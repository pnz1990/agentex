#!/usr/bin/env bash
# Agentex Planner Loop — Thin perpetuation heartbeat
#
# This is NOT an agent — it's a simple bash loop that spawns planner Jobs.
# Each planner Job is a mortal agent with generational identity, LLM session,
# and N+2 planning. The Deployment is the immortal perpetuation mechanism.
#
# Why this architecture:
# - Exactly-one-planner guaranteed by K8s (replicas: 1) — no TOCTOU
# - No chain to break — Deployment is immortal, K8s keeps it alive
# - Zero-downtime generation transitions — god patches constitution
# - Eliminates planner emergency perpetuation
# - Planners stop spawning successors — simpler entrypoint.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
REPO="${REPO:-pnz1990/agentex}"
LOOP_INTERVAL="${LOOP_INTERVAL:-60}"  # seconds between checks

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [planner-loop] $*"
}

# kubectl timeout wrapper (prevent 120s hangs)
kubectl_with_timeout() {
  local timeout_secs="${1:-10}"
  shift
  timeout "${timeout_secs}s" kubectl "$@" 2>&1
}

# Configure kubectl for in-cluster auth
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    kubectl config set-cluster local --server=https://kubernetes.default.svc --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    kubectl config set-credentials sa --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    kubectl config set-context local --cluster=local --user=sa --namespace="$NAMESPACE"
    kubectl config use-context local
fi

log "Planner loop starting"
log "Namespace: $NAMESPACE"
log "Loop interval: ${LOOP_INTERVAL}s"
log ""

# ── Main Loop ────────────────────────────────────────────────────────────────

ITERATION=0
PENDING_PLANNER_GRACE=120  # seconds to wait after spawn before checking again

while true; do
  ITERATION=$((ITERATION + 1))
  log "=== Iteration $ITERATION ==="
  
  # Read constitution values
  GEN=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
    -o jsonpath='{.data.civilizationGeneration}' 2>/dev/null || echo "1")
  CB_LIMIT=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
    -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "6")
  
  # Check kill switch
  KILLSWITCH=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
    -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
  
  if [ "$KILLSWITCH" = "true" ]; then
    log "Kill switch ACTIVE — skipping planner spawn"
    sleep "$LOOP_INTERVAL"
    continue
  fi
  
  # Count active jobs (circuit breaker check)
  ACTIVE_JOBS=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
    2>/dev/null || echo "99")
  
  log "Active jobs: $ACTIVE_JOBS / $CB_LIMIT (circuit breaker limit)"
  
  if [ "$ACTIVE_JOBS" -ge "$CB_LIMIT" ]; then
    log "Circuit breaker ACTIVE — skipping planner spawn"
    sleep "$LOOP_INTERVAL"
    continue
  fi
  
  # Count active planner jobs
  ACTIVE_PLANNERS=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] |
         select(.status.completionTime == null and (.status.active // 0) > 0) |
         select(.metadata.name | test("planner"))] | length' \
    2>/dev/null || echo "-1")
  
  if [ "$ACTIVE_PLANNERS" = "-1" ]; then
    log "kubectl query failed — skipping this iteration"
    sleep "$LOOP_INTERVAL"
    continue
  fi
  
  log "Active planners: $ACTIVE_PLANNERS"
  
  if [ "$ACTIVE_PLANNERS" -gt 0 ]; then
    log "Planner already running — waiting for completion"
    sleep "$LOOP_INTERVAL"
    continue
  fi
  
  # Check for recent pending planners (prevent double-spawn during pod scheduling lag)
  RECENT_PLANNERS=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq --arg grace "$PENDING_PLANNER_GRACE" '[.items[] |
         select(.metadata.name | test("planner")) |
         select(.metadata.creationTimestamp != null) |
         select((now - (.metadata.creationTimestamp | fromdateiso8601)) < ($grace | tonumber))] | length' \
    2>/dev/null || echo "0")
  
  if [ "$RECENT_PLANNERS" -gt 0 ]; then
    log "Planner spawned recently (within ${PENDING_PLANNER_GRACE}s grace period) — waiting for pod to become active"
    sleep "$LOOP_INTERVAL"
    continue
  fi
  
  # No planner running — spawn one
  TS=$(date +%s)
  TASK_NAME="task-planner-gen${GEN}-${TS}"
  AGENT_NAME="planner-gen${GEN}-${TS}"
  
  log "Spawning planner: $AGENT_NAME (generation $GEN)"
  
  # Create Task CR
  if ! kubectl_with_timeout 15 apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Task
metadata:
  name: ${TASK_NAME}
  namespace: ${NAMESPACE}
spec:
  title: "Continuous platform improvement — planner loop generation ${GEN}"
  description: "Audit codebase, fix one platform issue, spawn workers for open GitHub issues. Read the constitution for vision alignment."
  priority: 5
  effort: M
EOF
  then
    log "ERROR: Failed to create Task CR $TASK_NAME"
    sleep "$LOOP_INTERVAL"
    continue
  fi
  
  # Create Agent CR
  if ! kubectl_with_timeout 15 apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Agent
metadata:
  name: ${AGENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    agentex/role: "planner"
    agentex/generation: "${GEN}"
    agentex/spawned-by: "planner-loop"
spec:
  taskRef: ${TASK_NAME}
  role: planner
  priority: 5
EOF
  then
    log "ERROR: Failed to create Agent CR $AGENT_NAME"
    # Clean up orphaned Task CR
    kubectl_with_timeout 10 delete task.kro.run "$TASK_NAME" -n "$NAMESPACE" 2>/dev/null || true
    sleep "$LOOP_INTERVAL"
    continue
  fi
  
  log "Planner $AGENT_NAME spawned successfully"
  
  # Post a Thought CR to announce spawn
  kubectl_with_timeout 15 apply -f - <<EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-planner-loop-${TS}
  namespace: ${NAMESPACE}
spec:
  agentRef: "planner-loop"
  taskRef: "planner-loop"
  thoughtType: insight
  confidence: 9
  content: |
    Planner loop spawned ${AGENT_NAME} for generation ${GEN}.
    Active jobs: ${ACTIVE_JOBS} / ${CB_LIMIT}
    This planner will audit the codebase, spawn workers, and exit.
    The planner-loop Deployment will spawn the next planner when this one completes.
EOF
  
  # Wait for the grace period before checking again (allow pod to become active)
  log "Waiting ${PENDING_PLANNER_GRACE}s grace period (pod scheduling lag)"
  sleep "$PENDING_PLANNER_GRACE"
done
