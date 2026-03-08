#!/usr/bin/env bash
# Trigger a rolling restart of all agent pods by updating the forceRestart timestamp
# in the agentex-runner-version ConfigMap.
#
# When to use this:
# - After merging a PR that changes images/runner/entrypoint.sh or Dockerfile
# - When you need all agents to pick up new runner image immediately
# - When circuit breaker or other critical fixes need to take effect now
#
# What happens:
# - All running agents detect forceRestart > their start time
# - Each agent exits gracefully (not a crash)
# - Emergency perpetuation spawns replacement with imagePullPolicy: Always
# - Replacement pulls latest image and starts with new code
# - Rolling restart completes in ~2-5 minutes (depends on active agent count)
#
# Safety:
# - Does NOT delete pods directly (agents exit gracefully)
# - Preserves agent lineage (emergency perpetuation maintains chain)
# - Circuit breaker prevents proliferation during restart wave

set -euo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
RESTART_TIMESTAMP=$(date +%s)
HUMAN_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "Triggering rolling restart of all agents..."
echo "Restart timestamp: $RESTART_TIMESTAMP ($HUMAN_TIMESTAMP)"

# Check if ConfigMap exists
if ! kubectl get configmap agentex-runner-version -n "$NAMESPACE" &>/dev/null; then
  echo "ConfigMap agentex-runner-version does not exist. Creating..."
  kubectl create configmap agentex-runner-version -n "$NAMESPACE" \
    --from-literal=forceRestart="$RESTART_TIMESTAMP" \
    --from-literal=imageTag=latest \
    --from-literal=lastUpdated="$HUMAN_TIMESTAMP"
else
  echo "Updating existing ConfigMap..."
  kubectl patch configmap agentex-runner-version -n "$NAMESPACE" \
    --type=merge \
    -p "{\"data\":{\"forceRestart\":\"${RESTART_TIMESTAMP}\",\"lastUpdated\":\"${HUMAN_TIMESTAMP}\"}}"
fi

echo "✓ Rolling restart triggered."
echo ""
echo "Expected behavior:"
echo "  - All agents will detect restart signal on next inbox check"
echo "  - Each agent exits with 'Rolling restart triggered' message"
echo "  - Emergency perpetuation spawns replacements with latest image"
echo "  - Restart wave completes in ~2-5 minutes"
echo ""
echo "Monitor progress:"
echo "  watch 'kubectl get jobs -n $NAMESPACE | grep Running | wc -l'"
echo "  kubectl logs -n $NAMESPACE -l kro.run/resource-graph-definition-name=agent-graph --tail=20 -f"
