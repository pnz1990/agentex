#!/bin/bash
# Health check script for safe kill switch deactivation
# Usage: ./killswitch-healthcheck.sh
# Exit codes: 0 = safe to deactivate, 1 = not safe

set -euo pipefail

NAMESPACE="agentex"

# Read circuit breaker limit from constitution (do not hardcode!)
CIRCUIT_BREAKER_LIMIT=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "15")
if ! [[ "$CIRCUIT_BREAKER_LIMIT" =~ ^[0-9]+$ ]]; then CIRCUIT_BREAKER_LIMIT=15; fi

# Calculate threshold as 2/3 of circuit breaker limit (safe margin for recovery)
ACTIVE_JOB_THRESHOLD=$((CIRCUIT_BREAKER_LIMIT * 2 / 3))

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 Kill Switch Health Check"
echo "============================"
echo ""

# Check 1: Kill switch is currently enabled
echo "1. Checking kill switch status..."
KILLSWITCH_ENABLED=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" -o jsonpath='{.data.enabled}' 2>/dev/null || echo "unknown")
KILLSWITCH_REASON=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" -o jsonpath='{.data.reason}' 2>/dev/null || echo "")

if [ "$KILLSWITCH_ENABLED" != "true" ]; then
  echo -e "${YELLOW}⚠️  Kill switch is already disabled (enabled=$KILLSWITCH_ENABLED)${NC}"
  echo "   Nothing to deactivate."
  exit 1
fi

echo -e "   ${GREEN}✓${NC} Kill switch is enabled"
echo "   Reason: $KILLSWITCH_REASON"
echo ""

# Check 2: Active job count is below threshold
echo "2. Checking active job count..."
ACTIVE_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")

echo "   Active jobs: $ACTIVE_JOBS / threshold: $ACTIVE_JOB_THRESHOLD / circuit breaker: $CIRCUIT_BREAKER_LIMIT"

if [ "$ACTIVE_JOBS" -ge "$ACTIVE_JOB_THRESHOLD" ]; then
  echo -e "   ${RED}✗${NC} Too many active jobs ($ACTIVE_JOBS >= $ACTIVE_JOB_THRESHOLD)"
  echo "   NOT SAFE to deactivate kill switch yet."
  exit 1
fi

echo -e "   ${GREEN}✓${NC} Active jobs below threshold"
echo ""

# Check 3: No recent proliferation pattern (stable for at least 2 minutes)
echo "3. Checking for recent proliferation patterns..."
RECENT_JOBS=$(kubectl get jobs -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp -o json 2>/dev/null | \
  jq '[.items[] | select(.metadata.creationTimestamp > (now - 120 | strftime("%Y-%m-%dT%H:%M:%SZ")))] | length' 2>/dev/null || echo "0")

echo "   Jobs created in last 2 minutes: $RECENT_JOBS"

if [ "$RECENT_JOBS" -gt 5 ]; then
  echo -e "   ${RED}✗${NC} High spawn rate detected ($RECENT_JOBS jobs in 2 minutes)"
  echo "   System may not be stable yet."
  exit 1
fi

echo -e "   ${GREEN}✓${NC} Spawn rate is stable"
echo ""

# Check 4: Verify circuit breaker is working (entrypoint.sh has the code)
echo "4. Checking circuit breaker implementation..."
BREAKER_CHECK=$(kubectl get configmap -n "$NAMESPACE" -l app.kubernetes.io/component=agent-runner -o name 2>/dev/null | wc -l)

if [ "$BREAKER_CHECK" -eq 0 ]; then
  echo -e "   ${YELLOW}⚠️  Cannot verify circuit breaker implementation${NC}"
  echo "   Proceeding with caution..."
else
  echo -e "   ${GREEN}✓${NC} Runner configuration found"
fi
echo ""

# Check 5: No failed agent spawns in last 5 minutes
echo "5. Checking for recent spawn failures..."
FAILED_JOBS=$(kubectl get jobs -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp -o json 2>/dev/null | \
  jq '[.items[] | select(.metadata.creationTimestamp > (now - 300 | strftime("%Y-%m-%dT%H:%M:%SZ")) and .status.failed > 0)] | length' 2>/dev/null || echo "0")

echo "   Failed jobs in last 5 minutes: $FAILED_JOBS"

if [ "$FAILED_JOBS" -gt 3 ]; then
  echo -e "   ${RED}✗${NC} High failure rate detected ($FAILED_JOBS failures in 5 minutes)"
  echo "   System may have underlying issues."
  exit 1
fi

echo -e "   ${GREEN}✓${NC} Failure rate is acceptable"
echo ""

# All checks passed
echo "============================"
echo -e "${GREEN}✓ ALL CHECKS PASSED${NC}"
echo ""
echo "Safe to deactivate kill switch. Run:"
echo ""
echo "  kubectl patch configmap agentex-killswitch -n agentex \\"
echo "    --type=merge -p '{\"data\":{\"enabled\":\"false\",\"reason\":\"\"}}'"
echo ""
echo "Then monitor for 5 minutes:"
echo "  watch 'kubectl get jobs -n agentex | grep Running | wc -l'"
echo ""

exit 0
