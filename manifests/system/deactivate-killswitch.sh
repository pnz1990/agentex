#!/usr/bin/env bash
# Safe kill switch deactivation procedure
# Issue #390: Ensures system is healthy before re-enabling agent spawning
#
# Usage: ./manifests/system/deactivate-killswitch.sh [--force]
#
# Safety checks:
# 1. Active job count must be < 8 (safe margin below limit of 10)
# 2. No agent proliferation in last 5 minutes
# 3. At least one healthy planner agent running
#
# The --force flag bypasses all safety checks (dangerous!)

set -euo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
FORCE_MODE=false

# Parse arguments
if [ "${1:-}" = "--force" ]; then
  FORCE_MODE=true
  echo "⚠️  FORCE MODE: Bypassing all safety checks!"
fi

echo "═══════════════════════════════════════════════════════════"
echo "Kill Switch Deactivation Procedure"
echo "═══════════════════════════════════════════════════════════"
echo ""

# 1. Check current kill switch state
echo "Step 1: Checking current kill switch state..."
KILLSWITCH_ENABLED=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
  -o jsonpath='{.data.enabled}' 2>/dev/null || echo "unknown")
KILLSWITCH_REASON=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
  -o jsonpath='{.data.reason}' 2>/dev/null || echo "unknown")

if [ "$KILLSWITCH_ENABLED" != "true" ]; then
  echo "✓ Kill switch is already disabled (enabled=$KILLSWITCH_ENABLED)"
  echo "  No action needed."
  exit 0
fi

echo "  Kill switch is ACTIVE"
echo "  Reason: $KILLSWITCH_REASON"
echo ""

if [ "$FORCE_MODE" = "false" ]; then
  # 2. Check active job count
  echo "Step 2: Checking active job count..."
  ACTIVE_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length')
  
  echo "  Active jobs: $ACTIVE_JOBS"
  
  if [ "$ACTIVE_JOBS" -ge 8 ]; then
    echo "❌ SAFETY CHECK FAILED: $ACTIVE_JOBS active jobs (must be < 8)"
    echo "   The system still has too many active agents."
    echo "   Wait for jobs to complete or use --force to override."
    exit 1
  fi
  echo "✓ Active job count is safe ($ACTIVE_JOBS < 8)"
  echo ""
  
  # 3. Check for recent proliferation (job creation rate in last 5 minutes)
  echo "Step 3: Checking for recent agent proliferation..."
  FIVE_MIN_AGO=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                 date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                 echo "2020-01-01T00:00:00Z")
  
  RECENT_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json | \
    jq --arg threshold "$FIVE_MIN_AGO" \
      '[.items[] | select(.metadata.creationTimestamp > $threshold)] | length')
  
  echo "  Jobs created in last 5 minutes: $RECENT_JOBS"
  
  if [ "$RECENT_JOBS" -ge 15 ]; then
    echo "❌ SAFETY CHECK FAILED: $RECENT_JOBS jobs created recently (limit: 15)"
    echo "   High job creation rate detected. System may still be proliferating."
    echo "   Wait a few more minutes or use --force to override."
    exit 1
  fi
  echo "✓ No recent proliferation detected ($RECENT_JOBS < 15 jobs in 5 min)"
  echo ""
  
  # 4. Check for healthy planner agent
  echo "Step 4: Checking for healthy planner agents..."
  PLANNER_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json | \
    jq '[.items[] | 
         select(.metadata.name | startswith("planner-")) | 
         select(.status.completionTime == null and (.status.active // 0) > 0)] | length')
  
  echo "  Active planner jobs: $PLANNER_JOBS"
  
  if [ "$PLANNER_JOBS" -lt 1 ]; then
    echo "⚠️  WARNING: No active planner jobs found!"
    echo "   The planner chain may be broken. System may not self-perpetuate."
    echo "   Consider spawning a planner manually before deactivating."
    read -p "   Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted by user."
      exit 1
    fi
  else
    echo "✓ Healthy planner chain detected ($PLANNER_JOBS active)"
  fi
  echo ""
fi

# 5. Deactivate kill switch
echo "Step 5: Deactivating kill switch..."
kubectl patch configmap agentex-killswitch -n "$NAMESPACE" \
  --type=merge -p '{"data":{"enabled":"false","reason":""}}' || {
  echo "❌ ERROR: Failed to patch kill switch ConfigMap"
  exit 1
}

echo "✓ Kill switch deactivated successfully"
echo ""

# 6. Post a Thought CR to notify agents
echo "Step 6: Posting notification Thought CR..."
kubectl apply -f - <<EOF >/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-killswitch-deactivated-$(date +%s)
  namespace: $NAMESPACE
spec:
  agentRef: "system-operator"
  taskRef: "killswitch-deactivation"
  thoughtType: observation
  confidence: 10
  content: |
    Kill switch DEACTIVATED at $(date -u +%Y-%m-%dT%H:%M:%SZ).
    Agent spawning has been re-enabled.
    System status at deactivation:
    - Active jobs: ${ACTIVE_JOBS:-unknown}
    - Recent jobs (5 min): ${RECENT_JOBS:-unknown}
    - Active planner jobs: ${PLANNER_JOBS:-unknown}
    
    The civilization can now resume self-perpetuation.
EOF

echo "✓ Notification Thought CR posted"
echo ""

# 7. Verify deactivation
echo "Step 7: Verifying deactivation..."
FINAL_STATE=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
  -o jsonpath='{.data.enabled}' 2>/dev/null || echo "unknown")

if [ "$FINAL_STATE" = "false" ]; then
  echo "✓ Kill switch successfully deactivated and verified"
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "SUCCESS: Agent spawning has been re-enabled"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  echo "Next steps:"
  echo "  1. Monitor active job count: kubectl get jobs -n $NAMESPACE --watch"
  echo "  2. Watch for new agents: kubectl get agents -n $NAMESPACE --watch"
  echo "  3. If proliferation resumes, re-activate immediately:"
  echo "     kubectl patch configmap agentex-killswitch -n $NAMESPACE \\"
  echo "       --type=merge -p '{\"data\":{\"enabled\":\"true\",\"reason\":\"Proliferation detected\"}}'"
  exit 0
else
  echo "❌ ERROR: Kill switch state is '$FINAL_STATE' (expected 'false')"
  echo "   Deactivation may have failed. Check ConfigMap manually."
  exit 1
fi
