#!/usr/bin/env bash
# Agentex Agent Runner v3 — self-perpetuating loop
#
# The prime directive: when this agent exits, work MUST continue.
# Every agent spawns at least one successor Agent CR before dying.
# The system never idles. No human needed after initial seed.
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-unknown}"
AGENT_ROLE="${AGENT_ROLE:-worker}"
TASK_CR_NAME="${TASK_CR_NAME:-}"
SWARM_REF="${SWARM_REF:-}"
NAMESPACE="${NAMESPACE:-agentex}"
REPO="${REPO:-pnz1990/agentex}"
CLUSTER="${CLUSTER:-agentex}"
BEDROCK_REGION="${BEDROCK_REGION:-us-west-2}"
BEDROCK_MODEL="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"
WORKSPACE="/workspace"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$AGENT_NAME] $*"; }

# ── kubectl timeout wrapper (issue #441) ───────────────────────────────────
# Wrap critical kubectl commands with fast-fail timeout to prevent 120s hangs.
# When kubectl times out (cluster unreachable), detect it in 10s instead of 120s.
kubectl_with_timeout() {
  local timeout_secs="${1:-10}"
  shift
  timeout "${timeout_secs}s" kubectl "$@" 2>&1
}

# ── CONSTITUTION: Read god-owned constants ─────────────────────────────────
# These values are set by god and must not be changed by agents.
# To change: god edits the 'agentex-constitution' ConfigMap directly.
CIRCUIT_BREAKER_LIMIT=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "15")
if ! [[ "$CIRCUIT_BREAKER_LIMIT" =~ ^[0-9]+$ ]]; then CIRCUIT_BREAKER_LIMIT=15; fi

# Read vision and generation for agent self-assessment (issue #476)
CIVILIZATION_VISION=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.vision}' 2>/dev/null || echo "")
CIVILIZATION_GENERATION=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.civilizationGeneration}' 2>/dev/null || echo "1")
if ! [[ "$CIVILIZATION_GENERATION" =~ ^[0-9]+$ ]]; then CIVILIZATION_GENERATION=1; fi

ts() { date +%s; }

# ── Error trap handler for early-stage failures (issue #231) ──────────────────
# Without this, failures before step 12 (emergency perpetuation) cause silent chain breaks.
# The trap ensures SOME successor spawns even if kubectl config, git clone, or other early ops fail.
# CRITICAL (issue #344): Must respect circuit breaker to prevent proliferation from cascading errors.
handle_fatal_error() {
  local exit_code=$1 line_num=$2
  
  # Only trigger on actual errors (not normal exit 0)
  if [ "$exit_code" -ne 0 ]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME:-unknown}] FATAL ERROR at line $line_num (exit $exit_code)" >&2
    
    # Try to spawn emergency successor if AGENT_NAME is set and kubectl is configured
    # Check if we can reach the cluster before attempting spawn (with timeout)
    if [ -n "${AGENT_NAME:-}" ] && [ "$AGENT_NAME" != "unknown" ] && timeout 10s kubectl cluster-info &>/dev/null; then
      # CIRCUIT BREAKER: Check global active jobs first (issue #361)
      local total_active=$(kubectl_with_timeout 10 get jobs -n "${NAMESPACE}" -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
      
      # Try to emit active job metric before potential death (issue #416)
      aws cloudwatch put-metric-data --namespace Agentex --metric-name ActiveJobs --value "$total_active" --unit Count --dimensions Role="${AGENT_ROLE}",Agent="${AGENT_NAME}" --region "${BEDROCK_REGION:-us-west-2}" 2>/dev/null || true
      
      if [ "$total_active" -ge $CIRCUIT_BREAKER_LIMIT ]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] CIRCUIT BREAKER: $total_active active jobs >= $CIRCUIT_BREAKER_LIMIT. NOT spawning emergency successor." >&2
        # Try to emit metric before death (may fail if AWS/kubectl unavailable)
        aws cloudwatch put-metric-data --namespace Agentex --metric-name CircuitBreakerTriggered --value 1 --unit Count --dimensions Role="${AGENT_ROLE}",Agent="${AGENT_NAME}" --region "${BEDROCK_REGION:-us-west-2}" 2>/dev/null || true
        exit $exit_code
      fi
      
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] Attempting emergency spawn before death (circuit breaker OK: $total_active < $CIRCUIT_BREAKER_LIMIT)..." >&2
      local next_agent="${AGENT_ROLE}-$(date +%s)"
      local next_task="task-emergency-$(date +%s)"
      
      # Calculate next generation (issue #431: was hardcoded to "1")
      local my_generation=$(kubectl_with_timeout 10 get agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
      if ! [[ "$my_generation" =~ ^[0-9]+$ ]]; then
        my_generation=0
      fi
      local next_generation=$((my_generation + 1))
      
      # Inline emergency spawn (don't call functions that might fail)
      # Use || true to prevent trap recursion if kubectl fails
      # Issue #449: Capture stderr+stdout to log file for debugging
      kubectl apply -f - <<EOF 2>&1 | tee -a /tmp/emergency-spawn.log || true
apiVersion: kro.run/v1alpha1
kind: Task
metadata:
  name: $next_task
  namespace: ${NAMESPACE}
spec:
  title: "Emergency continuation after ${AGENT_NAME} fatal error"
  description: "Previous agent died at line $line_num with exit code $exit_code. Continue platform improvement."
  role: ${AGENT_ROLE}
  effort: M
  priority: 10
EOF
      kubectl apply -f - <<EOF 2>&1 | tee -a /tmp/emergency-spawn.log || true
apiVersion: kro.run/v1alpha1
kind: Agent
metadata:
  name: $next_agent
  namespace: ${NAMESPACE}
  labels:
    agentex/spawned-by: ${AGENT_NAME}
    agentex/emergency-spawn: "true"
    agentex/generation: "${next_generation}"
spec:
  role: ${AGENT_ROLE}
  taskRef: $next_task
  model: ${BEDROCK_MODEL}
EOF
      
      # Issue #449: Verify spawn succeeded with clear diagnostics
      # Issue #474: Use .kro.run API group (not default agentex.io)
      if kubectl get agent.kro.run "$next_agent" -n "$NAMESPACE" &>/dev/null; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] ✓ Emergency Agent CR created: $next_agent" >&2
      else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] ✗ Emergency spawn FAILED - Agent CR not found: $next_agent" >&2
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] Emergency spawn logs:" >&2
        cat /tmp/emergency-spawn.log >&2 2>/dev/null || echo "(no log file)" >&2
      fi
    fi
  fi
}

# Register trap for ERR (but NOT EXIT - that would trigger on normal completion too)
# Only trigger on errors, not on successful exits
trap 'handle_fatal_error $? $LINENO' ERR

# ── 0. Validate critical environment variables ────────────────────────────────
# Fail fast if required variables are missing to prevent cascading silent failures
if [ -z "$TASK_CR_NAME" ]; then
  echo "[FATAL] TASK_CR_NAME is required but not set. Agent cannot proceed without a task assignment." >&2
  exit 1
fi

if [ -z "$AGENT_NAME" ] || [ "$AGENT_NAME" = "unknown" ]; then
  echo "[FATAL] AGENT_NAME is required but not set. Agent cannot proceed without an identity." >&2
  exit 1
fi

log "Environment validated: agent=$AGENT_NAME task=$TASK_CR_NAME role=$AGENT_ROLE"

# ── 1. Configure kubectl ──────────────────────────────────────────────────────
log "Configuring kubectl for cluster $CLUSTER ..."
aws eks update-kubeconfig --name "$CLUSTER" --region "$BEDROCK_REGION"

# ── 1.1. Verify cluster connectivity (issue #431) ─────────────────────────────
# After kubectl config, verify we can reach the cluster API (relates to #430)
# Use short timeout (10s) to fail fast if cluster is unreachable
log "Verifying cluster connectivity..."
if ! timeout 10 kubectl cluster-info &>/dev/null; then
  log "ERROR: Cannot reach cluster API after kubectl config. Cluster may be down or network issue."
  log "Exiting cleanly - emergency perpetuation will spawn recovery agent if this is the last agent."
  exit 1
fi
log "Cluster connectivity verified ✓"

# ── 1.5. Initialize agent identity (issue #415) ───────────────────────────────
# Source identity.sh to claim persistent agent identity
# This MUST run after kubectl config and before any CR creation
if [ -f "/agent/identity.sh" ]; then
  source /agent/identity.sh
else
  log "WARNING: /agent/identity.sh not found, identity system disabled"
  AGENT_DISPLAY_NAME="$AGENT_NAME"
fi

# ── 2. Helper functions ───────────────────────────────────────────────────────
post_message() {
  local to="$1" body="$2" type="${3:-status}"
  local msg_name="msg-${AGENT_NAME}-$(date +%s%3N)"
  local err_output
  err_output=$(timeout 10s kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Message
metadata:
  name: ${msg_name}
  namespace: ${NAMESPACE}
spec:
  from: "${AGENT_NAME}"
  to: "${to}"
  thread: "${TASK_CR_NAME}"
  messageType: "${type}"
  body: |
$(echo "$body" | sed 's/^/    /')
EOF
) || {
    log "ERROR: Failed to create Message CR $msg_name: $err_output"
    return 0  # Don't fail the agent, but log the error
  }
  push_metric "MessageCreated" 1
}

post_thought() {
  local content="$1" type="${2:-observation}" confidence="${3:-7}"
  local thought_name="thought-${AGENT_NAME}-$(date +%s%3N)"
  local err_output
  err_output=$(timeout 10s kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: ${thought_name}
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  displayName: "${AGENT_DISPLAY_NAME:-$AGENT_NAME}"
  taskRef: "${TASK_CR_NAME}"
  thoughtType: "${type}"
  confidence: ${confidence}
  content: |
$(echo "$content" | sed 's/^/    /')
EOF
) || {
    log "ERROR: Failed to create Thought CR $thought_name: $err_output"
    return 0  # Don't fail the agent, but log the error
  }
  push_metric "ThoughtCreated" 1

  # Persist thought to S3 for long-term memory (survives cluster restarts)
  # Check if bucket exists before attempting write
  if aws s3 ls s3://agentex-thoughts/ >/dev/null 2>&1; then
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local s3_key="${AGENT_NAME}-${thought_name}.json"
    
    # Create JSON document with full thought metadata
    local s3_output
    if ! s3_output=$(cat <<JSON | aws s3 cp - "s3://agentex-thoughts/${s3_key}" --content-type application/json 2>&1
{
  "name": "${thought_name}",
  "agentRef": "${AGENT_NAME}",
  "displayName": "${AGENT_DISPLAY_NAME:-$AGENT_NAME}",
  "taskRef": "${TASK_CR_NAME}",
  "thoughtType": "${type}",
  "confidence": ${confidence},
  "timestamp": "${timestamp}",
  "content": $(echo "$content" | jq -Rs .)
}
JSON
); then
      log "WARNING: Failed to persist thought to S3 (key=${s3_key}): ${s3_output}"
    fi
    
    # Update identity stats (if identity system is active)
    if [ -n "${AGENT_DISPLAY_NAME:-}" ] && type update_identity_stats &>/dev/null; then
      update_identity_stats "thoughtsPosted" 1
    fi
  fi
}

# post_report() - Report CR with parameters matching Prime Directive step ⑤
# This is the primary interface agents should use per Prime Directive.
post_report() {
  local vision_score="$1" work_done="$2" issues_found="${3:-}" pr_opened="${4:-}" blockers="${5:-}" next_priority="${6:-}" exit_code="${7:-0}"
  local report_name="report-${AGENT_NAME}-$(date +%s)"
  
  # Get agent's generation from Agent CR
  local generation=$(kubectl_with_timeout 10 get agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
  if ! [[ "$generation" =~ ^[0-9]+$ ]]; then
    generation=0
  fi
  
  # Derive status from exit code
  local status="completed"
  if [ "$exit_code" -ne 0 ]; then
    status="failed"
  fi
  
  local err_output
  err_output=$(timeout 10s kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Report
metadata:
  name: ${report_name}
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  displayName: "${AGENT_DISPLAY_NAME:-$AGENT_NAME}"
  taskRef: "${TASK_CR_NAME}"
  role: "${AGENT_ROLE}"
  status: "${status}"
  visionScore: ${vision_score}
  workDone: |
$(echo "$work_done" | sed 's/^/    /')
  issuesFound: "${issues_found}"
  prOpened: "${pr_opened}"
  blockers: "${blockers}"
  nextPriority: "${next_priority}"
  generation: ${generation}
  exitCode: ${exit_code}
EOF
) || {
    log "ERROR: Failed to create Report CR $report_name: $err_output"
    return 0  # Don't fail the agent, but log the error
  }
  push_metric "ReportCreated" 1
  log "Report filed: vision=$vision_score issues=$issues_found pr=$pr_opened"
  
  # Update identity stats (if identity system is active)
  if [ -n "${AGENT_DISPLAY_NAME:-}" ] && type update_identity_stats &>/dev/null; then
    update_identity_stats "tasksCompleted" 1
  fi
}

patch_task_status() {
  local phase="$1" outcome="${2:-}"
  local completed_at=""
  [ "$phase" = "Done" ] && completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Patch the ConfigMap backing the Task CR, not the Task CR status directly.
  # kro status fields are output-only and reflect the ConfigMap data.
  # Use timeout to prevent 120s hangs if cluster API is unreachable (issue #458)
  timeout 10s kubectl patch configmap "${TASK_CR_NAME}-spec" -n "$NAMESPACE" \
    --type=merge \
    -p "{\"data\":{\"phase\":\"${phase}\",\"agentRef\":\"${AGENT_NAME}\",\"outcome\":\"${outcome}\",\"completedAt\":\"${completed_at}\"}}" \
    2>/dev/null || true
}

# Push a custom metric to CloudWatch for dashboard visibility.
# These metrics power the agentex-activity CloudWatch dashboard.
push_metric() {
  local metric_name="$1" value="${2:-1}" unit="${3:-Count}"
  aws cloudwatch put-metric-data \
    --namespace Agentex \
    --metric-name "$metric_name" \
    --value "$value" \
    --unit "$unit" \
    --dimensions Role="$AGENT_ROLE",Agent="$AGENT_NAME" \
    --region "$BEDROCK_REGION" \
    2>/dev/null || true
}

# ── Consensus Protocol Functions ──────────────────────────────────────────────
# Spawn a new Agent CR. This is the core perpetuation primitive.
# kro agent-graph turns this into a Job automatically.
spawn_agent() {
  local name="$1" role="$2" task_ref="$3" reason="$4"
  
  # EMERGENCY KILL SWITCH (issue #210): Check if spawning is globally disabled
  # Instant emergency stop via ConfigMap - no image rebuild needed
  local killswitch_enabled=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
    -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
  
  if [ "$killswitch_enabled" = "true" ]; then
    local killswitch_reason=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
      -o jsonpath='{.data.reason}' 2>/dev/null || echo "unknown")
    log "EMERGENCY KILL SWITCH ACTIVE: $killswitch_reason. NOT spawning successor."
    post_thought "Kill switch active: $killswitch_reason. Agent exiting without spawning successor." "blocker" 10
    return 1
  fi
  
  # GLOBAL CIRCUIT BREAKER (issue #338, #352): Hard limit to prevent catastrophic proliferation.
  # Count active Jobs (status.completionTime == null AND status.active > 0).
  # NOTE: Agent CRs never get completionTime set by kro — always use Jobs for counting.
  local total_active=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")

  # Push active job count metric for dashboard visibility (issue #416)
  push_metric "ActiveJobs" "$total_active" "Count"

  if [ "$total_active" -ge $CIRCUIT_BREAKER_LIMIT ]; then
    log "CIRCUIT BREAKER TRIGGERED: $total_active active jobs (limit: $CIRCUIT_BREAKER_LIMIT). BLOCKING spawn."
    post_thought "Circuit breaker: $total_active active jobs >= $CIRCUIT_BREAKER_LIMIT. Spawn blocked." "blocker" 10
    push_metric "CircuitBreakerTriggered" 1
    return 1
  fi
  
  # Calculate next generation number by reading current agent's generation label
  local my_generation=$(kubectl_with_timeout 10 get agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
  # Handle non-numeric generation (e.g., "next" from old code) by defaulting to 0
  if ! [[ "$my_generation" =~ ^[0-9]+$ ]]; then
    my_generation=0
  fi
  local next_generation=$((my_generation + 1))
  
  # Get identity signature for logging (if identity system is active)
  local identity_sig="${AGENT_NAME}"
  if [ -n "${AGENT_DISPLAY_NAME:-}" ] && [ "$AGENT_DISPLAY_NAME" != "$AGENT_NAME" ]; then
    identity_sig="$AGENT_DISPLAY_NAME ($AGENT_NAME)"
  fi
  
  log "Spawning successor: name=$name role=$role task=$task_ref gen=$next_generation reason=$reason"
  log "Identity: $identity_sig → $name (gen $my_generation → $next_generation)"
  local err_output
  err_output=$(timeout 10s kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Agent
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    agentex/spawned-by: ${AGENT_NAME}
    agentex/generation: "${next_generation}"
spec:
  role: "${role}"
  taskRef: "${task_ref}"
  model: "${BEDROCK_MODEL}"
  swarmRef: "${SWARM_REF}"
  priority: 5
EOF
) || {
    log "ERROR: CRITICAL - Failed to create Agent CR $name: $err_output"
    log "ERROR: System perpetuation may be broken. Emergency spawn may trigger."
    return 0  # Don't fail immediately - let emergency spawn handle it
  }
  
  # POST-SPAWN VERIFICATION (issue #364, #490): TOCTOU race condition mitigation
  # Re-check circuit breaker after spawn. If we raced and exceeded limit, delete BOTH Agent CR and Job.
  # This provides eventual consistency - not atomic, but catches most race conditions.
  sleep 1  # Brief delay to let API server state stabilize
  local post_spawn_active=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
  
  if [ "$post_spawn_active" -ge "$CIRCUIT_BREAKER_LIMIT" ]; then
    log "POST-SPAWN VERIFICATION FAILED: $post_spawn_active active jobs after spawn (limit: $CIRCUIT_BREAKER_LIMIT). TOCTOU race detected!"
    
    # CRITICAL (issue #490): Must delete the Job, not just the Agent CR
    # kro creates the Job immediately - deleting only the Agent CR leaves orphaned Job running
    log "Retrieving Job name for Agent $name before cleanup..."
    local job_name=$(kubectl_with_timeout 10 get agent.kro.run "$name" -n "$NAMESPACE" -o jsonpath='{.status.jobName}' 2>/dev/null)
    
    log "Deleting Agent CR $name to restore system stability..."
    kubectl delete agent.kro.run "$name" -n "$NAMESPACE" 2>/dev/null || true
    
    # Delete the Job kro created (if it exists)
    if [ -n "$job_name" ]; then
      log "Deleting Job $job_name associated with Agent $name (TOCTOU race cleanup)..."
      kubectl delete job "$job_name" -n "$NAMESPACE" 2>/dev/null || true
    else
      log "WARNING: Could not determine Job name for Agent $name. Job may be orphaned."
    fi
    
    post_thought "TOCTOU race: deleted Agent $name and Job $job_name after detecting $post_spawn_active active jobs (limit: $CIRCUIT_BREAKER_LIMIT)" "blocker" 8
    return 1
  fi
  
  log "Post-spawn verification passed: $post_spawn_active active jobs (limit: $CIRCUIT_BREAKER_LIMIT)"
}

# Create a Task CR and immediately spawn an Agent to work it.
spawn_task_and_agent() {
  local task_name="$1" agent_name="$2" role="$3" title="$4" desc="$5" effort="${6:-M}" issue="${7:-0}" swarm_ref="${8:-}"
  log "Creating Task $task_name and Agent $agent_name (role=$role)"

  # DUPLICATE WORK PREVENTION (issue #439): Check if issue already has open PR
  if [ "$issue" != "0" ] && [ "$issue" -gt 0 ] 2>/dev/null; then
    local existing_pr=$(gh pr list --repo "$REPO" --state open --search "#${issue}" --json number --jq '.[0].number // ""' 2>/dev/null || echo "")
    if [ -n "$existing_pr" ]; then
      log "DUPLICATE DETECTION: Issue #${issue} already has open PR #${existing_pr}. Skipping spawn."
      post_thought "Skipped spawning worker for issue #${issue}: PR #${existing_pr} already open. Prevents duplicate work." "observation" 8
      return 0
    fi
    
    # Also check for active Task CRs with same githubIssue (work in-progress)
    local existing_task=$(kubectl get tasks.kro.run -n "$NAMESPACE" -o json 2>/dev/null | \
      jq -r --arg issue "$issue" '.items[] | 
        select(.spec.githubIssue == ($issue | tonumber) and 
               (.status.phase != "Done" and .status.phase != "Cancelled")) | 
        .metadata.name' 2>/dev/null | head -1)
    if [ -n "$existing_task" ]; then
      log "DUPLICATE DETECTION: Issue #${issue} already has active Task ${existing_task}. Skipping spawn."
      post_thought "Skipped spawning worker for issue #${issue}: Task ${existing_task} already in-progress. Prevents duplicate work." "observation" 8
      return 0
    fi
  fi

  local err_output
  err_output=$(timeout 10s kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Task
metadata:
  name: ${task_name}
  namespace: ${NAMESPACE}
spec:
  title: "${title}"
  description: "${desc}"
  role: "${role}"
  effort: "${effort}"
  githubIssue: ${issue}
  swarmRef: "${swarm_ref}"
  priority: 5
EOF
) || {
    log "CRITICAL: Failed to create Task CR $task_name: $err_output"
    log "CRITICAL: Cannot spawn Agent without Task. Perpetuation chain broken."
    push_metric "AgentFailure" 1
    return 1
  }
  push_metric "TaskCreated" 1
  
  # Propagate spawn_agent return code (circuit breaker may block)
  if ! spawn_agent "$agent_name" "$role" "$task_name" "$title"; then
    log "CRITICAL: spawn_agent blocked (circuit breaker). Task CR created but Agent CR not spawned."
    return 1
  fi
  return 0
}

# ── 3. Announce startup ───────────────────────────────────────────────────────
log "Agent starting. Role=$AGENT_ROLE Task=$TASK_CR_NAME Model=$BEDROCK_MODEL"
push_metric "AgentRun" 1

# ── 3.5. Rolling restart check (issue #266) ───────────────────────────────────
# Check if a rolling restart has been triggered (new runner image deployed).
# If forceRestart timestamp is newer than this agent's start time, exit gracefully
# so emergency perpetuation spawns a replacement with the new image.
AGENT_START_TIME=$(ts)
RESTART_SIGNAL=$(kubectl_with_timeout 10 get configmap agentex-runner-version -n "$NAMESPACE" \
  -o jsonpath='{.data.forceRestart}' 2>/dev/null || echo "0")

if [ -n "$RESTART_SIGNAL" ] && [ "$RESTART_SIGNAL" -gt "$AGENT_START_TIME" ]; then
  log "Rolling restart triggered (signal=$RESTART_SIGNAL, start=$AGENT_START_TIME). Exiting for upgrade..."
  post_thought "Rolling restart: exiting to upgrade to new runner version" "observation" 9
  post_message "broadcast" "Rolling restart: $AGENT_NAME exiting for runner upgrade" "status"
  patch_task_status "Done" "Rolling restart triggered"
  exit 0  # Emergency perpetuation will spawn replacement with new image
fi

# ── 4. Process inbox ──────────────────────────────────────────────────────────
log "Processing inbox..."
INBOX_MESSAGES=""
INBOX_JSON=$(kubectl_with_timeout 10 get messages -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')

DIRECT_MSGS=$(echo "$INBOX_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[] | select(.spec.to == $name and (.status.read == "false" or .status.read == null)) |
   "FROM:\(.spec.from) TYPE:\(.spec.messageType)\n\(.spec.body)\n---"' 2>/dev/null || true)

BROADCAST_MSGS=$(echo "$INBOX_JSON" | jq -r \
  '.items[] | select(.spec.to == "broadcast" and (.status.read == "false" or .status.read == null)) |
   "FROM:\(.spec.from) TYPE:\(.spec.messageType)\n\(.spec.body)\n---"' 2>/dev/null || true)

# Cross-swarm messages: addressed to "swarm:<swarm-name>"
SWARM_MSGS=""
if [ -n "$SWARM_REF" ]; then
  SWARM_MSGS=$(echo "$INBOX_JSON" | jq -r \
    --arg swarm "swarm:${SWARM_REF}" \
    '.items[] | select(.spec.to == $swarm and (.status.read == "false" or .status.read == null)) |
     "FROM:\(.spec.from) TYPE:\(.spec.messageType) [SWARM]\n\(.spec.body)\n---"' 2>/dev/null || true)
fi

if [ -n "$DIRECT_MSGS" ] || [ -n "$BROADCAST_MSGS" ] || [ -n "$SWARM_MSGS" ]; then
  INBOX_MESSAGES=$(printf "=== INBOX ===\n%s\n%s\n%s\n=============\n" "$DIRECT_MSGS" "$BROADCAST_MSGS" "$SWARM_MSGS")
fi

# Mark all unread messages as read by patching the ConfigMap backing each Message CR
for msg_name in $(echo "$INBOX_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  --arg swarm "swarm:${SWARM_REF}" \
  '.items[] | select((.spec.to == $name or .spec.to == "broadcast" or .spec.to == $swarm) and (.status.read == "false" or .status.read == null)) | .metadata.name' \
  2>/dev/null || true); do
  # Patch the ConfigMap, not the Message CR. kro status fields are output-only.
  # Use timeout to prevent 120s hangs if cluster API is unreachable (issue #458)
  timeout 10s kubectl patch configmap "${msg_name}-msg" -n "$NAMESPACE" \
    --type=merge -p '{"data":{"read":"true"}}' 2>/dev/null || true
done

# ── 5. Peer thoughts (shared context) ────────────────────────────────────────
# Get the last 10 thoughts from other agents, excluding ones we've already read
# CRITICAL: Must sort by creationTimestamp to get the actual LAST 10 thoughts
# Bug #89: .items[-10:] on unsorted output may return random 10, not the latest 10
# Optimization #117: Fetch only the last 50 thoughts instead of all thoughts for better performance
THOUGHTS_JSON=$(kubectl_with_timeout 10 get thoughts.kro.run -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp --limit=50 -o json 2>/dev/null || echo '{"items":[]}')
PEER_THOUGHTS=$(echo "$THOUGHTS_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[-10:] | .[] | 
   select(.spec.agentRef != $name) |
   select((.status.readBy // "" | contains($name)) == false) |
   "[\(.spec.agentRef)/\(.spec.thoughtType)/c=\(.spec.confidence)]: \(.spec.content)"' \
  2>/dev/null || true)

# Mark thoughts as read by this agent (patch ConfigMap backing the Thought CR)
# Note: We already fetched limited thoughts above, so this loop processes max 50 items
for thought_name in $(echo "$THOUGHTS_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[-10:] | .[] | 
   select(.spec.agentRef != $name) |
   select((.status.readBy // "" | contains($name)) == false) |
   .metadata.name' \
  2>/dev/null || true); do
  # Get current readBy value from ConfigMap and append this agent's name
  CURRENT_READ_BY=$(kubectl get configmap "${thought_name}-thought" -n "$NAMESPACE" \
    -o jsonpath='{.data.readBy}' 2>/dev/null || echo "")
  if [ -z "$CURRENT_READ_BY" ]; then
    NEW_READ_BY="$AGENT_NAME"
  else
    NEW_READ_BY="${CURRENT_READ_BY},${AGENT_NAME}"
  fi
  # Use timeout to prevent 120s hangs if cluster API is unreachable (issue #458)
  timeout 10s kubectl patch configmap "${thought_name}-thought" -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"readBy\":\"${NEW_READ_BY}\"}}" 2>/dev/null || true
done

# ── 5b. S3 Historical Thoughts (long-term memory) ─────────────────────────────
# Supplement in-cluster thoughts with recent historical thoughts from S3
# This provides context across cluster restarts and preserves institutional memory
if aws s3 ls s3://agentex-thoughts/ >/dev/null 2>&1; then
  S3_THOUGHTS=""
  
  # Get the 20 most recent thought files from S3 (sorted by modification time)
  S3_FILES=$(aws s3 ls s3://agentex-thoughts/ --recursive 2>/dev/null | \
    sort -k1,2 | tail -20 | awk '{print $4}' || true)
  
  # Read each thought file and format for display (exclude our own thoughts)
  for s3_key in $S3_FILES; do
    THOUGHT_DATA=$(aws s3 cp "s3://agentex-thoughts/${s3_key}" - 2>/dev/null || echo "{}")
    
    # Extract fields and format like in-cluster thoughts
    THOUGHT_AGENT=$(echo "$THOUGHT_DATA" | jq -r '.agentRef // "unknown"' 2>/dev/null || echo "unknown")
    
    # Skip our own thoughts
    if [ "$THOUGHT_AGENT" != "$AGENT_NAME" ]; then
      THOUGHT_TYPE=$(echo "$THOUGHT_DATA" | jq -r '.thoughtType // "observation"' 2>/dev/null || echo "observation")
      THOUGHT_CONF=$(echo "$THOUGHT_DATA" | jq -r '.confidence // 7' 2>/dev/null || echo "7")
      THOUGHT_CONTENT=$(echo "$THOUGHT_DATA" | jq -r '.content // ""' 2>/dev/null || echo "")
      
      if [ -n "$THOUGHT_CONTENT" ]; then
        S3_THOUGHTS="${S3_THOUGHTS}[${THOUGHT_AGENT}/${THOUGHT_TYPE}/c=${THOUGHT_CONF}] (S3): ${THOUGHT_CONTENT}
"
      fi
    fi
  done
  
  # Combine in-cluster and S3 thoughts (prioritize in-cluster as they're more recent)
  if [ -n "$S3_THOUGHTS" ]; then
    if [ -n "$PEER_THOUGHTS" ]; then
      PEER_THOUGHTS="${PEER_THOUGHTS}

=== S3 HISTORICAL CONTEXT ===
${S3_THOUGHTS}"
    else
      PEER_THOUGHTS="=== S3 HISTORICAL CONTEXT ===
${S3_THOUGHTS}"
    fi
  fi
fi

# ── 6. Read Task CR ───────────────────────────────────────────────────────────
log "Reading task CR..."
TASK_JSON=$(kubectl get tasks.kro.run "$TASK_CR_NAME" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
TASK_TITLE=$(echo "$TASK_JSON" | jq -r '.spec.title // "No title"')
TASK_DESC=$(echo "$TASK_JSON" | jq -r '.spec.description // ""')
TASK_CONTEXT=$(echo "$TASK_JSON" | jq -r '.spec.context // ""')
TASK_ISSUE=$(echo "$TASK_JSON" | jq -r '.spec.githubIssue // 0')
TASK_EFFORT=$(echo "$TASK_JSON" | jq -r '.spec.effort // "M"')

log "Task: $TASK_TITLE (effort=$TASK_EFFORT issue=#$TASK_ISSUE)"
patch_task_status "InProgress"
post_message "broadcast" "Starting: $TASK_TITLE" "status"
post_thought "Task received: $TASK_TITLE. Beginning work." "observation" 8

# ── 7. Clone repo ─────────────────────────────────────────────────────────────
log "Cloning repo..."
gh auth setup-git
mkdir -p "$WORKSPACE/repo"
git clone "https://github.com/$REPO.git" "$WORKSPACE/repo" --depth=1
cd "$WORKSPACE/repo"

# ── 8. Configure OpenCode ─────────────────────────────────────────────────────
mkdir -p "${HOME}/.config/opencode"
# permission: "allow" disables all interactive prompts — required for headless operation.
# external_directory defaults to "ask" which would block bash writing to /tmp, /workspace.
cat > "${HOME}/.config/opencode/config.json" <<CONFIG
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "amazon-bedrock/${BEDROCK_MODEL}",
  "permission": "allow"
}
CONFIG

# ── 9. Build OpenCode prompt ──────────────────────────────────────────────────
ISSUE_LINE=""
[ "$TASK_ISSUE" != "0" ] && ISSUE_LINE="GitHub Issue: #${TASK_ISSUE} — gh issue view ${TASK_ISSUE} --repo ${REPO}"

SWARM_LINE=""
[ -n "$SWARM_REF" ] && SWARM_LINE="Swarm: ${SWARM_REF} — kubectl get configmap ${SWARM_REF}-state -n ${NAMESPACE} -o yaml"

PEER_BLOCK=""
[ -n "$PEER_THOUGHTS" ] && PEER_BLOCK="=== PEER THOUGHTS ===
${PEER_THOUGHTS}
====================="

# The perpetuation manifest embedded in every prompt.
# This is how the loop carries itself forward through every generation.
PERPETUATION_MANIFEST=$(cat <<'MANIFEST'
═══════════════════════════════════════════════════════
THE PRIME DIRECTIVE — READ THIS FIRST, OBEY IT LAST
═══════════════════════════════════════════════════════

You are an instance of a self-improving AI agent system called agentex.
The system's primary project is ITSELF. You develop the platform that runs you.

The human who built this system does NOT want to keep interacting with it.
Your job is to make that possible — by ensuring the system NEVER STOPS.

BEFORE YOU EXIT, YOU MUST DO ALL OF THE FOLLOWING:

① SPAWN YOUR SUCCESSOR
  Create a Task CR + Agent CR for the next agent to continue the work.
  The Agent CR is what triggers a new pod via kro. A Task CR alone does nothing.

  **MANDATORY: Check circuit breaker before spawning to prevent proliferation.**

  # STEP 1: CIRCUIT BREAKER — Prevent catastrophic proliferation (issue #338)
  # This check is MANDATORY. DO NOT skip it. OpenCode agents MUST execute this.
  # Count total active jobs across all roles to detect system overload.

  # Read circuit breaker limit from constitution (never hardcode!)
  CIRCUIT_BREAKER_LIMIT=\$(kubectl get configmap agentex-constitution -n agentex \\
    -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "15")
  if ! [[ "\$CIRCUIT_BREAKER_LIMIT" =~ ^[0-9]+\$ ]]; then CIRCUIT_BREAKER_LIMIT=15; fi

  ACTIVE_JOBS=\$(kubectl get jobs -n agentex -o json | \\
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length')

  echo "Circuit breaker check: \$ACTIVE_JOBS active jobs (limit: \$CIRCUIT_BREAKER_LIMIT)"

  if [ "\$ACTIVE_JOBS" -ge \$CIRCUIT_BREAKER_LIMIT ]; then
    echo "⚠️  CIRCUIT BREAKER ACTIVATED: \$ACTIVE_JOBS active jobs >= \$CIRCUIT_BREAKER_LIMIT"
    echo "System is overloaded. NOT spawning successor."
    echo "The civilization will pause to let load decrease."
    echo "Emergency perpetuation will spawn if this is the last agent."
    
    # Post a blocker thought so other agents know
    kubectl apply -f - <<EOF
  apiVersion: kro.run/v1alpha1
  kind: Thought
  metadata:
    name: thought-circuit-breaker-\$(date +%s)
    namespace: agentex
  spec:
    agentRef: "\${AGENT_NAME:-unknown}"
    taskRef: "\${TASK_CR_NAME:-unknown}"
    thoughtType: blocker
    confidence: 10
    content: |
      Circuit breaker activated: \$ACTIVE_JOBS active jobs >= \$CIRCUIT_BREAKER_LIMIT.
      Agent \${AGENT_NAME:-unknown} NOT spawning successor.
      System will stabilize before new spawns.
  EOF
    
    # Exit without spawning - emergency perpetuation will handle liveness if needed
    exit 0
  fi

  echo "✓ Circuit breaker passed: safe to spawn"

  # STEP 2: Determine next agent role and name
  NEXT_ROLE="planner"  # or worker/reviewer/architect - choose based on what work is needed
  NEXT_NAME="\${NEXT_ROLE}-\$(date +%s)"

  # STEP 3: Create Task CR
  # Task CR (defines the work) — use kro.run/v1alpha1
  kubectl apply -f - <<EOF
  apiVersion: kro.run/v1alpha1
  kind: Task
  metadata:
    name: task-\${NEXT_NAME}
    namespace: agentex
  spec:
    title: "<what to do>"
    description: "<detailed instructions including: spawn YOUR OWN successor before exiting>"
    role: \${NEXT_ROLE}
    effort: M
    priority: 5
    swarmRef: ""  # optional: set to swarm name if this task belongs to a swarm
  EOF

  # STEP 4: Create Agent CR (triggers the Job via kro)
  # MUST use kro.run/v1alpha1 (NOT agentex.io). kro watches kro.run group.
  # Calculate next generation: read your generation label and add 1
  MY_GEN=\$(kubectl get agent.kro.run \${AGENT_NAME} -n agentex \\
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
  NEXT_GEN=\$((MY_GEN + 1))

  kubectl apply -f - <<EOF
  apiVersion: kro.run/v1alpha1
  kind: Agent
  metadata:
    name: \${NEXT_NAME}
    namespace: agentex
    labels:
      agentex/spawned-by: \${AGENT_NAME}
      agentex/generation: "\${NEXT_GEN}"
  spec:
    role: \${NEXT_ROLE}
    taskRef: task-\${NEXT_NAME}
    model: us.anthropic.claude-sonnet-4-5-20250929-v1:0
  EOF

② FIND AND FIX ONE PLATFORM IMPROVEMENT
  Read: manifests/rgds/*.yaml, images/runner/entrypoint.sh, AGENTS.md
  Identify one improvement. Create a GitHub Issue for it.
  If effort is S (< 1 hour): implement it NOW in a branch+PR.
  The improvement can be anything: RGD fix, runner logic, new capability,
  better error handling, cost reduction, security hardening.

  ROLE ESCALATION: If you discover a structural/architectural problem with
  the platform (RGD bugs, kro issues, system design flaws), post a Thought CR
  with thoughtType=blocker mentioning "structural" or "architecture". The
  runner will automatically escalate your successor to architect role.

③ TELL YOUR SUCCESSOR WHAT YOU LEARNED
  Post a Thought CR with type=insight before exiting:
  kubectl apply -f - <<EOF
  apiVersion: kro.run/v1alpha1
  kind: Thought
  metadata:
    name: thought-<your-name>-insight-$(date +%s)
    namespace: agentex
  spec:
    agentRef: <your-name>
    taskRef: <your-task>
    thoughtType: insight
    confidence: 9
    content: |
      What I did: ...
      What I found: ...
      What the next agent should do: ...
      Open issues to pick up: #N, #N
  EOF

④ MARK YOUR TASK DONE
  kubectl patch configmap <your-task-cr>-spec -n agentex --type=merge \
    -p '{"data":{"phase":"Done","completedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}'

⑤ FILE YOUR REPORT (the god-observer reads these to steer the civilization)
  kubectl apply -f - <<EOF
  apiVersion: kro.run/v1alpha1
  kind: Report
  metadata:
    name: report-<your-name>-$(date +%s)
    namespace: agentex
  spec:
    agentRef: <your-name>
    taskRef: <your-task>
    role: <your-role>
    status: completed
    visionScore: <1-10: how aligned was your work with the long-term vision?>
    workDone: |
      - <bullet: what you accomplished>
    issuesFound: "#N, #N"
    prOpened: "PR #N"
    blockers: "<anything blocking the civilization>"
    nextPriority: "<what the next agent should prioritize>"
    generation: <your generation number from Agent CR label agentex/generation>
    exitCode: 0
  EOF

  visionScore guide: 10=swarms/memory/persistent identity (foundational capabilities),
  7=role escalation/dashboard/cross-agent debate (platform capabilities),
  5=platform stability, 3=bug fixes only, 1=emergency perpetuation only.

THE SYSTEM MUST NEVER IDLE. IF YOU EXIT WITHOUT SPAWNING A SUCCESSOR,
THE ENTIRE PLATFORM STOPS. TREAT THIS AS A CRITICAL FAILURE.
═══════════════════════════════════════════════════════
MANIFEST
)

PROMPT=$(cat <<PROMPT
${PERPETUATION_MANIFEST}

═══════════════════════════════════════════════════════
CIVILIZATION CONTEXT (from constitution)
═══════════════════════════════════════════════════════
Generation: ${CIVILIZATION_GENERATION}
Circuit Breaker: ${CIRCUIT_BREAKER_LIMIT} active jobs max

Vision:
${CIVILIZATION_VISION}

Use this vision to self-assess your work alignment (visionScore in Report).
Check generation to prioritize generation-appropriate work.

═══════════════════════════════════════════════════════
YOUR IDENTITY
═══════════════════════════════════════════════════════
Agent name:  ${AGENT_NAME}
Role:        ${AGENT_ROLE}
Task CR:     ${TASK_CR_NAME}
Model:       ${BEDROCK_MODEL}
Namespace:   ${NAMESPACE}
Repo:        ${REPO}
${SWARM_LINE}

═══════════════════════════════════════════════════════
YOUR TASK
═══════════════════════════════════════════════════════
Title:  ${TASK_TITLE}
Effort: ${TASK_EFFORT}
${ISSUE_LINE}

Description:
${TASK_DESC}

Context:
${TASK_CONTEXT}

${INBOX_MESSAGES}

${PEER_BLOCK}

═══════════════════════════════════════════════════════
TOOLS AVAILABLE
═══════════════════════════════════════════════════════
- kubectl  (read/write CRs in namespace agentex)
- gh       (authenticated to ${REPO})
- git      (repo at /workspace/repo)
- aws      (Bedrock via Pod Identity — no credentials needed)
- opencode (you are running inside it right now)

═══════════════════════════════════════════════════════
GIT RULES
═══════════════════════════════════════════════════════
- NEVER push to main. Branch: issue-N-description or feat-description
- Always open a PR. The CI builds the runner image on merge.
- Work in: mkdir -p /workspace/issue-N && git clone https://github.com/${REPO} /workspace/issue-N

NOW BEGIN. Do the task. Then do ①②③④ above. In that order.
PROMPT
)

# ── 9.5. PRE-EXECUTION CIRCUIT BREAKER ────────────────────────────────────────
# CRITICAL (issue #465): Check circuit breaker BEFORE running OpenCode.
# If system is overloaded, agent should exit gracefully WITHOUT executing work.
# This prevents "thundering herd" where 31+ agents all try to spawn successors.
PRE_EXEC_ACTIVE=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")

log "Pre-execution circuit breaker check: $PRE_EXEC_ACTIVE active jobs (limit: $CIRCUIT_BREAKER_LIMIT)"

if [ "$PRE_EXEC_ACTIVE" -ge $CIRCUIT_BREAKER_LIMIT ]; then
  log "CIRCUIT BREAKER ACTIVE: System overloaded ($PRE_EXEC_ACTIVE >= $CIRCUIT_BREAKER_LIMIT). Exiting gracefully."
  post_thought "Circuit breaker active at agent startup: $PRE_EXEC_ACTIVE active jobs >= $CIRCUIT_BREAKER_LIMIT. Agent exiting without work to reduce load." "blocker" 10
  push_metric "CircuitBreakerPreemptiveExit" 1
  patch_task_status "Skipped" "Circuit breaker active - system overloaded"
  post_message "broadcast" "Circuit breaker: $AGENT_NAME exiting without work (load too high)" "status"
  post_report 1 "Agent exited without work due to circuit breaker" "" "" "System overload: $PRE_EXEC_ACTIVE active jobs" "" 0
  
  log "Exiting gracefully. Emergency perpetuation will NOT spawn successor (circuit breaker blocks it)."
  exit 0
fi

log "Circuit breaker check passed. Proceeding with OpenCode execution."

# ── 10. Run OpenCode ───────────────────────────────────────────────────────────
log "Running OpenCode..."
post_thought "Starting OpenCode execution. Task: $TASK_TITLE" "decision" 9

echo "$PROMPT" | opencode run --print-logs 2>&1 | tee /tmp/opencode-output.txt
OPENCODE_EXIT=${PIPESTATUS[1]}

# ── 11. Post results ──────────────────────────────────────────────────────────
if [ "$OPENCODE_EXIT" -eq 0 ]; then
  log "OpenCode completed successfully"
  patch_task_status "Done" "Completed successfully"
  post_message "broadcast" "Done: $TASK_TITLE (agent=$AGENT_NAME)" "status"
  post_thought "Task finished. Successor should be spawned." "observation" 9
  post_report 8 "$TASK_TITLE completed successfully" "" "" "" "" 0
else
  log "OpenCode exited with code $OPENCODE_EXIT"
  patch_task_status "Done" "exit=$OPENCODE_EXIT"
  post_message "broadcast" "Finished (exit=$OPENCODE_EXIT): $TASK_TITLE" "status"
  post_thought "OpenCode exited $OPENCODE_EXIT. Activating emergency perpetuation." "observation" 4
  push_metric "AgentFailure" 1
  post_report 3 "Agent failed with exit code $OPENCODE_EXIT" "" "" "Agent execution failure" "" "$OPENCODE_EXIT"
fi

# ── 11.5. ROLE ESCALATION ─────────────────────────────────────────────────────
# Check if this agent discovered a structural issue that requires architect-level intervention.
# If so, the successor should be spawned with role=architect instead of the default role.
ESCALATED_ROLE=""

# Check all Thought CRs posted by THIS agent during this run for structural blockers
BLOCKER_THOUGHTS=$(kubectl get thoughts.kro.run -n "$NAMESPACE" \
  -l "agentex/agent=$AGENT_NAME" \
  -o json 2>/dev/null | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[] | 
   select(.spec.agentRef == $name and .spec.thoughtType == "blocker") |
   .spec.content' 2>/dev/null || true)

# Look for keywords that indicate structural problems requiring architecture changes
if echo "$BLOCKER_THOUGHTS" | grep -qiE '(structural|architecture|RGD|kro.*bug|system.*design|breaking.*change)'; then
  log "ROLE ESCALATION TRIGGERED: Structural issue detected in blocker thoughts"
  ESCALATED_ROLE="architect"
  post_thought "Role escalation triggered: $AGENT_ROLE → architect (structural issue found)" "decision" 9
  post_message "broadcast" "Role escalation: $AGENT_NAME discovered structural issue, next agent will be architect" "status"
fi

# ── 12. EMERGENCY PERPETUATION ────────────────────────────────────────────────
# If OpenCode failed to spawn a successor Agent CR, do it here unconditionally.
# This is the last line of defense against the system going dark.

# Check if THIS agent spawned a successor by filtering on the spawned-by label.
# This is precise and avoids false positives from other agents' spawns.
SUCCESSOR_AGENTS=$(kubectl get agents.kro.run -n "$NAMESPACE" \
  -l "agentex/spawned-by=$AGENT_NAME" \
  -o json 2>/dev/null || echo '{"items":[]}')
SPAWNED_BY_ME=$(echo "$SUCCESSOR_AGENTS" | jq '.items | length' 2>/dev/null || echo "0")

NEEDS_EMERGENCY_SPAWN=false
EMERGENCY_REASON=""

if [ "$SPAWNED_BY_ME" -eq 0 ]; then
  log "WARNING: No successor Agent CR created. Activating emergency perpetuation."
  NEEDS_EMERGENCY_SPAWN=true
  EMERGENCY_REASON="No Agent CR created"
  post_thought "Emergency perpetuation triggered — OpenCode did not spawn a successor." "blocker" 3
else
  # Agent CR(s) exist, but verify kro actually created Job(s) for them
  # Issue #54: Agent CR can exist but kro may fail to create the Job
  log "Found $SPAWNED_BY_ME successor Agent CR(s). Verifying Jobs were created by kro..."
  
  JOBS_VERIFIED=0
  for agent_name in $(echo "$SUCCESSOR_AGENTS" | jq -r '.items[].metadata.name' 2>/dev/null || true); do
    # Check if Agent CR has status.jobName populated by kro
    # Issue #474: Use .kro.run API group (not default agentex.io)
    JOB_NAME=$(kubectl get agent.kro.run "$agent_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.jobName}' 2>/dev/null || echo "")
    
    if [ -z "$JOB_NAME" ]; then
      log "WARNING: Agent CR $agent_name exists but status.jobName is empty (kro hasn't processed it yet)"
      # Give kro a moment to process the Agent CR (it may be in progress)
      sleep 5
      JOB_NAME=$(kubectl get agent.kro.run "$agent_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.jobName}' 2>/dev/null || echo "")
    fi
    
    if [ -z "$JOB_NAME" ]; then
      log "ERROR: Agent CR $agent_name still has no Job after 5s wait. kro may be down or RGD is broken."
      NEEDS_EMERGENCY_SPAWN=true
      EMERGENCY_REASON="Agent CR exists but kro didn't create Job (kro down or RGD error)"
      post_thought "Critical: Agent CR $agent_name created but kro failed to create Job. Possible kro failure or RGD syntax error." "blocker" 2
      break
    fi
    
    # Verify the Job actually exists
    if kubectl get job "$JOB_NAME" -n "$NAMESPACE" &>/dev/null; then
      log "✓ Agent CR $agent_name → Job $JOB_NAME exists"
      JOBS_VERIFIED=$((JOBS_VERIFIED + 1))
    else
      log "ERROR: Agent CR $agent_name has status.jobName=$JOB_NAME but Job doesn't exist"
      NEEDS_EMERGENCY_SPAWN=true
      EMERGENCY_REASON="Job referenced by Agent CR doesn't exist"
      post_thought "Critical: Agent CR $agent_name references Job $JOB_NAME but Job not found. kro may have failed." "blocker" 2
      break
    fi
  done
  
  if [ "$JOBS_VERIFIED" -gt 0 ] && [ "$NEEDS_EMERGENCY_SPAWN" = false ]; then
    log "Successor verification passed: $JOBS_VERIFIED Job(s) confirmed. No emergency perpetuation needed."
  fi
fi

if [ "$NEEDS_EMERGENCY_SPAWN" = true ]; then
  log "EMERGENCY PERPETUATION ACTIVATED: $EMERGENCY_REASON"

  # EMERGENCY KILL SWITCH (issue #210): Check if all spawning is disabled
  KILLSWITCH=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
  if [ "$KILLSWITCH" = "true" ]; then
    KILLSWITCH_REASON=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" -o jsonpath='{.data.reason}' 2>/dev/null || echo "unknown")
    log "EMERGENCY KILL SWITCH ACTIVE: $KILLSWITCH_REASON. NOT spawning successor."
    post_thought "Kill switch active: $KILLSWITCH_REASON. Agent exiting without spawning successor to stop proliferation." "blocker" 10
    NEEDS_EMERGENCY_SPAWN=false
    # Don't exit - let the agent finish reporting
  fi

  TS=$(ts)
  NEXT_TASK="task-continue-${TS}"

  # Determine what the next agent should do:
  # If role escalation was triggered, use that; otherwise cycle through roles
  if [ -n "$ESCALATED_ROLE" ]; then
    NEXT_ROLE="$ESCALATED_ROLE"
    log "Using escalated role: $NEXT_ROLE"
  else
    # Default role cycling to ensure the platform keeps improving itself
    case "$AGENT_ROLE" in
      worker)    NEXT_ROLE="planner" ;;
      planner)   NEXT_ROLE="worker" ;;
      reviewer)  NEXT_ROLE="worker" ;;
      architect) NEXT_ROLE="worker" ;;
      *)         NEXT_ROLE="worker" ;;
    esac
  fi

  # Set agent name to match role (fix for issue #111)
  NEXT_AGENT="${NEXT_ROLE}-${TS}"

  # CIRCUIT BREAKER (issue #338, #352): Same logic as spawn_agent.
  # Count active Jobs. Agent CRs never get completionTime set by kro.
  # Use kubectl_with_timeout for consistency with spawn_agent (issue #491)
  TOTAL_ACTIVE=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")

  # Push active job count metric for dashboard visibility (issue #416)
  push_metric "ActiveJobs" "$TOTAL_ACTIVE" "Count"

  if [ "$TOTAL_ACTIVE" -ge $CIRCUIT_BREAKER_LIMIT ]; then
    log "CIRCUIT BREAKER: $TOTAL_ACTIVE active jobs (limit: $CIRCUIT_BREAKER_LIMIT). Blocking emergency spawn."
    post_thought "Emergency spawn blocked: $TOTAL_ACTIVE active jobs >= $CIRCUIT_BREAKER_LIMIT." "blocker" 10
    push_metric "CircuitBreakerTriggered" 1
    NEEDS_EMERGENCY_SPAWN=false
  fi

  if [ "$NEEDS_EMERGENCY_SPAWN" = true ]; then
    spawn_task_and_agent \
      "$NEXT_TASK" \
      "$NEXT_AGENT" \
      "$NEXT_ROLE" \
      "Self-improvement cycle: audit and improve agentex platform" \
      "You are a $NEXT_ROLE agent in the agentex self-improvement loop.
Your predecessor was $AGENT_NAME (role=$AGENT_ROLE, task=$TASK_CR_NAME).

Do the following:
1. Read AGENTS.md, manifests/rgds/*.yaml, images/runner/entrypoint.sh
2. Read open GitHub issues: gh issue list --repo $REPO --state open --limit 20
3. Pick the highest-priority open issue and implement a fix or feature
4. Open a PR with your changes
5. Create a GitHub Issue for any NEW improvement you discover
6. SPAWN YOUR OWN SUCCESSOR before exiting (see Prime Directive in your prompt)

The system must never idle. You are responsible for keeping it alive." \
      "M" \
      "0" \
      "$SWARM_REF"

    log "Emergency successor spawned: Agent=$NEXT_AGENT Task=$NEXT_TASK Role=$NEXT_ROLE Running=${RUNNING_AGENTS} Reason=$EMERGENCY_REASON"
  fi
fi

# ── 13. Update Swarm state ────────────────────────────────────────────────────
if [ -n "$SWARM_REF" ]; then
  log "Updating swarm state: $SWARM_REF"
  
  # Get current state
  SWARM_STATE=$(kubectl get configmap "${SWARM_REF}-state" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
  CURRENT_TASKS=$(echo "$SWARM_STATE" | jq -r '.data.tasksCompleted // "0"')
  CURRENT_PHASE=$(echo "$SWARM_STATE" | jq -r '.data.phase // "Forming"')
  CURRENT_MEMBERS=$(echo "$SWARM_STATE" | jq -r '.data.memberAgents // ""')
  CURRENT_TIMESTAMP=$(echo "$SWARM_STATE" | jq -r '.data.lastActivityTimestamp // ""')
  
  # Add this agent to member list if not already present
  if ! echo "$CURRENT_MEMBERS" | grep -q "$AGENT_NAME"; then
    if [ -z "$CURRENT_MEMBERS" ]; then
      NEW_MEMBERS="$AGENT_NAME"
    else
      NEW_MEMBERS="${CURRENT_MEMBERS},${AGENT_NAME}"
    fi
  else
    NEW_MEMBERS="$CURRENT_MEMBERS"
  fi
  
  # Increment tasks completed
  NEW_TASKS=$(( CURRENT_TASKS + 1 ))
  
  # Check task completion status BEFORE updating timestamp
  # This prevents resetting the idle timer when all tasks are already done
  SWARM_TASKS=$(kubectl get tasks -n "$NAMESPACE" -l "agentex/swarm=${SWARM_REF}" -o json 2>/dev/null || echo '{"items":[]}')
  TOTAL_TASKS=$(echo "$SWARM_TASKS" | jq '.items | length')
  DONE_TASKS=$(echo "$SWARM_TASKS" | jq '[.items[] | select(.status.phase == "Done")] | length')
  PENDING_TASKS=$(( TOTAL_TASKS - DONE_TASKS ))
  
  log "Swarm $SWARM_REF: $DONE_TASKS/$TOTAL_TASKS tasks done, $PENDING_TASKS pending"
  
  # Only update timestamp if there are pending tasks
  # If all tasks are done, preserve the existing timestamp so idle timer can accumulate
  if [ "$PENDING_TASKS" -gt 0 ]; then
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "Swarm still has pending tasks - updating activity timestamp"
  else
    # All tasks done - preserve timestamp to allow dissolution
    if [ -z "$CURRENT_TIMESTAMP" ]; then
      # First time all tasks are done - set timestamp to mark completion
      TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      log "All swarm tasks complete - setting final activity timestamp"
    else
      # Keep existing timestamp so idle counter accumulates
      TIMESTAMP="$CURRENT_TIMESTAMP"
      log "All tasks already complete - preserving timestamp for dissolution check"
    fi
  fi
  
  # Patch swarm state
  # Use timeout to prevent 120s hangs if cluster API is unreachable (issue #458)
  timeout 10s kubectl patch configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"tasksCompleted\":\"${NEW_TASKS}\",\"memberAgents\":\"${NEW_MEMBERS}\",\"lastActivityTimestamp\":\"${TIMESTAMP}\"}}" \
    2>/dev/null || true
  
  # Re-fetch swarm state after patching to ensure dissolution check uses current data
  SWARM_STATE=$(kubectl get configmap "${SWARM_REF}-state" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
  CURRENT_PHASE=$(echo "$SWARM_STATE" | jq -r '.data.phase // "Forming"')
  
  # Check for dissolution condition (only if not already disbanded)
  if [ "$CURRENT_PHASE" != "Disbanded" ]; then
    # Dissolution condition: all tasks done AND no activity for 5 minutes
    if [ "$PENDING_TASKS" -eq 0 ] && [ "$TOTAL_TASKS" -gt 0 ]; then
      if [ -n "$TIMESTAMP" ]; then
        LAST_EPOCH=$(date -d "$TIMESTAMP" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        IDLE_SECONDS=$(( NOW_EPOCH - LAST_EPOCH ))
        
        # 300 seconds = 5 minutes idle threshold
        if [ "$IDLE_SECONDS" -gt 300 ]; then
          log "SWARM DISSOLUTION: $SWARM_REF has completed all tasks and been idle for ${IDLE_SECONDS}s"
          
          # Update phase to Disbanded
          # Use timeout to prevent 120s hangs if cluster API is unreachable (issue #458)
          timeout 10s kubectl patch configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
            --type=merge -p '{"data":{"phase":"Disbanded"}}' 2>/dev/null || true
          
          # Broadcast dissolution message
          post_message "broadcast" "Swarm $SWARM_REF has disbanded after completing all tasks. Members: $NEW_MEMBERS. Total tasks: $TOTAL_TASKS." "status"
          
          # Post thought about dissolution
          post_thought "Swarm $SWARM_REF dissolved. Goal achieved. All $TOTAL_TASKS tasks completed." "insight" 9
        else
          log "All tasks complete but only ${IDLE_SECONDS}s idle (need 300s for dissolution)"
        fi
      fi
    fi
  fi
fi

log "Agent exiting. Task=$TASK_CR_NAME Role=$AGENT_ROLE"
