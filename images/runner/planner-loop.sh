#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PLANNER LOOP — The Civilization's Perpetual Heartbeat
# ═══════════════════════════════════════════════════════════════════════════
#
# This is a thin Deployment that spawns planner Jobs but does NOT do planning.
# 
# RESPONSIBILITIES:
# 1. Spawn a new planner Job when no planner is currently active
# 2. Enforce circuit breaker before spawning
# 3. Check kill switch before spawning
# 4. Wait for planner to complete before spawning next
# 5. Never exit (Deployment keeps it alive)
#
# WHY THIS EXISTS:
# - Eliminates TOCTOU race in planner self-perpetuation (issue #828)
# - Exactly-one-planner guaranteed by Kubernetes (replicas: 1)
# - No chain to break — Deployment is immortal, not fragile Job chain
# - Simplifies planner Agent code (no self-spawning logic needed)
# - Coordinator watchdog becomes unnecessary
#
# WHAT THIS IS NOT:
# - NOT an agent (no OpenCode, no LLM, no Task CR)
# - NOT a planner (planners still do actual planning work)
# - NOT a coordinator (coordinator handles work distribution, voting, state)
#
# ═══════════════════════════════════════════════════════════════════════════

NAMESPACE="${NAMESPACE:-agentex}"
LOOP_INTERVAL=60  # seconds between checks
SPAWN_GRACE_PERIOD=10  # seconds to wait for kro to create Job after Agent CR

echo "═══════════════════════════════════════════════════════════════════════════"
echo "PLANNER LOOP STARTING"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Namespace: $NAMESPACE"
echo "Loop interval: ${LOOP_INTERVAL}s"
echo "Spawn grace period: ${SPAWN_GRACE_PERIOD}s"
echo ""

# ── Configure kubectl ────────────────────────────────────────────────────────
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    kubectl config set-cluster local --server=https://kubernetes.default.svc --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    kubectl config set-credentials sa --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    kubectl config set-context local --cluster=local --user=sa --namespace="$NAMESPACE"
    kubectl config use-context local
fi

# kubectl timeout wrapper
kubectl_with_timeout() {
  local timeout_secs="${1:-10}"
  shift
  timeout "${timeout_secs}s" kubectl "$@" 2>&1
}

# Check if kill switch is active
is_kill_switch_active() {
    local enabled
    enabled=$(kubectl_with_timeout 5 get configmap agentex-killswitch -n "$NAMESPACE" \
        -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
    [ "$enabled" = "true" ]
}

# Get circuit breaker limit from constitution
get_circuit_breaker_limit() {
    kubectl_with_timeout 5 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "6"
}

# Count active jobs (jobs with active > 0 and no completionTime)
count_active_jobs() {
    kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
        2>/dev/null || echo "99"
}

# Count active planner jobs specifically
count_active_planners() {
    kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] |
            select(.status.completionTime == null and (.status.active // 0) > 0) |
            select(.metadata.name | test("planner"))] | length' \
        2>/dev/null || echo "-1"
}

# Get current civilization generation from constitution
get_generation() {
    kubectl_with_timeout 5 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.civilizationGeneration}' 2>/dev/null || echo "3"
}

# Spawn a planner Job
spawn_planner() {
    local generation="$1"
    local timestamp
    timestamp=$(date +%s)
    local agent_name="planner-${timestamp}"
    local task_name="task-${agent_name}"
    
    echo "[$(date -u +%H:%M:%S)] Spawning planner: ${agent_name} (generation=${generation})"
    
    # Create Task CR
    kubectl_with_timeout 15 apply -f - <<EOF 2>/dev/null || {
        echo "[$(date -u +%H:%M:%S)] ERROR: Failed to create Task CR ${task_name}"
        return 1
    }
apiVersion: kro.run/v1alpha1
kind: Task
metadata:
  name: ${task_name}
  namespace: ${NAMESPACE}
spec:
  title: "Continuous platform improvement — planner loop generation ${generation}"
  description: |
    Audit codebase (manifests/rgds/*.yaml, images/runner/entrypoint.sh, AGENTS.md).
    Find one platform improvement and fix it (create GitHub Issue, implement if S-effort).
    Spawn workers for open GitHub issues.
    
    IMPORTANT: You do NOT need to spawn your own successor — the planner-loop Deployment
    handles perpetuation automatically. Focus on your work, exit cleanly when done.
  priority: 8
  effort: M
EOF
    
    # Create Agent CR
    kubectl_with_timeout 15 apply -f - <<EOF 2>/dev/null || {
        echo "[$(date -u +%H:%M:%S)] ERROR: Failed to create Agent CR ${agent_name}"
        return 1
    }
apiVersion: kro.run/v1alpha1
kind: Agent
metadata:
  name: ${agent_name}
  namespace: ${NAMESPACE}
  labels:
    agentex/role: "planner"
    agentex/generation: "${generation}"
    agentex/spawned-by: "planner-loop"
spec:
  taskRef: ${task_name}
  role: planner
  priority: 8
EOF
    
    echo "[$(date -u +%H:%M:%S)] Created Agent CR ${agent_name}, waiting for kro to create Job..."
    
    # Wait for kro to create the Job (with grace period)
    local retries=0
    local max_retries=$((SPAWN_GRACE_PERIOD / 2))
    while [ $retries -lt $max_retries ]; do
        local job_exists
        job_exists=$(kubectl_with_timeout 5 get job "${agent_name}" -n "$NAMESPACE" 2>/dev/null && echo "yes" || echo "no")
        
        if [ "$job_exists" = "yes" ]; then
            echo "[$(date -u +%H:%M:%S)] ✓ Planner Job ${agent_name} created by kro"
            return 0
        fi
        
        sleep 2
        retries=$((retries + 1))
    done
    
    echo "[$(date -u +%H:%M:%S)] WARNING: kro did not create Job for ${agent_name} within ${SPAWN_GRACE_PERIOD}s"
    return 1
}

# Main loop
echo "Entering main loop..."
echo ""

while true; do
    # Health check markers
    echo "[$(date -u +%H:%M:%S)] Planner loop heartbeat"
    
    # Step 1: Check kill switch
    if is_kill_switch_active; then
        echo "[$(date -u +%H:%M:%S)] Kill switch ACTIVE — skipping spawn"
        sleep "$LOOP_INTERVAL"
        continue
    fi
    
    # Step 2: Check if a planner is already running
    active_planners=$(count_active_planners)
    if [ "$active_planners" = "-1" ]; then
        echo "[$(date -u +%H:%M:%S)] kubectl unavailable — skipping spawn"
        sleep "$LOOP_INTERVAL"
        continue
    fi
    
    if [ "$active_planners" -gt 0 ]; then
        echo "[$(date -u +%H:%M:%S)] Planner already active (count=${active_planners}) — waiting"
        sleep "$LOOP_INTERVAL"
        continue
    fi
    
    # Step 3: Check circuit breaker
    cb_limit=$(get_circuit_breaker_limit)
    active_jobs=$(count_active_jobs)
    
    if [ "$active_jobs" = "99" ]; then
        echo "[$(date -u +%H:%M:%S)] kubectl unavailable for job count — skipping spawn"
        sleep "$LOOP_INTERVAL"
        continue
    fi
    
    if [ "$active_jobs" -ge "$cb_limit" ]; then
        echo "[$(date -u +%H:%M:%S)] Circuit breaker ACTIVE (${active_jobs} >= ${cb_limit}) — skipping spawn"
        sleep "$LOOP_INTERVAL"
        continue
    fi
    
    # Step 4: All checks passed — spawn planner
    generation=$(get_generation)
    echo "[$(date -u +%H:%M:%S)] No active planner and circuit breaker permits spawn (${active_jobs}/${cb_limit})"
    
    if spawn_planner "$generation"; then
        echo "[$(date -u +%H:%M:%S)] ✓ Planner spawned successfully"
    else
        echo "[$(date -u +%H:%M:%S)] ✗ Planner spawn failed — will retry next cycle"
    fi
    
    # Wait before next iteration
    sleep "$LOOP_INTERVAL"
done
