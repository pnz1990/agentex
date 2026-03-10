#!/bin/bash
set -uo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PLANNER LOOP — The Civilization's Heartbeat
# ═══════════════════════════════════════════════════════════════════════════
#
# This is a thin perpetuation mechanism (not a planner itself) that:
# 1. Spawns planner Jobs with generational identity
# 2. Enforces circuit breaker before spawning
# 3. Never exits (Kubernetes keeps the Deployment alive)
# 4. Eliminates chain breaks and TOCTOU races
#
# The loop is the perpetuation mechanism. The Job is the agent with LLM session.
# ═══════════════════════════════════════════════════════════════════════════

NAMESPACE="${NAMESPACE:-agentex}"
BEDROCK_REGION="${BEDROCK_REGION:-us-west-2}"  # For CloudWatch metrics
SPAWN_INTERVAL=60  # Check every 60 seconds if we need a new planner
CONSTITUTION_CM="agentex-constitution"

echo "═══════════════════════════════════════════════════════════════════════════"
echo "PLANNER LOOP STARTING"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Namespace: $NAMESPACE"
echo "Spawn interval: ${SPAWN_INTERVAL}s"
echo ""

# ── Configure kubectl ────────────────────────────────────────────────────────
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    kubectl config set-cluster local --server=https://kubernetes.default.svc --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    kubectl config set-credentials sa --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    kubectl config set-context local --cluster=local --user=sa --namespace="$NAMESPACE"
    kubectl config use-context local
fi

# ── Helper Functions ─────────────────────────────────────────────────────────

kubectl_with_timeout() {
  local timeout_secs="${1:-10}"
  shift
  # Issue #992 (same as #982 in coordinator.sh and #959 in entrypoint.sh): Do NOT use 2>&1 —
  # that mixes stderr into stdout, corrupting JSON output when callers use
  # $(kubectl_with_timeout ...) to capture data and pipe to jq.
  # Stderr is suppressed here; callers that need error context add 2>&1 explicitly.
  timeout "${timeout_secs}s" kubectl "$@" 2>/dev/null
}

push_metric() {
    local metric_name="$1"
    local value="$2"
    local unit="${3:-Count}"
    local dimensions="${4:-Component=PlannerLoop}"
    
    aws cloudwatch put-metric-data \
        --namespace Agentex \
        --metric-name "$metric_name" \
        --value "$value" \
        --unit "$unit" \
        --dimensions "$dimensions" \
        --region "$BEDROCK_REGION" 2>/dev/null || true
}

count_active_jobs() {
    # Redirect stderr to /dev/null to avoid mixing error output with the integer result
    timeout 10s kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0"
}

count_active_planners() {
    # Redirect stderr to /dev/null to avoid mixing error output with the integer result
    timeout 10s kubectl get jobs -n "$NAMESPACE" -l agentex/role=planner -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0"
}

spawn_planner_job() {
    local name="$1"
    local generation="$2"
    local model="$3"
    local task_name="task-${name}"
    
    echo "[$(date -u +%H:%M:%S)] Spawning planner Job: $name (generation $generation, model $model)"
    
    # Create Task CR first
    kubectl apply --validate=false -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Task
metadata:
  name: ${task_name}
  namespace: ${NAMESPACE}
  labels:
    agentex/generation: "${generation}"
spec:
  title: "Continuous platform improvement — planner loop generation ${generation}"
  description: |
    Audit codebase, fix one platform issue, spawn workers for open GitHub issues.
    Check coordinator-state for task queue. Spawn next workers as needed.
    Post insight thought before exiting.
  effort: M
  priority: 10
EOF
    
    # Create Agent CR (triggers Job via agent-graph RGD)
    kubectl apply --validate=false -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Agent
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    agentex/role: planner
    agentex/generation: "${generation}"
spec:
  role: planner
  taskRef: ${task_name}
  model: ${model}
EOF
    
    if [ $? -ne 0 ]; then
        echo "[$(date -u +%H:%M:%S)] ERROR: Failed to create Agent CR for $name"
        push_metric "PlannerSpawnFailed" 1 "Count"
        return 1
    fi

    # KRO FALLBACK (issue #714): If kro is down, Agent CR exists but no Job is created.
    # Wait 15s for kro to create the Job. If it doesn't, create the Job directly.
    echo "[$(date -u +%H:%M:%S)] Verifying kro creates Job for $name (15s grace period)..."
    local job_created=false
    for i in $(seq 1 15); do
        local job_name
        job_name=$(kubectl_with_timeout 5 get agent.kro.run "$name" -n "$NAMESPACE" \
            -o jsonpath='{.status.jobName}' 2>/dev/null || echo "")
        if [ -n "$job_name" ]; then
            echo "[$(date -u +%H:%M:%S)] kro created Job $job_name ✓"
            job_created=true
            break
        fi
        sleep 1
    done

    if [ "$job_created" = "false" ]; then
        echo "[$(date -u +%H:%M:%S)] WARNING: kro did not create Job for $name after 15s. Creating Job directly (kro fallback)."
        local fallback_registry
        fallback_registry=$(kubectl_with_timeout 10 get configmap "$CONSTITUTION_CM" -n "$NAMESPACE" \
            -o jsonpath='{.data.ecrRegistry}' 2>/dev/null || echo "569190534191.dkr.ecr.us-west-2.amazonaws.com")
        local repo
        repo=$(kubectl_with_timeout 10 get configmap "$CONSTITUTION_CM" -n "$NAMESPACE" \
            -o jsonpath='{.data.githubRepo}' 2>/dev/null || echo "pnz1990/agentex")
        local cluster_name
        cluster_name=$(kubectl_with_timeout 10 get configmap "$CONSTITUTION_CM" -n "$NAMESPACE" \
            -o jsonpath='{.data.clusterName}' 2>/dev/null || echo "agentex")
        kubectl_with_timeout 10 apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: agent-${name}
  namespace: ${NAMESPACE}
  labels:
    agentex/agent: ${name}
    agentex/role: planner
    agentex/generation: "${generation}"
    kro.run/instance: ${name}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 180
  activeDeadlineSeconds: 3600
  template:
    metadata:
      labels:
        agentex/agent: ${name}
        agentex/role: planner
    spec:
      serviceAccountName: agentex-agent-sa
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: agent
          image: ${fallback_registry}/agentex/runner:latest
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
          env:
            - name: AGENT_NAME
              value: ${name}
            - name: AGENT_ROLE
              value: planner
            - name: TASK_CR_NAME
              value: task-${name}
            - name: BEDROCK_MODEL
              value: ${model}
            - name: BEDROCK_REGION
              value: ${BEDROCK_REGION}
            - name: REPO
              value: ${repo}
            - name: CLUSTER
              value: ${cluster_name}
            - name: NAMESPACE
              value: ${NAMESPACE}
            - name: GITHUB_TOKEN_FILE
              value: "/var/secrets/github/token"
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "2Gi"
              cpu: "1000m"
          volumeMounts:
            - name: workspace
              mountPath: /workspace
            - name: github-token
              mountPath: /var/secrets/github
              readOnly: true
      volumes:
        - name: workspace
          emptyDir:
            sizeLimit: 2Gi
        - name: github-token
          secret:
            secretName: agentex-github-token
            defaultMode: 0400
EOF
        if [ $? -eq 0 ]; then
            echo "[$(date -u +%H:%M:%S)] Fallback Job created for $name ✓"
            push_metric "PlannerFallbackJobCreated" 1 "Count"
        else
            echo "[$(date -u +%H:%M:%S)] ERROR: Fallback Job creation also failed for $name"
            push_metric "PlannerSpawnFailed" 1 "Count"
            return 1
        fi
    fi

    echo "[$(date -u +%H:%M:%S)] Planner Job spawned successfully: $name"
    push_metric "PlannerSpawned" 1 "Count"
    return 0
}

# ── Main Loop ────────────────────────────────────────────────────────────────

echo "[$(date -u +%H:%M:%S)] Starting planner-loop main cycle"
push_metric "PlannerLoopStarted" 1 "Count"

LOOP_ITERATION=0

while true; do
    LOOP_ITERATION=$((LOOP_ITERATION + 1))
    echo ""
    echo "[$(date -u +%H:%M:%S)] ─────────────────────────────────────────────────────────"
    echo "[$(date -u +%H:%M:%S)] Planner-loop iteration $LOOP_ITERATION"
    
    # Read constitution values
    GEN=$(kubectl_with_timeout 10 get configmap "$CONSTITUTION_CM" -n "$NAMESPACE" \
        -o jsonpath='{.data.civilizationGeneration}' 2>/dev/null || echo "1")
    if ! [[ "$GEN" =~ ^[0-9]+$ ]]; then GEN=1; fi
    
    LIMIT=$(kubectl_with_timeout 10 get configmap "$CONSTITUTION_CM" -n "$NAMESPACE" \
        -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "6")
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then LIMIT=6; fi
    
    AGENT_MODEL=$(kubectl_with_timeout 10 get configmap "$CONSTITUTION_CM" -n "$NAMESPACE" \
        -o jsonpath='{.data.agentModel}' 2>/dev/null || echo "us.anthropic.claude-sonnet-4-6")
    if [ -z "$AGENT_MODEL" ]; then AGENT_MODEL="us.anthropic.claude-sonnet-4-6"; fi
    
    # Check kill switch
    KILL_ENABLED=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
        -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
    if [ "$KILL_ENABLED" = "true" ]; then
        KILL_REASON=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
            -o jsonpath='{.data.reason}' 2>/dev/null || echo "unknown")
        echo "[$(date -u +%H:%M:%S)] Kill switch active: $KILL_REASON"
        echo "[$(date -u +%H:%M:%S)] Planner-loop respects kill switch. Waiting for deactivation..."
        push_metric "PlannerLoopKillSwitchActive" 1 "Count"
        sleep "$SPAWN_INTERVAL"
        continue
    fi
    
    # Count active jobs and planners
    ACTIVE_JOBS=$(count_active_jobs)
    ACTIVE_PLANNERS=$(count_active_planners)
    
    echo "[$(date -u +%H:%M:%S)] Active jobs: $ACTIVE_JOBS / $LIMIT (circuit breaker limit)"
    echo "[$(date -u +%H:%M:%S)] Active planners: $ACTIVE_PLANNERS"
    
    # Emit metrics
    push_metric "ActiveJobs" "$ACTIVE_JOBS" "Count"
    push_metric "ActivePlanners" "$ACTIVE_PLANNERS" "Count"
    push_metric "PlannerLoopHeartbeat" 1 "Count"
    
    # Decision: should we spawn a planner?
    SHOULD_SPAWN=false
    SPAWN_REASON=""
    
    if [ "$ACTIVE_JOBS" -ge "$LIMIT" ]; then
        echo "[$(date -u +%H:%M:%S)] Circuit breaker active: $ACTIVE_JOBS >= $LIMIT. No spawn."
        push_metric "CircuitBreakerActive" 1 "Count"
    elif [ "$ACTIVE_PLANNERS" -gt 0 ]; then
        echo "[$(date -u +%H:%M:%S)] Planner already running. No spawn needed."
    else
        SHOULD_SPAWN=true
        SPAWN_REASON="no-active-planner"
        echo "[$(date -u +%H:%M:%S)] No active planner detected. Ready to spawn."
    fi
    
    # Spawn if needed
    if [ "$SHOULD_SPAWN" = "true" ]; then
        NAME="planner-gen${GEN}-$(date +%s)"
        echo "[$(date -u +%H:%M:%S)] Spawning planner: $NAME (reason: $SPAWN_REASON)"
        
        if spawn_planner_job "$NAME" "$GEN" "$AGENT_MODEL"; then
            echo "[$(date -u +%H:%M:%S)] Planner spawned successfully"
        else
            echo "[$(date -u +%H:%M:%S)] Planner spawn failed — will retry next iteration"
        fi
    fi
    
    # Sleep until next check
    echo "[$(date -u +%H:%M:%S)] Sleeping ${SPAWN_INTERVAL}s until next check"
    sleep "$SPAWN_INTERVAL"
done
