#!/usr/bin/env bash
# cleanup-stuck-agents.sh — Remove stuck/failed agent Jobs to unblock circuit breaker
# This script should be run when active job count exceeds circuit breaker limit (15)
# and agents cannot spawn successors.
#
# Usage:
#   ./cleanup-stuck-agents.sh [--dry-run] [--age-threshold-seconds 1800]
#
# Exit codes:
#   0 = cleanup successful or no cleanup needed
#   1 = error during cleanup

set -euo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
DRY_RUN=0
AGE_THRESHOLD=1800  # 30 minutes
MIN_FAILURES=2      # Jobs must have failed at least this many times

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --age-threshold-seconds)
      AGE_THRESHOLD="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run] [--age-threshold-seconds N]"
      exit 1
      ;;
  esac
done

echo "=== Agent Cleanup Script ==="
echo "Namespace: $NAMESPACE"
echo "Age threshold: ${AGE_THRESHOLD}s ($(($AGE_THRESHOLD / 60)) minutes)"
echo "Minimum failures: $MIN_FAILURES"
echo "Dry run: $DRY_RUN"
echo ""

# Count current active jobs
ACTIVE_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")

echo "Current active jobs: $ACTIVE_JOBS"
echo "Circuit breaker limit: 15"
echo ""

if [ "$ACTIVE_JOBS" -le 15 ]; then
  echo "✓ System is healthy (active jobs <= 15). No cleanup needed."
  exit 0
fi

echo "⚠️  Circuit breaker overload detected ($ACTIVE_JOBS > 15)"
echo ""

# Find stuck jobs (failed 2+ times, older than threshold, no completion)
echo "Identifying stuck jobs..."

STUCK_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | jq -r --arg threshold "$AGE_THRESHOLD" --arg min_failures "$MIN_FAILURES" '
  .items[] | 
  select(
    .status.completionTime == null and 
    (.status.failed // 0) >= ($min_failures | tonumber) and
    (.status.startTime | fromdateiso8601) < (now - ($threshold | tonumber))
  ) | .metadata.name' 2>/dev/null || echo "")

if [ -z "$STUCK_JOBS" ]; then
  echo "No stuck jobs found matching criteria."
  echo ""
  echo "Current jobs by status:"
  kubectl get jobs -n "$NAMESPACE" -o json | jq -r '.items[] | select(.status.completionTime == null) | 
    "\(.metadata.name): active=\(.status.active // 0) failed=\(.status.failed // 0) age=\((now - (.status.startTime | fromdateiso8601)) | floor)s"'
  exit 0
fi

STUCK_COUNT=$(echo "$STUCK_JOBS" | wc -l)
echo "Found $STUCK_COUNT stuck jobs:"
echo "$STUCK_JOBS" | sed 's/^/  - /'
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY RUN] Would delete $STUCK_COUNT jobs"
  echo "Run without --dry-run to execute cleanup"
  exit 0
fi

# Delete stuck jobs
echo "Deleting stuck jobs..."
DELETED=0
FAILED=0

while IFS= read -r job_name; do
  if [ -n "$job_name" ]; then
    echo "  Deleting job: $job_name"
    if kubectl delete job "$job_name" -n "$NAMESPACE" --wait=false 2>/dev/null; then
      DELETED=$((DELETED + 1))
    else
      echo "    ⚠️  Failed to delete $job_name"
      FAILED=$((FAILED + 1))
    fi
  fi
done <<< "$STUCK_JOBS"

echo ""
echo "Cleanup complete:"
echo "  - Deleted: $DELETED jobs"
echo "  - Failed: $FAILED jobs"
echo ""

# Wait for deletions to propagate (5 seconds)
echo "Waiting 5s for deletions to propagate..."
sleep 5

# Check new active job count
NEW_ACTIVE=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")

echo "Active jobs after cleanup: $NEW_ACTIVE"
echo ""

if [ "$NEW_ACTIVE" -le 15 ]; then
  echo "✓ SUCCESS: Circuit breaker is now passable ($NEW_ACTIVE <= 15)"
  
  # Post success Thought CR
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1 || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-cleanup-success-$(date +%s)
  namespace: $NAMESPACE
spec:
  agentRef: "cleanup-script"
  taskRef: "manual-cleanup"
  thoughtType: insight
  confidence: 10
  content: |
    Cleanup script executed successfully.
    Deleted $DELETED stuck jobs (failed >= $MIN_FAILURES times, age > ${AGE_THRESHOLD}s).
    Active jobs: $ACTIVE_JOBS → $NEW_ACTIVE
    Circuit breaker now passable. System can resume spawning agents.
EOF
  
  exit 0
else
  echo "⚠️  WARNING: Active jobs still above limit ($NEW_ACTIVE > 15)"
  echo "Additional cleanup may be needed. Consider:"
  echo "  - Running again with lower --age-threshold-seconds"
  echo "  - Manual inspection of remaining active jobs"
  exit 1
fi
