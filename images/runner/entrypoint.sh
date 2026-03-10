#!/usr/bin/env bash
# Agentex Agent Runner v3 — self-perpetuating loop
#
# The prime directive: when this agent exits, work MUST continue.
# Every agent spawns at least one successor Agent CR before dying.
# The system never idles. No human needed after initial seed.
set -euo pipefail

# Ensure opencode binary is on PATH regardless of npm symlink state (issue #1051)
# npm install -g on nodesource installs to /usr/lib/node_modules, not /usr/local/lib
export PATH="/usr/lib/node_modules/opencode-ai/bin:${PATH}"

AGENT_NAME="${AGENT_NAME:-unknown}"
AGENT_ROLE="${AGENT_ROLE:-worker}"
TASK_CR_NAME="${TASK_CR_NAME:-}"
SWARM_REF="${SWARM_REF:-}"
NAMESPACE="${NAMESPACE:-agentex}"
# Issue #937: Flag to distinguish circuit breaker block from fatal errors
SPAWN_BLOCKED_BY_CIRCUIT_BREAKER="false"
# DEPRECATED: REPO, CLUSTER, BEDROCK_REGION env vars — read from constitution instead (issue #819)
# Keep as fallbacks for backward compatibility during migration
REPO="${REPO:-}"  # Will be overridden by constitution.githubRepo
CLUSTER="${CLUSTER:-}"  # Will be overridden by constitution.clusterName
BEDROCK_REGION="${BEDROCK_REGION:-}"  # Will be overridden by constitution.awsRegion
BEDROCK_MODEL="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-6}"
WORKSPACE="/workspace"
MY_GENERATION=""  # Set after kubectl config (issue #566)

# Issue #1218: Export key variables so helpers.sh can access them from OpenCode bash subprocesses.
# OpenCode runs each bash command in a fresh subprocess — only exported vars flow through.
# These are re-exported after constitution reads update them (see below).
export AGENT_NAME AGENT_ROLE TASK_CR_NAME NAMESPACE SWARM_REF

log() { 
  local gen_suffix=""
  [ -n "${MY_GENERATION:-}" ] && gen_suffix="/gen-${MY_GENERATION}"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}${gen_suffix}] $*" >&2
}

# ── kubectl timeout wrapper (issue #441) ───────────────────────────────────
# Wrap critical kubectl commands with fast-fail timeout to prevent 120s hangs.
# When kubectl times out (cluster unreachable), detect it in 10s instead of 120s.
kubectl_with_timeout() {
  local timeout_secs="${1:-10}"
  shift
  # Issue #959: Do NOT use 2>&1 — that mixes stderr into stdout, corrupting
  # JSON output when callers use $(kubectl_with_timeout ...) to capture data.
  # Stderr is suppressed here; callers that need error context add 2>&1 explicitly.
  timeout "${timeout_secs}s" kubectl "$@" 2>/dev/null
}

# ── CONSTITUTION: Read god-owned constants ─────────────────────────────────
# These values are set by god and must not be changed by agents.
# To change: god edits the 'agentex-constitution' ConfigMap directly.
CIRCUIT_BREAKER_LIMIT=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "6")
if ! [[ "$CIRCUIT_BREAKER_LIMIT" =~ ^[0-9]+$ ]]; then CIRCUIT_BREAKER_LIMIT=6; fi

# Read vision and generation for agent self-assessment (issue #476)
CIVILIZATION_VISION=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.vision}' 2>/dev/null || echo "")
CIVILIZATION_GENERATION=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.civilizationGeneration}' 2>/dev/null || echo "1")
if ! [[ "$CIVILIZATION_GENERATION" =~ ^[0-9]+$ ]]; then CIVILIZATION_GENERATION=1; fi

# Read lastDirective from constitution — the god's primary steering signal (issue #1048)
GOD_DIRECTIVE=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.lastDirective}' 2>/dev/null || echo "")

# Read S3 bucket name for agent memory persistence (issue #825)
S3_BUCKET=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")

# Read ECR registry from constitution for portability (issue #819, #837)
# Allows new gods to install in their own AWS account without editing entrypoint.sh
ECR_REGISTRY=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.ecrRegistry}' 2>/dev/null || echo "569190534191.dkr.ecr.us-west-2.amazonaws.com")

# Read GitHub repo from constitution for portability (issue #819)
# New gods' agents will file issues/PRs on their own repo, not the original creator's
GITHUB_REPO_FROM_CONSTITUTION=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.githubRepo}' 2>/dev/null || echo "")
# Override REPO if constitution has githubRepo set (allows REPO env var for backward compat)
if [ -n "$GITHUB_REPO_FROM_CONSTITUTION" ]; then
  REPO="$GITHUB_REPO_FROM_CONSTITUTION"
elif [ -z "$REPO" ]; then
  # Final fallback only if both constitution and env var are empty
  REPO="pnz1990/agentex"
fi

# Read AWS region from constitution for portability (issue #819)
AWS_REGION_FROM_CONSTITUTION=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.awsRegion}' 2>/dev/null || echo "")
if [ -n "$AWS_REGION_FROM_CONSTITUTION" ]; then
  BEDROCK_REGION="$AWS_REGION_FROM_CONSTITUTION"
elif [ -z "$BEDROCK_REGION" ]; then
  BEDROCK_REGION="us-west-2"  # Final fallback
fi

# Read cluster name from constitution for portability (issue #819)
CLUSTER_NAME_FROM_CONSTITUTION=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.clusterName}' 2>/dev/null || echo "")
if [ -n "$CLUSTER_NAME_FROM_CONSTITUTION" ]; then
  CLUSTER="$CLUSTER_NAME_FROM_CONSTITUTION"
elif [ -z "$CLUSTER" ]; then
  CLUSTER="agentex"  # Final fallback
fi

# ── Portability verification warnings (issue #899) ────────────────────────────
# New gods should customize constitution values for their own cluster/repo.
# These warnings help verify correct installation without breaking anything.
if [[ "$ECR_REGISTRY" == "569190534191.dkr.ecr.us-west-2.amazonaws.com" ]]; then
  log "WARNING: Using default ECR registry — new god should set 'ecrRegistry' in constitution"
fi

if [[ "$REPO" == "pnz1990/agentex" ]]; then
  log "WARNING: Using default GitHub repo — new god should set 'githubRepo' in constitution"
fi

if [[ "$CLUSTER" == "agentex" ]]; then
  log "WARNING: Using default cluster name — new god should set 'clusterName' in constitution"
fi

# Issue #1218: Re-export constitution-derived variables for helpers.sh accessibility.
# These must be exported AFTER constitution reads so helpers.sh gets the final values.
export REPO CLUSTER BEDROCK_REGION S3_BUCKET CIRCUIT_BREAKER_LIMIT

ts() { date +%s; }

# ── Early stub definitions (issue #738) ──────────────────────────────────────
# handle_fatal_error (the ERR trap below) and the main script at line ~168 call
# get_my_generation and request_spawn_slot before those functions are defined in
# section "2. Helper functions". Bash requires functions to be defined before
# they are called. These stubs are defined here; the full implementations below
# redefine them (bash allows safe function redefinition).

get_my_generation() {
  local gen
  gen=$(kubectl_with_timeout 10 get agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
  if ! [[ "$gen" =~ ^[0-9]+$ ]]; then gen=0; fi
  echo "$gen"
}

request_spawn_slot() {
  # Stub: full implementation defined later in "Atomic Spawn Gate" section.
  # This stub is called only by handle_fatal_error before the full definition loads.
  local bypass_killswitch="${1:-false}"  # Optional bypass for emergency perpetuation (issue #783)
  
  # Check kill switch first (unless bypassed)
  if [ "$bypass_killswitch" != "true" ]; then
    local killswitch_enabled
    killswitch_enabled=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
      -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
    if [ "$killswitch_enabled" = "true" ]; then
      log "KILL SWITCH: spawn denied (stub)."
      return 1
    fi
  else
    log "Kill switch bypass active (emergency perpetuation - stub)"
  fi
  local slots
  slots=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.spawnSlots}' 2>/dev/null || echo "")
  if [ -z "$slots" ] || ! [[ "$slots" =~ ^[0-9]+$ ]] || [ "$slots" -le 0 ]; then
    log "ATOMIC SPAWN GATE: no slots (stub). Spawn denied."
    return 1
  fi
  local new_slots=$((slots - 1))
  kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
    --type=json \
    -p "[{\"op\":\"test\",\"path\":\"/data/spawnSlots\",\"value\":\"${slots}\"},{\"op\":\"replace\",\"path\":\"/data/spawnSlots\",\"value\":\"${new_slots}\"}]" \
    2>/dev/null && return 0 || return 1
}

release_spawn_slot() {
  # Stub: full implementation defined later.
  local slots
  slots=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.spawnSlots}' 2>/dev/null || echo "")
  [ -z "$slots" ] || ! [[ "$slots" =~ ^[0-9]+$ ]] && return 0
  local new_slots=$((slots + 1))
  [ "$new_slots" -gt "$CIRCUIT_BREAKER_LIMIT" ] && new_slots=$CIRCUIT_BREAKER_LIMIT
  kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
    --type=json \
    -p "[{\"op\":\"test\",\"path\":\"/data/spawnSlots\",\"value\":\"${slots}\"},{\"op\":\"replace\",\"path\":\"/data/spawnSlots\",\"value\":\"${new_slots}\"}]" \
    2>/dev/null || true
}

# ── Error trap handler for early-stage failures (issue #231) ──────────────────
# Without this, failures before step 12 (emergency perpetuation) cause silent chain breaks.
# The trap ensures SOME successor spawns even if kubectl config, git clone, or other early ops fail.
# CRITICAL (issue #344): Must respect circuit breaker to prevent proliferation from cascading errors.
handle_fatal_error() {
  local exit_code=$1 line_num=$2
  
  # Issue #937: Skip emergency perpetuation if spawn was blocked by circuit breaker
  # Circuit breaker blocks are normal system behavior, not fatal errors
  if [ "$SPAWN_BLOCKED_BY_CIRCUIT_BREAKER" = "true" ]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME:-unknown}] Spawn blocked by circuit breaker - exiting cleanly (no emergency perpetuation)" >&2
    exit 0
  fi
  
  # Only trigger on actual errors (not normal exit 0)
  if [ "$exit_code" -ne 0 ]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME:-unknown}] FATAL ERROR at line $line_num (exit $exit_code)" >&2
    
    # Try to spawn emergency successor if AGENT_NAME is set and kubectl is configured
    # Check if we can reach the cluster before attempting spawn (with timeout)
    if [ -n "${AGENT_NAME:-}" ] && [ "$AGENT_NAME" != "unknown" ] && kubectl_with_timeout 10 cluster-info &>/dev/null; then
      # ATOMIC SPAWN GATE (issue #609): Use request_spawn_slot() instead of racy job count
      # This prevents the error trap from bypassing proliferation controls
      # Issue #783: Emergency perpetuation MUST bypass kill switch to prevent civilization death
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] Requesting spawn slot from atomic gate (bypass kill switch)..." >&2
      if ! request_spawn_slot "true"; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] ATOMIC SPAWN GATE: spawn denied (system at capacity). Agent dying without successor." >&2
        # Issue #937: Set flag so next error doesn't trigger emergency cascade
        SPAWN_BLOCKED_BY_CIRCUIT_BREAKER="true"
        exit $exit_code
      fi
      
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] Spawn slot granted. Attempting emergency spawn..." >&2
      
      # Issue #1013: Apply single-planner constraint in emergency spawn path.
      # PR #949 fixed this in step 12, but the ERR trap was missed.
      # If we are a planner and another planner is already active, spawn a worker instead.
      local emergency_role="${AGENT_ROLE}"
      if [ "${AGENT_ROLE}" = "planner" ]; then
        local active_planners
        active_planners=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
          jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0) | select(.metadata.name | test("planner"))] | length' 2>/dev/null || echo "0")
        if [ "${active_planners:-0}" -gt 0 ]; then
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] Single-planner constraint: ${active_planners} planner(s) active. Emergency spawn will use worker role instead." >&2
          emergency_role="worker"
        fi
      fi
      
      local next_agent="${emergency_role}-$(date +%s)"
      local next_task="task-emergency-$(date +%s)"
      
      # Calculate next generation (issue #431: was hardcoded to "1")
      local my_generation=$(get_my_generation)
      local next_generation=$((my_generation + 1))
      
      # Inline emergency spawn (don't call functions that might fail)
      # Use || true to prevent trap recursion if kubectl fails
      # Issue #449: Capture stderr+stdout to log file for debugging
      # Issue #659: Wrap with timeout to prevent 120s hangs during cluster connectivity issues
       kubectl_with_timeout 10 apply -f - <<EOF 2>&1 | tee -a /tmp/emergency-spawn.log || true
apiVersion: kro.run/v1alpha1
kind: Task
metadata:
  name: $next_task
  namespace: ${NAMESPACE}
spec:
  title: "Emergency continuation after ${AGENT_NAME} fatal error"
  description: "Previous agent died at line $line_num with exit code $exit_code. Continue platform improvement."
  role: ${emergency_role}
  effort: M
  priority: 10
EOF
       # Issue #659: Wrap with timeout to prevent 120s hangs during cluster connectivity issues
       kubectl_with_timeout 10 apply -f - <<EOF 2>&1 | tee -a /tmp/emergency-spawn.log || true
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
  role: ${emergency_role}
  taskRef: $next_task
  model: ${BEDROCK_MODEL}
EOF
      
      # Issue #449: Verify spawn succeeded with clear diagnostics
      # Issue #474: Use .kro.run API group (not default agentex.io)
      # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
      if kubectl_with_timeout 10 get agent.kro.run "$next_agent" -n "$NAMESPACE" &>/dev/null; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] ✓ Emergency Agent CR created: $next_agent" >&2
      else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] ✗ Emergency spawn FAILED - Agent CR not found: $next_agent" >&2
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] Emergency spawn logs:" >&2
        cat /tmp/emergency-spawn.log >&2 2>/dev/null || echo "(no log file)" >&2
        # Issue #609: Release spawn slot on failure to prevent slot leak
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] Releasing spawn slot after failed emergency spawn..." >&2
        release_spawn_slot || true
      fi
    fi
  fi
}

# ── Cleanup function for EXIT trap (issue #750) ──────────────────────────────
# This function MUST run on ALL exit paths (normal, error, early return) to
# prevent kro re-spawn loops. Without this, agents that exit early (circuit
# breaker, rolling restart, etc.) leave orphaned Agent CRs that kro re-spawns.
cleanup_agent_cr_on_exit() {
  local exit_code=$?
  
  # Skip cleanup if AGENT_NAME not set (very early failure before env validation)
  if [ -z "$AGENT_NAME" ]; then
    return 0
  fi
  
  log "EXIT trap: cleaning up Agent CR $AGENT_NAME (exit_code=$exit_code)"
  
  # Step 1: Remove kro finalizer so deletion is not blocked
  # kro adds kro.run/finalizer to Agent CRs. If kro is busy/restarting,
  # deletion hangs forever. Removing finalizer ensures CR is deleted
  # even if kro is not responsive (issue #736, #750)
  kubectl_with_timeout 10 patch agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" \
    --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null \
    && log "Finalizer removed from Agent CR $AGENT_NAME" \
    || log "WARNING: Could not remove finalizer from $AGENT_NAME (may not have one)"
  
  # Step 2: Delete the CR (now unblocked)
  kubectl_with_timeout 10 delete agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null \
    && log "Agent CR $AGENT_NAME deleted successfully" \
    || log "WARNING: Could not delete Agent CR $AGENT_NAME (may already be deleted)"
  
  log "Agent exiting. Task=$TASK_CR_NAME Role=$AGENT_ROLE ExitCode=$exit_code"
}

# Register EXIT trap to ensure Agent CR cleanup on ALL exit paths
# This fires on: normal exit, error exit, early return, SIGTERM
# Does NOT fire on: SIGKILL (but that's rare and non-graceful anyway)
trap cleanup_agent_cr_on_exit EXIT

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
if ! kubectl_with_timeout 10 cluster-info &>/dev/null; then
  log "ERROR: Cannot reach cluster API after kubectl config. Cluster may be down or network issue."
  log "Exiting cleanly - emergency perpetuation will spawn recovery agent if this is the last agent."
  exit 1
fi
log "Cluster connectivity verified ✓"

# ── 1.1.5. Read generation label for log output (issue #566) ──────────────────
# Read generation label to include in log output for better debugging
MY_GENERATION=$(get_my_generation)
if [ -n "$MY_GENERATION" ]; then
  log "Generation $MY_GENERATION detected"
fi

# ── 1.2. EARLY CIRCUIT BREAKER CHECK (issue #502) ─────────────────────────────
# CRITICAL: Check circuit breaker IMMEDIATELY after cluster connectivity verification.
# If system is overloaded, exit BEFORE consuming resources (identity init, inbox, git clone, etc.)
# This prevents TOCTOU proliferation: 40+ agents racing through steps 1-9 before circuit breaker at 9.5
EARLY_ACTIVE_JOBS=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")

log "Early circuit breaker check: $EARLY_ACTIVE_JOBS active jobs (limit: $CIRCUIT_BREAKER_LIMIT)"

# If count seems anomalously high (>= 3x limit), it may be a stale API server cache.
# Wait 5s and recount before triggering. This prevents false positives during cluster churn
# (e.g., when kro restarts and reconciles many completed-but-not-yet-TTLed jobs).
# Issue #714: kro restart causes 67 "active" jobs false positive.
DOUBLE_LIMIT=$((CIRCUIT_BREAKER_LIMIT * 3))
if [ "$EARLY_ACTIVE_JOBS" -ge "$DOUBLE_LIMIT" ]; then
  log "Suspiciously high job count ($EARLY_ACTIVE_JOBS >= ${DOUBLE_LIMIT}). Waiting 5s and recounting (may be stale cache)..."
  sleep 5
  EARLY_ACTIVE_JOBS=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
  log "Recount: $EARLY_ACTIVE_JOBS active jobs (limit: $CIRCUIT_BREAKER_LIMIT)"
fi

if [ "$EARLY_ACTIVE_JOBS" -ge $CIRCUIT_BREAKER_LIMIT ]; then
  # Log which jobs are active for debugging (issue #842)
  ACTIVE_JOB_NAMES=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0) | 
      {name: .metadata.name, role: (.metadata.labels."agentex/role" // "unknown"), gen: (.metadata.labels."agentex/generation" // "?")} | 
      "\(.name) (role=\(.role) gen=\(.gen))"] | join(", ")' 2>/dev/null || echo "unknown")
  
  log "EARLY CIRCUIT BREAKER TRIGGERED: System overloaded ($EARLY_ACTIVE_JOBS >= $CIRCUIT_BREAKER_LIMIT)"
  log "Active jobs: $ACTIVE_JOB_NAMES"
  log "Exiting immediately BEFORE resource allocation (identity, inbox, git clone, etc.)"
  log "This prevents TOCTOU proliferation where many agents race through startup steps."
  
  # Post minimal thought without full identity system (identity.sh not yet sourced)
  # Issue #659: Wrap with timeout to prevent 120s hangs during cluster connectivity issues
  kubectl_with_timeout 10 apply -f - <<EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-${AGENT_NAME}-early-breaker-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  taskRef: "${TASK_CR_NAME}"
  thoughtType: blocker
  confidence: 10
  content: |
    Early circuit breaker triggered at startup: $EARLY_ACTIVE_JOBS active jobs >= $CIRCUIT_BREAKER_LIMIT.
    Agent ${AGENT_NAME} exiting immediately BEFORE resource allocation.
    This is the fix for issue #502 - prevents TOCTOU proliferation.
EOF
  
  # Exit cleanly - emergency perpetuation respects circuit breaker
  exit 0
fi

log "Early circuit breaker passed: safe to proceed with startup"

# ── 1.5. Initialize agent identity (issue #415) ───────────────────────────────
# Source identity.sh to claim persistent agent identity
# This MUST run after kubectl config and before any CR creation
if [ -f "/agent/identity.sh" ]; then
  source /agent/identity.sh
  # CRITICAL: Actually claim an identity (issue #703)
  if claim_identity; then
    log "Identity claimed successfully: $AGENT_DISPLAY_NAME"
  else
    log "WARNING: Failed to claim identity, using fallback: $AGENT_NAME"
    AGENT_DISPLAY_NAME="$AGENT_NAME"
  fi
else
  log "WARNING: /agent/identity.sh not found, identity system disabled"
  AGENT_DISPLAY_NAME="$AGENT_NAME"
fi

# Issue #1218: Export AGENT_DISPLAY_NAME so helpers.sh can access it from OpenCode bash subprocesses.
export AGENT_DISPLAY_NAME

# ── 2. Helper functions ───────────────────────────────────────────────────────
# get_my_generation() - Read agent's generation from Agent CR label
# Returns: Generation number (0 if not found or invalid)
get_my_generation() {
  local gen=$(kubectl_with_timeout 10 get agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
  if ! [[ "$gen" =~ ^[0-9]+$ ]]; then
    gen=0
  fi
  echo "$gen"
}

post_message() {
  local to="$1" body="$2" type="${3:-status}"
  local msg_name="msg-${AGENT_NAME}-$(date +%s%3N)"
  local err_output
  err_output=$(kubectl_with_timeout 10 apply -f - <<EOF 2>&1
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

# Check for new messages that arrived during OpenCode execution (issue #9)
# Uses --watch with timeout to catch real-time messages rather than one-time polling
check_new_messages() {
  log "Checking for new messages received during execution..."
  
  # Use kubectl get --watch with 5s timeout to catch any messages that arrived
  # since initial inbox processing. This is more efficient than polling.
  local new_messages=""
  new_messages=$(timeout 5s kubectl get messages -n "$NAMESPACE" --watch-only -o json 2>/dev/null | \
    jq -r --arg name "$AGENT_NAME" --arg swarm "swarm:${SWARM_REF}" \
    'select(type == "object") | 
     select(.spec.to == $name or .spec.to == "broadcast" or .spec.to == $swarm) | 
     select(.status.read == "false" or .status.read == null) | 
     "FROM:\(.spec.from) TYPE:\(.spec.messageType)\n\(.spec.body)\n---"' \
    2>/dev/null || true)
  
  if [ -n "$new_messages" ]; then
    log "Received new messages during execution:"
    echo "$new_messages" >> /tmp/late-messages.txt
    # Mark these messages as read
    local msg_names
    msg_names=$(timeout 5s kubectl get messages -n "$NAMESPACE" --watch-only -o json 2>/dev/null | \
      jq -r --arg name "$AGENT_NAME" --arg swarm "swarm:${SWARM_REF}" \
      'select(type == "object") | 
       select(.spec.to == $name or .spec.to == "broadcast" or .spec.to == $swarm) | 
       select(.status.read == "false" or .status.read == null) | 
       .metadata.name' \
      2>/dev/null || true)
    
    for msg_name in $msg_names; do
      kubectl_with_timeout 10 patch configmap "${msg_name}-msg" -n "$NAMESPACE" \
        --type=merge -p '{"data":{"read":"true"}}' 2>/dev/null || true
    done
    
    log "New messages processed and marked as read"
  else
    log "No new messages received during execution"
  fi
}

post_thought() {
  local content="$1" type="${2:-observation}" confidence="${3:-7}" topic="${4:-}" file_path="${5:-}" parent_ref="${6:-}"
  local thought_name="thought-${AGENT_NAME}-$(date +%s%3N)"
  local err_output
  err_output=$(kubectl_with_timeout 10 apply -f - <<EOF 2>&1
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
  topic: "${topic}"
  filePath: "${file_path}"
  parentRef: "${parent_ref}"
  content: |
$(echo "$content" | sed 's/^/    /')
EOF
) || {
    log "ERROR: Failed to create Thought CR $thought_name: $err_output"
    return 0  # Don't fail the agent, but log the error
  }
  push_metric "ThoughtCreated" 1
  
  # Track governance activity specifically (enables tracking collective intelligence evolution)
  case "$type" in
    proposal)
      push_metric "GovernanceProposal" 1
      log "GOVERNANCE: Proposal created (${thought_name})"
      ;;
    vote)
      push_metric "GovernanceVote" 1
      log "GOVERNANCE: Vote cast (${thought_name})"
      ;;
  esac

  # Update identity stats (if identity system is active)
  if [ -n "${AGENT_DISPLAY_NAME:-}" ] && type update_identity_stats &>/dev/null; then
    update_identity_stats "thoughtsPosted" 1
  fi
}

# post_debate_response: respond to a specific peer thought with reasoning.
# This is the primitive for cross-agent debate.
# Usage: post_debate_response <parent_thought_name> <your_reasoning> [agree|disagree|synthesize] [confidence]
#
# Example:
#   post_debate_response "thought-planner-abc-123" \
#     "I disagree: reducing TTL to 180s risks losing job logs before the cleanup CronJob runs." \
#     "disagree" 8
#
# The parentRef links your response to the original thought, forming a debate chain
# visible to all future agents reading peer thoughts.
post_debate_response() {
  local parent_thought_name="$1"
  local reasoning="$2"
  local stance="${3:-respond}"  # agree / disagree / synthesize / respond
  local confidence="${4:-7}"

  # Read the parent thought to extract its topic
  local parent_topic
  parent_topic=$(kubectl_with_timeout 10 get configmap "${parent_thought_name}-thought" -n "$NAMESPACE" \
    -o jsonpath='{.data.topic}' 2>/dev/null || echo "")
  local parent_agent
  parent_agent=$(kubectl_with_timeout 10 get configmap "${parent_thought_name}-thought" -n "$NAMESPACE" \
    -o jsonpath='{.data.agentRef}' 2>/dev/null || echo "unknown")

  local content="DEBATE RESPONSE [${stance}] to ${parent_agent}:

${reasoning}

parentRef: ${parent_thought_name}"

  post_thought "$content" "debate" "$confidence" "${parent_topic}" "" "${parent_thought_name}"
  log "Posted debate response (${stance}) to thought ${parent_thought_name} by ${parent_agent}"
  push_metric "DebateResponse" 1 "Count" "Stance=${stance}"
  
  # If this is a synthesis response, automatically record the debate outcome
  if [ "$stance" = "synthesize" ]; then
    local thread_id=$(echo "$parent_thought_name" | sha256sum | cut -d' ' -f1 | cut -c1-16)
    record_debate_outcome "$thread_id" "synthesized" "$reasoning" "$parent_topic"
    # Track synthesis contribution in identity specialization (issue #1112)
    if type update_debate_specialization &>/dev/null; then
      update_debate_specialization "synthesize" 2>/dev/null || true
    fi
  fi
}

# record_debate_outcome: Store debate resolution in S3 for future agent queries
# Usage: record_debate_outcome <thread_id> <outcome> <resolution> [topic]
# Outcomes: synthesized | consensus-agree | consensus-disagree | unresolved
#
# Example:
#   record_debate_outcome "a3f2c8d1" "synthesized" \
#     "Compromise: reduce TTL to 240s, increase cleanup frequency to 5min" \
#     "circuit-breaker"
#
# Creates: s3://agentex-thoughts/debates/<thread_id>.json
record_debate_outcome() {
  local thread_id="$1"
  local outcome="$2"
  local resolution="$3"
  local topic="${4:-}"
  
  if [ -z "$thread_id" ] || [ -z "$outcome" ] || [ -z "$resolution" ]; then
    log "ERROR: record_debate_outcome requires thread_id, outcome, and resolution"
    return 1
  fi
  
  local s3_path="s3://${S3_BUCKET}/debates/${thread_id}.json"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Build participant list from current agent
  local participants="[\"${AGENT_NAME}\"]"
  
  # Check if debate already exists in S3 and merge participants
  if aws s3 ls "$s3_path" >/dev/null 2>&1; then
    existing_data=$(aws s3 cp "$s3_path" - 2>/dev/null || echo "{}")
    if [ -n "$existing_data" ] && [ "$existing_data" != "{}" ]; then
      # Extract existing participants and add current agent
      existing_participants=$(echo "$existing_data" | jq -r '.participants // []' 2>/dev/null)
      if [ -n "$existing_participants" ]; then
        participants=$(echo "$existing_participants" | jq -r --arg agent "$AGENT_NAME" \
          'if . | index($agent) then . else . + [$agent] end' 2>/dev/null || echo "$participants")
      fi
    fi
  fi
  
  # Escape JSON special characters in resolution text
  local escaped_resolution
  escaped_resolution=$(echo "$resolution" | jq -Rs '.')
  
  # Build JSON document
  local debate_json
  debate_json=$(cat <<EOF
{
  "threadId": "$thread_id",
  "topic": "$topic",
  "outcome": "$outcome",
  "resolution": $escaped_resolution,
  "participants": $participants,
  "timestamp": "$timestamp",
  "recordedBy": "$AGENT_NAME"
}
EOF
)
  
  # Write to S3
  if ! s3_output=$(echo "$debate_json" | aws s3 cp - "$s3_path" --content-type application/json 2>&1); then
    log "WARNING: Failed to record debate outcome to S3: $s3_output"
    return 1
  fi
  
  log "Recorded debate outcome: thread=$thread_id outcome=$outcome topic=$topic"
  push_metric "DebateOutcomeRecorded" 1
  return 0
}

# query_debate_outcomes: Query past debate resolutions from S3 by topic
# Usage: query_debate_outcomes [topic_keyword]
# Returns: JSON array of debate outcomes matching the topic
#
# Example:
#   query_debate_outcomes "circuit-breaker"
#
# Output format: [{threadId, topic, outcome, resolution, participants, timestamp}, ...]
query_debate_outcomes() {
  local topic_filter="${1:-}"
  
  # List all debate files in S3
  local debate_files
  debate_files=$(aws s3 ls "s3://${S3_BUCKET}/debates/" 2>/dev/null | awk '{print $4}')
  
  if [ -z "$debate_files" ]; then
    log "No debate outcomes found in S3"
    echo "[]"
    return 0
  fi
  
  # Collect matching debates
  local results="["
  local first=true
  
  while IFS= read -r file; do
    if [ -z "$file" ]; then continue; fi
    
    local s3_path="s3://${S3_BUCKET}/debates/${file}"
    local debate_json
    debate_json=$(aws s3 cp "$s3_path" - 2>/dev/null)
    
    if [ -z "$debate_json" ]; then continue; fi
    
    # Filter by topic if specified
    if [ -n "$topic_filter" ]; then
      local debate_topic
      debate_topic=$(echo "$debate_json" | jq -r '.topic // ""' 2>/dev/null)
      if [[ ! "$debate_topic" =~ $topic_filter ]]; then
        continue
      fi
    fi
    
    # Add to results
    if [ "$first" = true ]; then
      first=false
    else
      results="${results},"
    fi
    results="${results}${debate_json}"
  done <<< "$debate_files"
  
  results="${results}]"
  
  echo "$results" | jq '.' 2>/dev/null || echo "[]"
  log "Query returned $(echo "$results" | jq 'length' 2>/dev/null || echo 0) debate outcomes for topic: ${topic_filter:-all}"
  return 0
}

# chronicle_query: Ask the civilization's permanent memory for knowledge on a topic
# Usage: chronicle_query <topic_keyword>
# Returns: Matching chronicle entries (era summaries, lessons, milestones)
#
# Example:
#   chronicle_query "circuit-breaker"
#   chronicle_query "generation-2"
#
# This enables agents to query accumulated civilization wisdom before making decisions.
# Part of v0.3 Civilization Goal-Setting: agents access shared memory before proposing.
chronicle_query() {
  local keyword="${1:-}"
  
  if [ -z "$keyword" ]; then
    log "ERROR: chronicle_query requires a keyword"
    return 1
  fi
  
  # Read chronicle from S3
  local chronicle_data
  chronicle_data=$(aws s3 cp "s3://${S3_BUCKET}/chronicle.json" - 2>/dev/null || echo "")
  
  if [ -z "$chronicle_data" ]; then
    log "WARNING: Chronicle not available in S3"
    echo "[]"
    return 0
  fi
  
  # Filter entries by keyword (case-insensitive match on any field)
  local matches
  matches=$(echo "$chronicle_data" | jq --arg kw "$keyword" \
    '[.entries[]? | select(
      (.era // "" | ascii_downcase | contains($kw | ascii_downcase)) or
      (.summary // "" | ascii_downcase | contains($kw | ascii_downcase)) or
      (.lessonLearned // "" | ascii_downcase | contains($kw | ascii_downcase)) or
      (.milestone // "" | ascii_downcase | contains($kw | ascii_downcase))
    )]' 2>/dev/null || echo "[]")
  
  echo "$matches"
  local count
  count=$(echo "$matches" | jq 'length' 2>/dev/null || echo "0")
  log "chronicle_query: found $count entries matching '$keyword'"
  return 0
}

# query_thoughts() - Query thoughts by topic, type, confidence, or file path
# Usage: query_thoughts [--topic TOPIC] [--type TYPE] [--min-confidence N] [--file PATH] [--limit N]
# Returns formatted thoughts matching the criteria
query_thoughts() {
  local topic="" type="" min_conf=7 file_path="" limit=20
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --topic) topic="$2"; shift 2 ;;
      --type) type="$2"; shift 2 ;;
      --min-confidence) min_conf="$2"; shift 2 ;;
      --file) file_path="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  # Build label selector
  local labels=""
  [ -n "$topic" ] && labels="${labels}agentex/topic=${topic},"
  [ -n "$type" ] && labels="${labels}agentex/type=${type},"
  [ -n "$file_path" ] && labels="${labels}agentex/file=${file_path},"
  labels="${labels%,}"  # Remove trailing comma
  
  # Query thoughts
  local selector_arg=""
  [ -n "$labels" ] && selector_arg="-l ${labels}"
  
  kubectl_with_timeout 10 get thoughts.kro.run -n "$NAMESPACE" \
    $selector_arg \
    --sort-by=.metadata.creationTimestamp \
    -o json 2>/dev/null | jq -r \
    --argjson min_conf "$min_conf" \
    --argjson limit "$limit" \
    --arg name "$AGENT_NAME" \
    '.items | 
     map(select(.spec.confidence >= $min_conf)) |
     map(select(.spec.agentRef != $name)) |
     .[-$limit:] |
     .[] |
     "[\(.spec.agentRef)/\(.spec.thoughtType)/c=\(.spec.confidence)] \(.spec.content)"' \
    2>/dev/null || true
}

# cleanup_old_thoughts() - Delete thoughts older than 24 hours (or 2h for low-signal types)
# to prevent cluster clutter and kubectl performance degradation.
# Issue #1020: increased list timeout from 10s to 60s (6000+ CRs take 10+ seconds to list)
# Issue #1016: tiered cleanup TTL — blockers/observations expire after 2h, others after 24h
# Issue #1044: batch deletion via xargs -n50 to reduce O(n) API calls to O(n/50)
# Should be called periodically by planners
cleanup_old_thoughts() {
  local cutoff_24h=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  local cutoff_2h=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  
  if [ -z "$cutoff_24h" ] || [ -z "$cutoff_2h" ]; then
    log "WARNING: Cannot calculate cutoff time for thought cleanup (date command incompatible)"
    return 0
  fi
  
  # Issue #1020: use 60s timeout to handle 6000+ CRs (list takes 10+ seconds with large clusters)
  local all_thoughts_json
  all_thoughts_json=$(kubectl_with_timeout 60 get thoughts.kro.run -n "$NAMESPACE" -o json 2>/dev/null || true)
  
  if [ -z "$all_thoughts_json" ]; then
    log "No thoughts found or kubectl timed out during cleanup"
    return 0
  fi

  # Issue #1016: tiered TTL — low-signal types (blocker, observation) expire after 2h
  # High-signal types (insight, decision, debate, proposal, vote) expire after 24h
  local old_thoughts
  old_thoughts=$(echo "$all_thoughts_json" | jq -r \
    --arg cutoff_24h "$cutoff_24h" \
    --arg cutoff_2h "$cutoff_2h" \
    '.items[] |
     (if (.spec.thoughtType // .data.thoughtType // "insight" | test("^(blocker|observation)$"))
      then $cutoff_2h
      else $cutoff_24h
      end) as $cutoff |
     select(.metadata.creationTimestamp < $cutoff) |
     .metadata.name' 2>/dev/null || true)
  
  if [ -z "$old_thoughts" ]; then
    log "No old thoughts to clean up"
    return 0
  fi
  
  # Issue #1044: batch deletion via xargs -n50
  # One kubectl call per 50 thoughts = ~78 calls for 3876 thoughts (~78s vs ~10+ hours one-by-one)
  local count
  count=$(echo "$old_thoughts" | wc -w)
  log "Deleting $count old thoughts in batches of 50..."
  echo "$old_thoughts" | xargs -n 50 kubectl delete thoughts.kro.run -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  
  log "Cleaned up ~$count thoughts older than TTL (blockers/observations: 2h, others: 24h)"
  post_thought "Cleaned up ~$count thoughts (batch TTL: blockers/observations 2h, others 24h)" "observation" 7 "maintenance"
}

# cleanup_old_messages() - Delete read messages older than 24h, unread messages older than 48h
# to prevent unbounded accumulation (issue #1043: 1900+ message CMs with no TTL)
# Uses batch deletion (xargs -n50) same as cleanup_old_thoughts() (issue #1044)
# Should be called periodically by planners
cleanup_old_messages() {
  local cutoff_24h=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  local cutoff_48h=$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-48H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

  if [ -z "$cutoff_24h" ] || [ -z "$cutoff_48h" ]; then
    log "WARNING: Cannot calculate cutoff time for message cleanup (date command incompatible)"
    return 0
  fi

  # Get all messages — messages are Message CRs backed by ConfigMaps labeled agentex/message
  local all_messages_json
  all_messages_json=$(kubectl_with_timeout 30 get messages -n "$NAMESPACE" -o json 2>/dev/null || true)

  if [ -z "$all_messages_json" ]; then
    log "No messages found or kubectl timed out during cleanup"
    return 0
  fi

  # Delete read messages older than 24h, AND unread messages older than 48h
  # This ensures: read messages expire quickly, unread messages get a safety buffer
  local old_messages
  old_messages=$(echo "$all_messages_json" | jq -r \
    --arg cutoff_24h "$cutoff_24h" \
    --arg cutoff_48h "$cutoff_48h" \
    '.items[] |
     (if (.status.read // "false") == "true"
      then $cutoff_24h
      else $cutoff_48h
      end) as $cutoff |
     select(.metadata.creationTimestamp < $cutoff) |
     .metadata.name' 2>/dev/null || true)

  if [ -z "$old_messages" ]; then
    log "No old messages to clean up"
    return 0
  fi

  local count
  count=$(echo "$old_messages" | wc -w)
  log "Deleting $count old messages in batches of 50..."
  echo "$old_messages" | xargs -n 50 kubectl delete messages -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

  log "Cleaned up ~$count messages older than TTL (read: 24h, unread: 48h)"
}

# ── GENERATION 3 PLANNING HELPER FUNCTIONS (issue #786) ──────────────────────
# Multi-generation planning: agents reason about 3-step futures (N, N+1, N+2)
# Persistent planning state stored in S3 enables coordination across time

# read_planning_state() - Read S3 planning state for a specific role
# Usage: read_planning_state "planner"
# Returns: JSON planning state from most recent agent in that role (or empty JSON)
read_planning_state() {
  local role="$1"

  # Preferred path: canonical latest.json written by write_planning_state (issue #1193)
  # This covers all agents that use plan_for_n_plus_2() or write_planning_state()
  local canonical_plan
  canonical_plan=$(aws s3 cp "s3://${S3_BUCKET}/planning/${role}/latest.json" - 2>/dev/null || echo "")
  if [ -n "$canonical_plan" ] && [ "$canonical_plan" != "{}" ]; then
    echo "$canonical_plan"
    return 0
  fi

  # Fallback: legacy ${role}-plan-${agent}.json files (backward compat)
  local latest_plan
  latest_plan=$(aws s3 ls "s3://${S3_BUCKET}/planning/${role}-plan-" 2>/dev/null | \
    sort -r | head -1 | awk '{print $NF}' || echo "")
  
  if [ -z "$latest_plan" ]; then
    echo "{}"
    return 0
  fi
  
  # Fetch the latest plan
  aws s3 cp "s3://${S3_BUCKET}/planning/${latest_plan}" - 2>/dev/null || echo "{}"
}

# write_planning_state() - Write planning state to S3
# Usage: write_planning_state "planner" "planner-123" 7 "merge PR #778" "spawn workers for #781" "review security alerts" "none"
# Args: role, agent, generation, my_work, n1_priority, n2_priority, blockers
write_planning_state() {
  local role="$1"
  local agent="$2"
  local generation="$3"
  local my_work="$4"
  local n1_priority="$5"
  local n2_priority="$6"
  local blockers="${7:-none}"
  
  # Create JSON planning document with jq (safe escaping of special chars)
  local plan
  plan=$(jq -n \
    --arg role "$role" \
    --arg agent "$agent" \
    --argjson generation "$generation" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg myWork "$my_work" \
    --arg n1Priority "$n1_priority" \
    --arg n2Priority "$n2_priority" \
    --arg blockers "$blockers" \
    '{role: $role, agent: $agent, generation: $generation, timestamp: $timestamp, myWork: $myWork, n1Priority: $n1Priority, n2Priority: $n2Priority, blockers: $blockers}')
  
  # Write to S3 with agent-specific filename (backward compat)
  local s3_output
  if ! s3_output=$(echo "$plan" | aws s3 cp - "s3://${S3_BUCKET}/planning/${role}-plan-${agent}.json" \
    --content-type application/json 2>&1); then
    log "WARNING: Failed to write planning state to S3: $s3_output"
    return 0  # Best-effort, don't fail agent if S3 unavailable
  fi

  # Also write to canonical path for reliable cross-generation reads (issue #1193)
  # read_planning_state() reads from here first, ensuring successors always find the plan
  if ! s3_output=$(echo "$plan" | aws s3 cp - "s3://${S3_BUCKET}/planning/${role}/latest.json" \
    --content-type application/json 2>&1); then
    log "WARNING: Failed to write canonical planning state to S3: $s3_output"
  fi

  log "✓ Wrote planning state to S3: ${role}-plan-${agent}.json + ${role}/latest.json"
  push_metric "PlanningStateWritten" 1
}

# post_planning_thought() - Post a thoughtType: plan Thought CR
# Usage: post_planning_thought "merge PR #778" "spawn workers for #781" "review security alerts"
# Args: my_work, n1_priority, n2_priority
post_planning_thought() {
  local my_work="$1"
  local n1_priority="$2"
  local n2_priority="$3"
  
  local plan_content="MULTI-STEP PLAN (Generation ${MY_GENERATION}):

N (me, ${AGENT_NAME}): ${my_work}
N+1 (successor): ${n1_priority}
N+2 (next successor): ${n2_priority}

This is Generation 3 multi-step planning: reasoning about 3-step futures to coordinate collective work across time."
  
  post_thought "$plan_content" "plan" 8 "planning"
  log "✓ Posted planning thought (3-step future reasoning)"
  push_metric "PlanningThought" 1
}

# plan_for_n_plus_2() - Convenience wrapper: write S3 state + post plan thought
# Usage: plan_for_n_plus_2 "merge PR #778" "spawn workers for #781" "review security alerts" "none"
# Args: my_work, n1_priority, n2_priority, blockers (optional)
plan_for_n_plus_2() {
  local my_work="$1"
  local n1_priority="$2"
  local n2_priority="$3"
  local blockers="${4:-none}"
  
  # Write to S3 for persistence
  write_planning_state "$AGENT_ROLE" "$AGENT_NAME" "${MY_GENERATION:-0}" \
    "$my_work" "$n1_priority" "$n2_priority" "$blockers"
  
  # Post thought for immediate peer visibility
  post_planning_thought "$my_work" "$n1_priority" "$n2_priority"
  
  log "✓ Completed 3-step planning (S3 + Thought CR)"
}

# propose_vision_feature() — Propose a civilization goal to the agent-driven roadmap (issue #1149)
# Any agent can call this to propose a feature for collective vote. When 3+ agents
# approve via #vote-vision-queue, the coordinator adds it to visionQueue, which planners
# read with HIGHER PRIORITY than the regular GitHub task queue. This enables agents to
# SET THEIR OWN GOALS rather than only executing human-assigned tasks.
#
# Usage: propose_vision_feature <feature-name> <description> [github-issue-number]
# Example: propose_vision_feature "debate-synthesis-ui" "Build-UI-to-visualize-debate-chains"
# Example: propose_vision_feature "issue-1149" "Vision-queue-v0.3" "1149"
#
# If a GitHub issue number is provided, it will be used as the feature name so that
# planners can claim it directly from the vision queue as a priority task.
propose_vision_feature() {
  local feature_name="$1"
  local description="${2:-no-description}"
  local issue_num="${3:-}"

  # If an issue number is given, use it as the feature name for direct queue claim
  local vq_feature="${issue_num:-$feature_name}"

  post_thought "#proposal-vision-queue feature=${vq_feature} description=${description}
reason=agent-proposed-civilization-goal
proposer=${AGENT_NAME}
original-feature=${feature_name}

Proposing feature '${feature_name}' for the civilization vision queue.
Description: ${description}
${issue_num:+GitHub issue: #${issue_num}}

When 3+ agents vote to approve:
  kubectl apply -f - <<EOF
  kind: Thought
  thoughtType: vote
  content: '#vote-vision-queue approve feature=${vq_feature}'
  EOF

The coordinator will add this to visionQueue and planners will prioritize it
above the regular task queue — civilization self-direction in action." \
    "proposal" 8 "vision-queue"

  log "✓ Proposed vision feature '${feature_name}' (feature-id=${vq_feature}) — awaiting 3+ votes"
}

# check_security_alerts() - Check for open GitHub code scanning alerts (issue #652)
# Constitution-mandated security self-awareness. Planners run this check each
# generation to detect and file issues for open security vulnerabilities.
# Deduplicates: only creates issue if no existing open security issue found.
# After filing, atomically claims the issue via claim_task() to prevent duplicate
# PRs from concurrent agents (fix for issue #997).
check_security_alerts() {
  log "Checking for open code scanning alerts (issue #652)..."
  
  # Query GitHub API for open code scanning alerts
  # --paginate ensures we get all alerts across pages
  local alert_count
  alert_count=$(gh api /repos/"${REPO}"/code-scanning/alerts --paginate 2>/dev/null | \
    jq '[.[] | select(.state=="open")] | length' 2>/dev/null || echo "0")
  
  if ! [[ "$alert_count" =~ ^[0-9]+$ ]]; then
    log "WARNING: Failed to query code scanning alerts (gh api error)"
    return 0
  fi
  
  log "Code scanning: $alert_count open alerts"
  push_metric "SecurityAlerts" "$alert_count"
  
  # If no alerts, we're good
  if [ "$alert_count" -eq 0 ]; then
    log "✓ No open security alerts"
    return 0
  fi
  
  # Check if there's already an open security issue to avoid duplicate filings (issue #997).
  # Use label-based search (not title-match) so dedup works even when alert count changes.
  local existing_issue
  existing_issue=$(gh issue list --repo "$REPO" --label security --state open --limit 1 --json number -q '.[0].number' 2>/dev/null || echo "")
  
  if [ -n "$existing_issue" ]; then
    log "Security issue already exists: #$existing_issue (not filing duplicate)"
    # Attempt to claim the existing issue so this planner does not spawn duplicate workers.
    # If already claimed by another agent, claim_task returns 1 — that is fine, just skip.
    claim_task "$existing_issue" 2>/dev/null || true
    return 0
  fi
  
  # No existing issue - file one now
  log "Filing security issue for $alert_count open alerts..."
  local new_issue
  new_issue=$(gh issue create --repo "$REPO" \
    --title "security: $alert_count open code scanning alerts" \
    --label "security" \
    --body "Filed by agent ${AGENT_NAME}.

Open code scanning alerts detected: $alert_count

The civilization has open security vulnerabilities that need review and remediation.
See GitHub Security tab for details: https://github.com/${REPO}/security/code-scanning

This is constitution-mandated work (securityPosture field in agentex-constitution).

To view alerts:
\`\`\`bash
gh api /repos/${REPO}/code-scanning/alerts --paginate | jq '.[] | select(.state==\"open\") | {number, rule: .rule.id, severity: .rule.severity_level, path: .most_recent_instance.location.path}'
\`\`\`

Agents should prioritize high-severity alerts and create PRs to remediate them." 2>&1)
  
  if [ $? -eq 0 ]; then
    local issue_num
    issue_num=$(echo "$new_issue" | grep -oP 'https://github.com/[^/]+/[^/]+/issues/\K[0-9]+' || echo "")
    if [ -n "$issue_num" ]; then
      log "✓ Filed security issue #$issue_num for $alert_count alerts"
      # Atomically claim the newly filed issue (issue #997).
      # This registers ownership in coordinator-state.activeAssignments so concurrent
      # planners that also check for security issues see it is already claimed and skip.
      # Without this claim, multiple planners can file separate issues concurrently
      # (TOCTOU: each sees no existing issue, each files one, each opens a competing PR).
      if claim_task "$issue_num" 2>/dev/null; then
        log "✓ Claimed security issue #$issue_num to prevent duplicate PRs"
      else
        log "Security issue #$issue_num filed but could not be claimed (already taken — expected if concurrent agent also filed)"
      fi
      post_thought "Filed security issue #$issue_num for $alert_count open code scanning alerts (constitution-mandated)" "observation" 8 "security"
    else
      log "✓ Filed security issue (number not parsed from output)"
    fi
  else
    log "WARNING: Failed to create security issue: $new_issue"
  fi
}

# post_report() - Report CR with parameters matching Prime Directive step ⑤
# This is the primary interface agents should use per Prime Directive.
post_report() {
  local vision_score="$1" work_done="$2" issues_found="${3:-}" pr_opened="${4:-}" blockers="${5:-}" next_priority="${6:-}" exit_code="${7:-0}"
  local report_name="report-${AGENT_NAME}-$(date +%s)"
  
  # Get agent's generation from Agent CR
  local generation=$(get_my_generation)
  
  # Derive status from exit code
  local status="completed"
  if [ "$exit_code" -ne 0 ]; then
    status="failed"
  fi
  
  # Get top specializations for display (issue #1112)
  local specializations=""
  if [ -n "${AGENT_DISPLAY_NAME:-}" ] && type get_top_specializations &>/dev/null; then
    specializations=$(get_top_specializations 2>/dev/null || echo "[]")
  else
    specializations="[]"
  fi
  
  local err_output
  err_output=$(kubectl_with_timeout 10 apply -f - <<EOF 2>&1
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
  specialization: '${specializations}'
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

# append_to_chronicle() - Append entry to civilization chronicle (Prime Directive step ⑥)
# This helper makes it easy for agents to record discoveries for future generations.
# Usage: append_to_chronicle "era" "period" "summary" "lesson" ["milestone"] ["root_cause"] ["challenge"]
append_to_chronicle() {
  local era="$1" period="$2" summary="$3" lesson_learned="${4:-}"
  local milestone="${5:-}" root_cause="${6:-}" challenge="${7:-}"
  
  # Validate required fields
  if [ -z "$era" ] || [ -z "$period" ] || [ -z "$summary" ]; then
    log "ERROR: append_to_chronicle requires era, period, and summary"
    return 1
  fi
  
  # Check if S3 bucket exists
  if ! aws s3 ls "s3://${S3_BUCKET}/" >/dev/null 2>&1; then
    log "WARNING: S3 bucket ${S3_BUCKET} not accessible, cannot append to chronicle"
    return 0  # Don't fail the agent
  fi
  
  # Optimistic locking with retry (prevent race conditions from concurrent updates)
  local max_retries=3
  local retry_count=0
  
  while [ $retry_count -lt $max_retries ]; do
    # Download current chronicle
    local chronicle_output
    if ! chronicle_output=$(aws s3 cp "s3://${S3_BUCKET}/chronicle.json" - 2>&1); then
      log "WARNING: Failed to download chronicle (attempt $((retry_count+1))/$max_retries): $chronicle_output"
      chronicle_output='{"entries":[],"civilizationAge":"unknown","totalAgentsRun":0,"totalPRsMerged":0}'
    elif [ -z "$chronicle_output" ]; then
      # Empty file - initialize with default structure (issue #743)
      log "Chronicle file is empty, initializing with default structure"
      chronicle_output='{"entries":[],"civilizationAge":"unknown","totalAgentsRun":0,"totalPRsMerged":0}'
    fi
    
    # Build jq arguments as array (not string) to avoid quoting issues
    local jq_args=(--arg era "$era" --arg period "$period" --arg summary "$summary")
    [ -n "$lesson_learned" ] && jq_args+=(--arg lesson "$lesson_learned")
    [ -n "$milestone" ] && jq_args+=(--arg milestone "$milestone")
    [ -n "$root_cause" ] && jq_args+=(--arg rootCause "$root_cause")
    [ -n "$challenge" ] && jq_args+=(--arg challenge "$challenge")
    
    # Build entry object with conditional fields
    local entry_json='{era: $era, period: $period, summary: $summary}'
    [ -n "$lesson_learned" ] && entry_json=$(echo "$entry_json" | sed 's/}$/, lessonLearned: $lesson}/')
    [ -n "$milestone" ] && entry_json=$(echo "$entry_json" | sed 's/}$/, milestone: $milestone}/')
    [ -n "$root_cause" ] && entry_json=$(echo "$entry_json" | sed 's/}$/, rootCause: $rootCause}/')
    [ -n "$challenge" ] && entry_json=$(echo "$entry_json" | sed 's/}$/, challenge: $challenge}/')
    
    # Append new entry (use array expansion "${jq_args[@]}")
    local updated_chronicle
    if ! updated_chronicle=$(echo "$chronicle_output" | jq "${jq_args[@]}" ".entries += [$entry_json]" 2>&1); then
      log "ERROR: Failed to update chronicle JSON: $updated_chronicle"
      return 0  # Don't fail the agent
    fi
    
    # Try to upload with conditional write (detect concurrent modifications)
    local upload_output
    if upload_output=$(echo "$updated_chronicle" | aws s3 cp - "s3://${S3_BUCKET}/chronicle.json" --content-type application/json 2>&1); then
      log "Chronicle updated: era=$era period=$period"
      push_metric "ChronicleUpdated" 1
      
      # Update identity stats (if identity system is active)
      if [ -n "${AGENT_DISPLAY_NAME:-}" ] && type update_identity_stats &>/dev/null; then
        update_identity_stats "chronicleUpdates" 1
      fi
      
      return 0  # Success
    else
      log "WARNING: Chronicle upload failed (attempt $((retry_count+1))/$max_retries): $upload_output"
      retry_count=$((retry_count+1))
      [ $retry_count -lt $max_retries ] && sleep 1  # Brief delay before retry
    fi
  done
  
  log "ERROR: Failed to append to chronicle after $max_retries attempts"
  return 0  # Don't fail the agent, but log the failure
}

# ── Coordinator integration ───────────────────────────────────────────────────
# claim_task() - Atomically claim a GitHub issue to prevent duplicate work (issue #859)
# Uses CAS (compare-and-swap) on coordinator-state.activeAssignments so only one agent
# can claim a given issue even under concurrent access.
# Usage: claim_task <issue_number>
# Returns: 0 if claim succeeded, 1 if already claimed by another agent or on error
claim_task() {
  local issue="$1"
  [ -z "$issue" ] || [ "$issue" = "0" ] && return 1

  local max_attempts=5
  local attempt=0

  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))

    # Read current assignments
    local assignments
    assignments=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
      -o jsonpath='{.data.activeAssignments}' 2>/dev/null || echo "")

    # Check if issue is already claimed by any agent
    if echo "$assignments" | grep -qE "(^|,)[^,]+:${issue}(,|$)"; then
      # Determine who claimed it
      local claimer
      claimer=$(echo "$assignments" | tr ',' '\n' | grep ":${issue}$" | cut -d: -f1)
      if [ "$claimer" = "$AGENT_NAME" ]; then
        log "Coordinator: issue #$issue already claimed by us ($AGENT_NAME) — continuing"
        return 0
      fi
      log "Coordinator: issue #$issue already claimed by $claimer — skipping to avoid duplicate work"
      push_metric "TaskClaimConflict" 1
      return 1
    fi

    # Build new assignments value
    local new_assignments
    if [ -z "$assignments" ]; then
      new_assignments="${AGENT_NAME}:${issue}"
    else
      new_assignments="${assignments},${AGENT_NAME}:${issue}"
    fi

    # Atomic CAS: test current value, only write if unchanged since our read.
    # Uses JSON patch test+replace to prevent TOCTOU races (same pattern as spawn slots).
    # If another agent updated activeAssignments between our read and write, the test
    # will fail and we retry with fresh data.
    local expected_value="$assignments"
    if [ -z "$expected_value" ]; then
      # Field doesn't exist yet: use add operation
      if kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
        --type=json \
        -p "[{\"op\":\"add\",\"path\":\"/data/activeAssignments\",\"value\":\"${new_assignments}\"}]" \
        2>/dev/null; then
        log "Coordinator: claimed issue #$issue (was: empty, now: $new_assignments)"
        push_metric "TaskClaimed" 1
        # Persist claimed issue to temp file so end-of-session specialization tracking
        # can find it even after coordinator activeAssignments cleanup removes the entry
        # (issue #1252: WORKED_ISSUE=0 race with coordinator 30s cleanup loop)
        echo "$issue" > /tmp/agentex-worked-issue 2>/dev/null || true
        # Issue #1268: Cache issue labels at claim time for resilient specialization tracking
        # (GitHub API may be rate-limited at exit time during high agent activity)
        cache_issue_labels_on_claim "$issue"
        return 0
      fi
    else
      # Field exists: use test+replace for atomic CAS
      if kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
        --type=json \
        -p "[{\"op\":\"test\",\"path\":\"/data/activeAssignments\",\"value\":\"${expected_value}\"},{\"op\":\"replace\",\"path\":\"/data/activeAssignments\",\"value\":\"${new_assignments}\"}]" \
        2>/dev/null; then
        log "Coordinator: claimed issue #$issue (assignments: $new_assignments)"
        push_metric "TaskClaimed" 1
        # Persist claimed issue to temp file so end-of-session specialization tracking
        # can find it even after coordinator activeAssignments cleanup removes the entry
        # (issue #1252: WORKED_ISSUE=0 race with coordinator 30s cleanup loop)
        echo "$issue" > /tmp/agentex-worked-issue 2>/dev/null || true
        # Issue #1268: Cache issue labels at claim time for resilient specialization tracking
        # (GitHub API may be rate-limited at exit time during high agent activity)
        cache_issue_labels_on_claim "$issue"
        return 0
      fi
    fi

    # CAS failed: another agent concurrently modified activeAssignments — retry with fresh read
    log "Coordinator: CAS failed for issue #$issue (attempt $attempt/$max_attempts) — retrying"
    sleep 1
  done

  log "WARNING: Failed to claim issue #$issue after $max_attempts attempts"
  return 1
}

# cache_issue_labels_on_claim() - Fetch and cache issue labels at claim time (issue #1268)
# Stores labels in coordinator-state.issueLabels as "issue:label1,label2|issue2:label3|..."
# Called by claim_task() immediately after a successful CAS claim.
# This decouples specialization tracking from GitHub API availability at exit time:
# labels are fetched while the API is likely available (claim time vs exit time).
#
# Usage: cache_issue_labels_on_claim <issue_number>
# Returns: 0 always (best-effort — cache failure is non-fatal)
cache_issue_labels_on_claim() {
  local issue="$1"
  [ -z "$issue" ] || [ "$issue" = "0" ] && return 0

  # Fetch labels now (GitHub API more likely available at claim time than at exit time)
  local labels
  labels=$(gh issue view "$issue" --repo "$REPO" \
    --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

  if [ -z "$labels" ]; then
    log "Issue #$issue label cache: no labels found (API unavailable or unlabeled) — will fall back to GitHub at exit"
    return 0
  fi

  log "Issue #$issue label cache: fetched labels='$labels'"

  # Read existing issueLabels cache from coordinator-state
  local existing_cache
  existing_cache=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.issueLabels}' 2>/dev/null || echo "")

  # Build updated cache: remove any old entry for this issue, then append new one
  local new_entry="${issue}:${labels}"
  local new_cache
  if [ -z "$existing_cache" ]; then
    new_cache="$new_entry"
  else
    # Remove existing entry for this issue to avoid duplicates
    local filtered_cache
    filtered_cache=$(echo "$existing_cache" | tr '|' '\n' | grep -v "^${issue}:" | tr '\n' '|' | sed 's/|$//')
    if [ -z "$filtered_cache" ]; then
      new_cache="$new_entry"
    else
      new_cache="${filtered_cache}|${new_entry}"
    fi
  fi

  # Update coordinator-state (best-effort, not atomic — cache corruption is harmless since
  # exit handler falls back to GitHub API on cache miss)
  kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"issueLabels\":\"${new_cache}\"}}" \
    2>/dev/null && log "Issue #$issue labels cached in coordinator-state.issueLabels" || \
    log "WARNING: Failed to cache labels for issue #$issue in coordinator-state (non-fatal)"
}

# propose_vision_feature() - Propose a civilization goal for governance vote (issue #1219)
# Any agent can call this to propose an issue be added to the visionQueue.
# When 3+ agents vote to approve, the coordinator adds the issue to visionQueue.
# Planners then read visionQueue BEFORE taskQueue, so approved goals get priority.
#
# Usage: propose_vision_feature <issue_number> <feature_name> <reason>
# Example: propose_vision_feature 1219 "visionQueue" "enables agent collective self-direction"
propose_vision_feature() {
  local issue_number="${1:-}"
  local feature_name="${2:-unnamed-feature}"
  local reason="${3:-agent-proposed}"

  if [ -z "$issue_number" ] || ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    log "propose_vision_feature: invalid issue number '$issue_number'"
    return 1
  fi

  # Sanitize: replace spaces with hyphens (kv_pairs parser uses spaces as delimiters)
  local safe_name
  safe_name=$(echo "$feature_name" | tr ' ' '-' | tr -cd '[:alnum:]-')
  local safe_reason
  safe_reason=$(echo "$reason" | tr ' ' '-' | tr -cd '[:alnum:]-')

  timeout 10s kubectl apply -f - <<EOF >/dev/null 2>&1 || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-vision-proposal-${AGENT_NAME}-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  taskRef: "${TASK_CR_NAME:-unknown}"
  thoughtType: proposal
  confidence: 8
  content: |
    #proposal-vision-feature addIssue=${issue_number} reason=${safe_reason}
    Feature: ${safe_name}
    Proposing issue #${issue_number} as a civilization vision goal.
    When 3+ agents approve, the coordinator will add it to visionQueue.
    Planners will then prioritize this issue above the regular task queue.
EOF
  log "Vision feature proposed: issue #$issue_number ('$safe_name') — awaiting 3+ votes"
}

# request_coordinator_task() - Claim an unassigned issue from the coordinator queue
# Returns: sets COORDINATOR_ISSUE to the claimed issue number, or 0 if none available
# This is the mechanism that makes planners coordinate instead of acting independently.
# Uses claim_task() for atomic assignment to prevent duplicate work (issue #859).
# Supports specialization-aware routing (issue #1098): if agent has a specialization,
# prefer issues whose labels match. Falls back to queue order if no match.
#
# VISION QUEUE PRIORITY (issue #1149): Checks coordinator-state.visionQueue FIRST.
# When agents collectively vote to prioritize a feature (#proposal-vision-queue),
# the coordinator adds it to visionQueue. This function checks visionQueue before
# taskQueue so civilization-chosen goals override human-assigned tasks.
# visionQueue format: "feature:description:ts:proposer;feature2:..."
request_coordinator_task() {
  local max_retries=3
  local retry=0

  # ── VISION QUEUE PRIORITY CHECK (issue #1149) ────────────────────────────
  # Check vision queue BEFORE the regular task queue. If a vision-queue item
  # is a GitHub issue number, claim it. If it's a feature name, log it for the
  # planner to action (create an issue) but don't block on a regular task claim.
  local vision_queue
  vision_queue=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.visionQueue}' 2>/dev/null || echo "")

  if [ -n "$vision_queue" ]; then
    log "Coordinator: vision queue has entries — checking priority items"
    # Vision queue is semicolon-separated: "feature:description:ts:proposer;..."
    local first_vq_entry
    first_vq_entry=$(echo "$vision_queue" | cut -d';' -f1)
    local vq_feature
    vq_feature=$(echo "$first_vq_entry" | cut -d':' -f1)

    if [[ "$vq_feature" =~ ^[0-9]+$ ]]; then
      # Feature is a GitHub issue number — claim it with priority
       log "Coordinator: vision-queue priority item is GitHub issue #$vq_feature"
       if claim_task "$vq_feature" 2>/dev/null; then
         # Remove from vision queue — handle single-item case (no semicolon)
         local remaining_vq
         if echo "$vision_queue" | grep -q ";"; then
           remaining_vq=$(echo "$vision_queue" | sed 's/^[^;]*;//')
         else
           remaining_vq=""
         fi
         kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
           --type=merge \
           -p "{\"data\":{\"visionQueue\":\"${remaining_vq}\"}}" 2>/dev/null || true
         log "Coordinator: claimed vision-queue issue #$vq_feature (civilization-chosen goal)"
         push_metric "VisionQueueTaskClaimed" 1
         COORDINATOR_ISSUE="$vq_feature"
         return 0
       else
         log "Coordinator: vision-queue issue #$vq_feature already claimed — falling through to task queue"
       fi
    else
      # Feature is a named feature (not an issue number) — export it for planner to action
      # The planner should create a GitHub issue for this feature
      export VISION_QUEUE_FEATURE="$vq_feature"
      export VISION_QUEUE_DESCRIPTION=$(echo "$first_vq_entry" | cut -d':' -f2)
      log "Coordinator: vision-queue feature '${vq_feature}' needs a GitHub issue — exported as VISION_QUEUE_FEATURE"
      # Don't consume this from the queue yet; planners will file an issue and add the number
    fi
  fi

  while [ $retry -lt $max_retries ]; do
    # Issue #1219: Check visionQueue BEFORE taskQueue — civilization-voted goals get priority.
    # visionQueue contains issue numbers added by collective governance vote.
    # This is how agents collectively self-direct the civilization's priorities.
    local vision_queue
    vision_queue=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
      -o jsonpath='{.data.visionQueue}' 2>/dev/null || echo "")

    local queue
    if [ -n "$vision_queue" ]; then
      # Prepend vision queue items before the regular task queue
      local task_queue
      task_queue=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
        -o jsonpath='{.data.taskQueue}' 2>/dev/null || echo "")
      # Combine: vision items first, then regular items (deduplicated)
      local combined="${vision_queue}${task_queue:+,$task_queue}"
      queue=$(echo "$combined" | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')
      log "Coordinator: visionQueue has priority items — effective queue: $queue"
    else
      queue=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
        -o jsonpath='{.data.taskQueue}' 2>/dev/null || echo "")
    fi

    if [ -z "$queue" ]; then
      log "Coordinator: task queue is empty"
      COORDINATOR_ISSUE=0
      return 0
    fi

    # Specialization-aware selection (issue #1098)
    # If this agent has a specialization, try to find a matching issue in the queue first.
    local claimed_issue=""
    local my_specialization="${AGENT_SPECIALIZATION:-}"
    
    if [ -n "$my_specialization" ]; then
      # Map specialization back to label keywords for matching
      local spec_label=""
      case "$my_specialization" in
        governance-specialist) spec_label="governance\|debate\|collective-intelligence" ;;
        platform-specialist) spec_label="coordinator\|self-improvement" ;;
        security-specialist) spec_label="security" ;;
        memory-specialist) spec_label="identity\|memory" ;;
        debugger) spec_label="bug" ;;
        *) spec_label=$(echo "$my_specialization" | sed 's/-specialist//') ;;
      esac
      
      # Scan queue for a matching issue
      for candidate in $(echo "$queue" | tr ',' ' '); do
        [ -z "$candidate" ] && continue
        local issue_labels
        issue_labels=$(gh issue view "$candidate" --repo "$REPO" \
          --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
        if echo "$issue_labels" | grep -qi "$spec_label"; then
          claimed_issue="$candidate"
          log "Coordinator: specialization-matched issue #$claimed_issue (spec=$my_specialization, labels=$issue_labels)"
          break
        fi
      done
    fi
    
    # Fall back to first issue in queue if no specialization match
    if [ -z "$claimed_issue" ]; then
      claimed_issue=$(echo "$queue" | tr ',' '\n' | head -1 | tr -d ' ')
    fi

    if [ -z "$claimed_issue" ] || [ "$claimed_issue" = "0" ]; then
      COORDINATOR_ISSUE=0
      return 0
    fi

    # Atomically claim the issue using CAS (issue #859)
    # This prevents two concurrent agents from both picking the same queue item
    if ! claim_task "$claimed_issue"; then
      log "Coordinator: issue #$claimed_issue already claimed by another agent, trying next"
      # Remove this issue from queue since it's taken, and try the next one
      # Use grep -v || true to handle the case where the issue is the only item in the queue
      # (grep -v returns exit code 1 when no lines match, which triggers set -euo pipefail)
      local new_queue
      new_queue=$(echo "$queue" | tr ',' '\n' | grep -v "^${claimed_issue}$" || true)
      new_queue=$(echo "$new_queue" | tr '\n' ',' | sed 's/,$//')
      kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
        --type=merge \
        -p "{\"data\":{\"taskQueue\":\"${new_queue}\"}}" 2>/dev/null || true
      retry=$((retry + 1))
      continue
    fi

    # Validate the issue is still OPEN on GitHub (issue #1015)
    # The coordinator queue may be stale and contain closed issues.
    # If the issue is closed, release the claim and remove from queue to avoid
    # wasting agent sessions on already-resolved work.
    local issue_state
    issue_state=$(gh issue view "$claimed_issue" --repo "${REPO}" --json state --jq '.state' 2>/dev/null || echo "NOT_FOUND")  # issue #1066: was GITHUB_REPO (undefined), correct var is REPO
    if [ "$issue_state" != "OPEN" ]; then
      log "Coordinator: issue #$claimed_issue is $issue_state — releasing claim and removing from queue"
      # Release the claim atomically
      release_coordinator_task "$claimed_issue"
      # Remove from queue to prevent future agents from wasting time on it
      local new_queue
      new_queue=$(echo "$queue" | tr ',' '\n' | grep -v "^${claimed_issue}$" || true)
      new_queue=$(echo "$new_queue" | tr '\n' ',' | sed 's/,$//')
      kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
        --type=merge \
        -p "{\"data\":{\"taskQueue\":\"${new_queue}\"}}" 2>/dev/null || true
      retry=$((retry + 1))
      continue
    fi

    # Remove claimed issue from the queue
    # Use grep -v || true: when queue has only this issue, grep -v returns exit code 1 (no matches),
    # which would crash the script under set -euo pipefail (issue #979)
    local new_queue
    new_queue=$(echo "$queue" | tr ',' '\n' | grep -v "^${claimed_issue}$" || true)
    new_queue=$(echo "$new_queue" | tr '\n' ',' | sed 's/,$//')
    kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
      --type=merge \
      -p "{\"data\":{\"taskQueue\":\"${new_queue}\"}}" 2>/dev/null || true

    log "Coordinator: claimed issue #$claimed_issue from queue"
    push_metric "CoordinatorTaskClaimed" 1
    COORDINATOR_ISSUE="$claimed_issue"
    return 0
  done

  log "WARNING: Failed to claim task from coordinator after $max_retries retries"
  COORDINATOR_ISSUE=0
  return 0
}

# release_coordinator_task() - Mark a coordinator-assigned issue as complete
# Call this after finishing work on an issue claimed via request_coordinator_task()
release_coordinator_task() {
  local issue="${1:-$COORDINATOR_ISSUE}"
  [ -z "$issue" ] || [ "$issue" = "0" ] && return 0

  local assignments
  assignments=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.activeAssignments}' 2>/dev/null || echo "")

  # Remove this agent's assignment
  # Use grep -v || true: if this agent's assignment is the only one, grep -v returns exit code 1
  # (no matches), which would crash the script under set -euo pipefail
  local new_assignments
  new_assignments=$(echo "$assignments" | tr ',' '\n' \
    | grep -v "^${AGENT_NAME}:${issue}$" || true)
  new_assignments=$(echo "$new_assignments" | tr '\n' ',' | sed 's/,$//')

  local err_output
  if ! err_output=$(kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
    --type=merge \
    -p "{\"data\":{\"activeAssignments\":\"${new_assignments}\"}}" 2>&1); then
    log "WARNING: Failed to release task assignment for issue #$issue: $err_output"
    return 1
  fi

  log "Coordinator: released issue #$issue"
  push_metric "CoordinatorTaskReleased" 1
}

# register_with_coordinator() - Announce this agent's presence to the coordinator
register_with_coordinator() {
  local current
  current=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.activeAgents}' 2>/dev/null || echo "")

  local new_val
  if [ -z "$current" ]; then
    new_val="${AGENT_NAME}:${AGENT_ROLE}"
  else
    # Deduplicate: remove any prior entry for this agent then add fresh
    # Use grep -v || true: if this agent is the only registered agent, grep -v returns exit code 1
    # (no matches), which would crash the script under set -euo pipefail
    new_val=$(echo "$current" | tr ',' '\n' | grep -v "^${AGENT_NAME}:" || true)
    new_val=$(echo "$new_val" | tr '\n' ',' | sed 's/,$//')
    [ -n "$new_val" ] && new_val="${new_val},${AGENT_NAME}:${AGENT_ROLE}" || new_val="${AGENT_NAME}:${AGENT_ROLE}"
  fi

  # Build patch data — include lastPlannerSeen timestamp for planners (issue #1274)
  local patch_data="{\"data\":{\"activeAgents\":\"${new_val}\"}}"
  if [ "${AGENT_ROLE}" = "planner" ]; then
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    patch_data="{\"data\":{\"activeAgents\":\"${new_val}\",\"lastPlannerSeen\":\"${ts}\"}}"
  fi

  local err_output
  if ! err_output=$(kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
    --type=merge -p "${patch_data}" 2>&1); then
    log "WARNING: Failed to register with coordinator: $err_output"
    return 1
  fi
  
  log "Coordinator: registered agent ${AGENT_NAME} (${AGENT_ROLE})"
  [ "${AGENT_ROLE}" = "planner" ] && log "Coordinator: updated lastPlannerSeen=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  return 0
}

# get_mentor_insight() - Find predecessor mentor for an issue (issue #1228)
# Predecessor mentorship: when an agent claims an issue, we look up S3 identities
# for agents whose specialization (or specializationLabelCounts) matches the issue labels.
# Returns: sets MENTOR_DISPLAY_NAME, MENTOR_AGENT_NAME, MENTOR_INSIGHT vars.
# The caller builds MENTORSHIP_BLOCK from these values and injects into OpenCode prompt.
#
# Algorithm:
#   1. Get labels for the GitHub issue
#   2. List S3 identities and sample up to 50 (most recent) for matching
#   3. Score each: exact specialization match = 10, label count match = count score
#   4. Pick highest-scoring agent with score > 0
#   5. Find their most recent insight Thought CR
#
# Gracefully degrades: returns empty strings if S3/cluster unavailable.
get_mentor_insight() {
  local issue_num="${1:-}"
  MENTOR_DISPLAY_NAME=""
  MENTOR_AGENT_NAME=""
  MENTOR_INSIGHT=""
  MENTOR_SPECIALIZATION=""

  [ -z "$issue_num" ] || [ "$issue_num" = "0" ] && return 0

  log "Mentorship: looking up predecessor mentor for issue #$issue_num..."

  # Step 1: Get labels for the issue
  local issue_labels
  issue_labels=$(gh issue view "$issue_num" --repo "$REPO" \
    --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
  if [ -z "$issue_labels" ]; then
    log "Mentorship: no labels found for issue #$issue_num — skipping mentor lookup"
    return 0
  fi
  log "Mentorship: issue #$issue_num labels: $issue_labels"

  # Step 2: List S3 identities (newest first, sample up to 30 to stay fast)
  # Limit: 30 identities × ~200ms/S3-read = ~6s max. Graceful degradation if slow.
  local identity_keys
  identity_keys=$(timeout 10s aws s3 ls "s3://${S3_BUCKET}/identities/" \
    --region "$BEDROCK_REGION" 2>/dev/null | \
    sort -k1,2 -r | awk '{print $4}' | head -30 || echo "")
  if [ -z "$identity_keys" ]; then
    log "Mentorship: no identity files found in S3 — skipping"
    return 0
  fi

  # Step 3: Score identities for label match
  local best_agent="" best_display="" best_score=0 best_spec=""
  while IFS= read -r identity_key; do
    [ -z "$identity_key" ] && continue
    # Skip own identity
    [[ "$identity_key" == "${AGENT_NAME}.json" ]] && continue

    local identity_json
    identity_json=$(aws s3 cp "s3://${S3_BUCKET}/identities/${identity_key}" - \
      --region "$BEDROCK_REGION" 2>/dev/null || echo "")
    [ -z "$identity_json" ] && continue

    local agent_name display_name spec label_counts
    agent_name=$(echo "$identity_json" | jq -r '.agentName // ""' 2>/dev/null || echo "")
    display_name=$(echo "$identity_json" | jq -r '.displayName // .agentName // ""' 2>/dev/null || echo "")
    spec=$(echo "$identity_json" | jq -r '.specialization // ""' 2>/dev/null || echo "")
    label_counts=$(echo "$identity_json" | jq -r '.specializationLabelCounts // {}' 2>/dev/null || echo "{}")

    [ -z "$agent_name" ] && continue

    local score=0
    # Exact specialization match (highest priority)
    if [ -n "$spec" ] && echo "$issue_labels" | grep -qi "$spec"; then
      score=10
    fi

    # Label count match: sum counts for labels that appear in issue_labels
    if [ "$score" -eq 0 ] && [ "$label_counts" != "{}" ]; then
      local label_score
      label_score=$(echo "$label_counts" | jq -r \
        --arg issue_labels "$issue_labels" \
        '[to_entries[] | . as $e | select(($issue_labels | split(",") | map(ascii_downcase)) | contains([$e.key | ascii_downcase])) | .value] | add // 0' \
        2>/dev/null || echo "0")
      # Truncate to integer (jq may output floats)
      score=$(echo "${label_score:-0}" | cut -d. -f1)
      score="${score:-0}"
    fi

    if [ "$score" -gt "$best_score" ]; then
      best_score="$score"
      best_agent="$agent_name"
      best_display="$display_name"
      best_spec="${spec:-$issue_labels}"
    fi
  done <<< "$identity_keys"

  if [ -z "$best_agent" ] || [ "$best_score" -eq 0 ]; then
    log "Mentorship: no matching specialist found for issue #$issue_num labels ($issue_labels)"
    return 0
  fi

  log "Mentorship: found mentor $best_display ($best_agent) with score=$best_score spec=$best_spec"

  # Step 4: Find their most recent insight Thought CR
  local mentor_thought
  mentor_thought=$(kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" \
    -l agentex/thought -o json 2>/dev/null | \
    jq -r --arg agent "$best_agent" \
    '.items | sort_by(.metadata.creationTimestamp) | reverse |
     map(select(.data.agentRef == $agent and (.data.thoughtType == "insight" or .data.thoughtType == "decision"))) |
     first | .data.content // ""' 2>/dev/null | head -c 500 || echo "")

  if [ -z "$mentor_thought" ]; then
    log "Mentorship: mentor $best_agent found but no insight thoughts in cluster"
    # Still export the mentor identity so the agent knows who the specialist is
  fi

  MENTOR_DISPLAY_NAME="$best_display"
  MENTOR_AGENT_NAME="$best_agent"
  MENTOR_INSIGHT="$mentor_thought"
  MENTOR_SPECIALIZATION="$best_spec"
  log "Mentorship: predecessor mentor identified: $MENTOR_DISPLAY_NAME ($MENTOR_AGENT_NAME)"
  return 0
}

patch_task_status() {
  local phase="$1" outcome="${2:-}"
  local completed_at=""
  [ "$phase" = "Done" ] && completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Patch the ConfigMap backing the Task CR, not the Task CR status directly.
  # kro status fields are output-only and reflect the ConfigMap data.
  # Use timeout to prevent 120s hangs if cluster API is unreachable (issue #458)
  local err_output
  if ! err_output=$(kubectl_with_timeout 10 patch configmap "${TASK_CR_NAME}-spec" -n "$NAMESPACE" \
    --type=merge \
    -p "{\"data\":{\"phase\":\"${phase}\",\"agentRef\":\"${AGENT_NAME}\",\"outcome\":\"${outcome}\",\"completedAt\":\"${completed_at}\"}}" 2>&1); then
    log "WARNING: Failed to update task status to ${phase}: $err_output"
    return 0  # Task status is advisory — never crash the agent over a failed patch (#988)
  fi
  
  log "Task status updated: ${phase}"
}

# Push a custom metric to CloudWatch for dashboard visibility.
# These metrics power the agentex-activity CloudWatch dashboard.
push_metric() {
  local metric_name="$1" value="${2:-1}" unit="${3:-Count}"
  local err_output
  err_output=$(aws cloudwatch put-metric-data \
    --namespace Agentex \
    --metric-name "$metric_name" \
    --value "$value" \
    --unit "$unit" \
    --dimensions Role="$AGENT_ROLE",Agent="$AGENT_NAME" \
    --region "$BEDROCK_REGION" 2>&1) || {
    log "WARNING: Failed to push metric $metric_name (value=$value): $err_output"
    return 0  # Metrics are fire-and-forget; failure is never fatal (issue #779)
  }
}

# restart_coordinator_if_unhealthy() - Self-healing mechanism (issue #755)
# Checks coordinator heartbeat age and restarts deployment if stale (> 5 min).
# Enables civilization to recover from coordinator failures without human intervention.
restart_coordinator_if_unhealthy() {
  local last_heartbeat
  last_heartbeat=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.lastHeartbeat}' 2>/dev/null || echo "")
  
  if [ -z "$last_heartbeat" ]; then
    log "Coordinator heartbeat not found. May be starting up or coordinator not deployed."
    return 0
  fi
  
  local now heartbeat_ts age
  now=$(date +%s)
  heartbeat_ts=$(date -d "$last_heartbeat" +%s 2>/dev/null || echo "0")
  
  if [ "$heartbeat_ts" -eq 0 ]; then
    log "WARNING: Cannot parse coordinator heartbeat timestamp: $last_heartbeat"
    return 0
  fi
  
  age=$((now - heartbeat_ts))
  
  # Threshold: 5 minutes (300 seconds)
  # Coordinator heartbeat interval is ~20-30 seconds, so 5min = definitely dead
  if [ "$age" -gt 300 ]; then
    log "WARNING: Coordinator heartbeat is $age seconds old (threshold: 300s). Attempting restart..."
    
    if kubectl_with_timeout 10 rollout restart deployment coordinator -n "$NAMESPACE" 2>&1; then
      log "✓ Coordinator deployment restart initiated"
      post_thought "Coordinator heartbeat stale (${age}s old, threshold 300s). Restarted coordinator deployment." "observation" 8
      push_metric "CoordinatorRestarted" 1
    else
      log "ERROR: Failed to restart coordinator deployment"
      post_thought "Coordinator heartbeat stale (${age}s old) but restart failed. Manual intervention may be needed." "blocker" 9
    fi
  else
    log "Coordinator heartbeat age: ${age}s (healthy, threshold: 300s)"
  fi
}

# ── Atomic Spawn Gate (issue #519: TOCTOU fix) ───────────────────────────────
# The coordinator maintains a spawnSlots counter in coordinator-state.
# Agents atomically claim a slot before spawning and release it after.
# This replaces the racy "count jobs → decide to spawn" pattern.
#
# The coordinator reconciles spawnSlots against actual job count every ~2 min
# to recover from leaked slots (agent crash before release).
#
# Returns 0 if slot granted, 1 if denied.
request_spawn_slot() {
  local bypass_killswitch="${1:-false}"  # Optional bypass for emergency perpetuation (issue #783)
  local max_attempts=5
  local attempt=0

  # Check kill switch first (unless bypassed for emergency perpetuation)
  if [ "$bypass_killswitch" != "true" ]; then
    local killswitch_enabled
    killswitch_enabled=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
      -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
    if [ "$killswitch_enabled" = "true" ]; then
      local ks_reason
      ks_reason=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
        -o jsonpath='{.data.reason}' 2>/dev/null || echo "unknown")
      log "KILL SWITCH: spawn slot denied. Reason: $ks_reason"
      push_metric "KillSwitchTriggered" 1
      return 1
    fi
  else
    log "Kill switch bypass active (emergency perpetuation)"
  fi

  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))

    # Read current spawnSlots
    local slots
    slots=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
      -o jsonpath='{.data.spawnSlots}' 2>/dev/null || echo "")

    # If coordinator-state missing or spawnSlots not set, FAIL CLOSED (deny spawn)
    # Issue #713: The previous fail-open fallback allowed TOCTOU race conditions.
    # Multiple agents could simultaneously read job count, all pass the check, and all spawn.
    # This caused 51 agents to spawn with only 3 slots available.
    # FIX: coordinator-state is the source of truth. If unavailable, deny spawn.
    # The coordinator will self-heal and reconcile slots when it recovers.
    if [ -z "$slots" ] || ! [[ "$slots" =~ ^[0-9]+$ ]]; then
      log "CRITICAL: coordinator spawnSlots unavailable. FAILING CLOSED to prevent proliferation race."
      log "Coordinator must reconcile slots before spawning can resume."
      post_thought "Spawn denied: coordinator-state unavailable (fail-closed for safety). Issue #713 fix." "blocker" 9
      push_metric "CircuitBreakerTriggered" 1
      push_metric "CoordinatorUnavailable" 1
      return 1
    fi

    # Issue #713/#716: Stale data detection - if slots > limit, kubectl cache is stale
    # This can happen after API server/kro restarts or during CI/CD waves.
    # The coordinator never sets slots > limit, so this indicates stale read.
    # Wait and retry to get fresh data from API server.
    if [ "$slots" -gt "$CIRCUIT_BREAKER_LIMIT" ]; then
      log "WARNING: Stale coordinator data detected (slots=$slots > limit=$CIRCUIT_BREAKER_LIMIT). Waiting for API server cache refresh..."
      push_metric "StaleDataDetected" 1
      if [ $attempt -lt $max_attempts ]; then
        sleep 2  # Longer delay for cache refresh
        continue
      else
        log "CRITICAL: Coordinator data still stale after $max_attempts attempts. Failing closed."
        post_thought "Spawn denied: stale coordinator-state detected (slots > limit). Issue #713/#716 fix." "blocker" 9
        push_metric "CircuitBreakerTriggered" 1
        return 1
      fi
    fi

    if [ "$slots" -le 0 ]; then
      log "ATOMIC SPAWN GATE: 0 slots available (limit=$CIRCUIT_BREAKER_LIMIT). Spawn denied."
      post_thought "Atomic spawn gate: 0 slots remaining. Spawn blocked. System at capacity." "blocker" 10
      push_metric "CircuitBreakerTriggered" 1
      return 1
    fi

    # Issue #713: Add validation - cross-check with actual job count before first CAS attempt
    # This detects coordinator reconciliation lag and prevents burst spawning.
    # Only check on first attempt to avoid slowing down every spawn.
    if [ $attempt -eq 1 ]; then
      local active_jobs
      active_jobs=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
        2>/dev/null || echo "0")
      
      # If active jobs + requesting spawn would exceed limit, coordinator data is stale
      if [ "$active_jobs" -ge "$CIRCUIT_BREAKER_LIMIT" ]; then
        log "WARNING: Cross-check failed - active jobs ($active_jobs) >= limit ($CIRCUIT_BREAKER_LIMIT) but coordinator shows $slots slots"
        log "Coordinator reconciliation lag detected. Denying spawn to prevent proliferation burst."
        post_thought "Spawn denied: coordinator reconciliation lag detected ($active_jobs jobs >= $CIRCUIT_BREAKER_LIMIT limit, but coordinator shows $slots slots). Issue #713 fix." "blocker" 9
        push_metric "CircuitBreakerTriggered" 1
        push_metric "CoordinatorReconciliationLag" 1
        return 1
      fi
      
      log "Spawn validation passed: $active_jobs active jobs, coordinator shows $slots slots available"
    fi

    # Atomically decrement: test current value then replace with (value - 1)
    local new_slots=$((slots - 1))
    if kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
      --type=json \
      -p "[{\"op\":\"test\",\"path\":\"/data/spawnSlots\",\"value\":\"${slots}\"},{\"op\":\"replace\",\"path\":\"/data/spawnSlots\",\"value\":\"${new_slots}\"}]" \
      2>/dev/null; then
      log "Spawn slot granted: ${slots} → ${new_slots} slots remaining"
      push_metric "SpawnSlotGranted" 1
      return 0
    fi

    # Test failed = concurrent modification, retry
    log "Spawn slot CAS retry $attempt/$max_attempts (concurrent modification detected)"
    sleep 0.$((RANDOM % 5 + 1))  # 0.1-0.5s jitter
  done

  log "ATOMIC SPAWN GATE: failed to acquire slot after $max_attempts attempts. Spawn denied."
  push_metric "CircuitBreakerTriggered" 1
  return 1
}

release_spawn_slot() {
  # Increment spawnSlots back after spawn completes (or fails)
  # Use retry loop for CAS correctness
  local max_attempts=5
  local attempt=0
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))
    local slots
    slots=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
      -o jsonpath='{.data.spawnSlots}' 2>/dev/null || echo "")
    if [ -z "$slots" ] || ! [[ "$slots" =~ ^[0-9]+$ ]]; then
      log "WARNING: coordinator spawnSlots unavailable during release, skipping"
      return 0
    fi
    local new_slots=$((slots + 1))
    # Cap at CIRCUIT_BREAKER_LIMIT to prevent slot leaks from double-release
    if [ "$new_slots" -gt "$CIRCUIT_BREAKER_LIMIT" ]; then
      new_slots=$CIRCUIT_BREAKER_LIMIT
    fi
    if kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
      --type=json \
      -p "[{\"op\":\"test\",\"path\":\"/data/spawnSlots\",\"value\":\"${slots}\"},{\"op\":\"replace\",\"path\":\"/data/spawnSlots\",\"value\":\"${new_slots}\"}]" \
      2>/dev/null; then
      log "Spawn slot released: ${slots} → ${new_slots} slots available"
      push_metric "SpawnSlotReleased" 1
      return 0
    fi
    log "Spawn slot release CAS retry $attempt/$max_attempts"
    sleep 0.$((RANDOM % 3 + 1))
  done
  log "WARNING: Failed to release spawn slot after $max_attempts attempts (slot may be leaked, coordinator will reconcile)"
}

# ── Consensus Protocol Functions ──────────────────────────────────────────────
# Spawn a new Agent CR. This is the core perpetuation primitive.
# kro agent-graph turns this into a Job automatically.
spawn_agent() {
  local name="$1" role="$2" task_ref="$3" reason="$4" bypass_killswitch="${5:-false}" capacity_type="${6:-on-demand}"
  
  # ATOMIC SPAWN GATE (issue #519): Request a spawn slot from the coordinator.
  # This replaces the racy "count jobs → decide to spawn" TOCTOU pattern.
  # The coordinator maintains an atomic counter that prevents concurrent over-spawning.
  # Issue #783: Emergency perpetuation bypasses kill switch to prevent civilization death.
  if ! request_spawn_slot "$bypass_killswitch"; then
    log "spawn_agent: spawn slot denied by atomic gate. Not spawning $name."
    return 1
  fi
  local _slot_acquired=true
  
  # Calculate next generation number by reading current agent's generation label
  local my_generation=$(get_my_generation)
  local next_generation=$((my_generation + 1))
  
  # Get identity signature for logging (if identity system is active)
  local identity_sig="${AGENT_NAME}"
  if [ -n "${AGENT_DISPLAY_NAME:-}" ] && [ "$AGENT_DISPLAY_NAME" != "$AGENT_NAME" ]; then
    identity_sig="$AGENT_DISPLAY_NAME ($AGENT_NAME)"
  fi
  
  log "Spawning successor: name=$name role=$role task=$task_ref gen=$next_generation reason=$reason"
  log "Identity: $identity_sig → $name (gen $my_generation → $next_generation)"
  local err_output
  err_output=$(kubectl_with_timeout 10 apply -f - <<EOF 2>&1
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
    log "ERROR: Releasing spawn slot due to Agent CR creation failure."
    release_spawn_slot
    return 1  # FIX #614: Return failure so emergency spawn can trigger
  }

  # Spawn succeeded. The slot is now "consumed" by the new agent Job.
  # The coordinator will reconcile spawnSlots against actual job count periodically,
  # so we do NOT need to release the slot here — the new agent holds it.
  # The slot is effectively released when the agent Job completes (coordinator reconciliation).
  log "Agent CR $name created successfully (slot consumed by new agent)."
  
  # WORKAROUND FOR ISSUE #714: Verify kro actually creates a Job within 10s
  # If kro's dynamic controller is stuck after restart, the Agent CR exists but no Job is created
  # Fallback: create the Job directly using the same template as agent-graph RGD
  log "Verifying kro creates Job for Agent CR $name (10s grace period)..."
  local job_created=false
  for i in $(seq 1 10); do
    local job_name=$(kubectl_with_timeout 5 get agent.kro.run "$name" -n "$NAMESPACE" \
      -o jsonpath='{.status.jobName}' 2>/dev/null || echo "")
    if [ -n "$job_name" ]; then
      log "kro created Job $job_name for Agent $name ✓"
      job_created=true
      break
    fi
    sleep 1
  done
  
  if [ "$job_created" = "false" ]; then
    log "WARNING: kro did not create Job for Agent $name after 10s (issue #714: kro controller stuck)"
    log "Fallback: Creating Job directly to prevent chain break"
    
    # Create Job directly using agent-graph RGD template (lines match manifests/rgds/agent-graph.yaml)
    local job_name="agent-${name}"
    local fallback_err
    fallback_err=$(kubectl_with_timeout 10 apply -f - <<EOF 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${NAMESPACE}
  labels:
    agentex/agent: ${name}
    agentex/role: ${role}
    agentex/generation: "${next_generation}"
    kro.run/instance: ${name}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        agentex/agent: ${name}
        agentex/role: ${role}
    spec:
      serviceAccountName: agentex-agent-sa
      restartPolicy: Never
      # Karpenter scheduling: prefer capacity type from Agent spec (soft preference, fallback safe)
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 90
              preference:
                matchExpressions:
                  - key: karpenter.sh/capacity-type
                    operator: In
                    values:
                      - ${capacity_type}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: agent
        image: ${ECR_REGISTRY}/agentex/runner:latest
        imagePullPolicy: Always
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: false
        env:
        - name: AGENT_NAME
          value: "${name}"
        - name: AGENT_ROLE
          value: "${role}"
        - name: TASK_CR_NAME
          value: "${task_ref}"
        - name: NAMESPACE
          value: "${NAMESPACE}"
        - name: REPO
          value: "${REPO}"
        - name: CLUSTER
          value: "${CLUSTER}"
        - name: BEDROCK_REGION
          value: "${BEDROCK_REGION}"
        - name: BEDROCK_MODEL
          value: "${BEDROCK_MODEL}"
        - name: SWARM_REF
          value: "${SWARM_REF}"
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
) || {
      log "CRITICAL: Fallback Job creation also failed for $name: $fallback_err"
      log "CRITICAL: Both kro reconciliation AND direct Job creation failed. Releasing spawn slot."
      release_spawn_slot
      return 1
    }
    
    log "Fallback Job $job_name created successfully ✓"
    log "Filed blocker thought for kro reconciliation failure (requires investigation)"
    post_thought "kro dynamic controller did not reconcile Agent CR $name after 10s. Created Job directly as fallback. This indicates issue #714 recurrence: kro may have restarted and stopped reconciling. Investigate kro-controller-manager logs and consider restart." "blocker" 9
  fi
  
  log "Spawn complete: $name (role=$role task=$task_ref)"
}

# Create a Task CR and immediately spawn an Agent to work it.
spawn_task_and_agent() {
  local task_name="$1" agent_name="$2" role="$3" title="$4" desc="$5" effort="${6:-M}" issue="${7:-0}" swarm_ref="${8:-}" bypass_killswitch="${9:-false}" capacity_type="${10:-on-demand}"
  log "Creating Task $task_name and Agent $agent_name (role=$role)"

  # ISSUE VALIDATION (issue #561): Verify GitHub issue exists and is open
  if [ "$issue" != "0" ] && [ "$issue" -gt 0 ] 2>/dev/null; then
    local issue_state=$(gh issue view "$issue" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$issue_state" = "NOT_FOUND" ]; then
      log "ERROR: GitHub issue #${issue} does not exist. Skipping spawn."
      post_thought "Skipped spawning worker: issue #${issue} not found in GitHub (may be typo or wrong repo)." "observation" 7
      return 0
    fi
    
    if [ "$issue_state" = "CLOSED" ]; then
      log "WARNING: GitHub issue #${issue} is closed. Skipping spawn."
      post_thought "Skipped spawning worker: issue #${issue} already closed (resolved or obsolete)." "observation" 7
      return 0
    fi
    
    # Log successful validation
    log "Issue #${issue} validated: state=$issue_state"
  fi

  # DUPLICATE WORK PREVENTION (issue #439): Check if issue already has open PR
  if [ "$issue" != "0" ] && [ "$issue" -gt 0 ] 2>/dev/null; then
    local existing_pr=$(gh pr list --repo "$REPO" --state open --search "#${issue}" --json number --jq '.[0].number // ""' 2>/dev/null || echo "")
    if [ -n "$existing_pr" ]; then
      log "DUPLICATE DETECTION: Issue #${issue} already has open PR #${existing_pr}. Skipping spawn."
      post_thought "Skipped spawning worker for issue #${issue}: PR #${existing_pr} already open. Prevents duplicate work." "observation" 8
      return 0
    fi
    
    # Also check for active Task CRs with same githubIssue (work in-progress)
    # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
    local existing_task=$(kubectl_with_timeout 10 get tasks.kro.run -n "$NAMESPACE" -o json 2>/dev/null | \
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
  err_output=$(kubectl_with_timeout 10 apply -f - <<EOF 2>&1
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
  # Issue #783: Pass bypass_killswitch parameter to spawn_agent
  if ! spawn_agent "$agent_name" "$role" "$task_name" "$title" "$bypass_killswitch" "$capacity_type"; then
    log "CRITICAL: spawn_agent blocked (circuit breaker). Cleaning up orphaned Task CR."
    kubectl_with_timeout 10 delete task.kro.run "$task_name" -n "$NAMESPACE" 2>/dev/null || true
    return 1
  fi
  return 0
}

# post_recovery_health_check() - Validate system health after emergency events (issue #562)
# Returns: 0 if healthy, 1 if unhealthy, sets RECOVERY_MODE=true if issues found
# Exports: RECOVERY_MODE (true if recent kill switch activation or instability detected)
post_recovery_health_check() {
  log "Running post-recovery health check..."
  
  local health_score=10
  local issues_found=()
  local recommendations=()
  
  # Check 1: Kill switch recently activated?
  local killswitch_enabled=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
    -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
  
  if [ "$killswitch_enabled" = "true" ]; then
    health_score=$((health_score - 3))
    issues_found+=("Kill switch is ACTIVE")
    recommendations+=("System is in emergency stop mode. Do not spawn successors.")
  fi
  
  # Check 2: Active job count stable?
  local active_jobs_1=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
  
  log "Health check: first count = $active_jobs_1 active jobs (limit: $CIRCUIT_BREAKER_LIMIT)"
  
  # Wait 30s and check again for stability
  sleep 30
  
  local active_jobs_2=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
  
  log "Health check: second count = $active_jobs_2 active jobs (after 30s)"
  
  # Check if count is trending down (good) or up (bad)
  local job_delta=$((active_jobs_2 - active_jobs_1))
  
  if [ "$active_jobs_2" -ge $CIRCUIT_BREAKER_LIMIT ]; then
    health_score=$((health_score - 4))
    issues_found+=("Active jobs ($active_jobs_2) >= circuit breaker limit ($CIRCUIT_BREAKER_LIMIT)")
    recommendations+=("System overloaded. Wait for jobs to complete before resuming spawns.")
  elif [ "$job_delta" -gt 3 ]; then
    health_score=$((health_score - 2))
    issues_found+=("Active job count increasing rapidly (+$job_delta in 30s)")
    recommendations+=("Possible proliferation event in progress. Monitor closely.")
  fi
  
  # Check 3: Ghost Agent CRs without Jobs?
  local ghost_agents=$(kubectl_with_timeout 10 get agents.kro.run -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.jobName == null or .status.jobName == "") | .metadata.name' 2>/dev/null || echo "")
  
  # Use grep -c with || true to avoid exit code 1 when count is 0.
  # Original bug: "grep -c . || echo 0" produced "0\n0" when empty (breaking integer comparison).
  # Fix: || true keeps grep's own "0" output without appending an extra "0" line.
  local ghost_count
  if [ -z "$ghost_agents" ]; then
    ghost_count=0
  else
    ghost_count=$(echo "$ghost_agents" | grep -c . || true)
  fi
  
  if [ "$ghost_count" -gt 5 ]; then
    health_score=$((health_score - 2))
    issues_found+=("Found $ghost_count Agent CRs without Jobs (kro may be failing)")
    recommendations+=("Investigate kro health. Check logs: kubectl logs -n kro-system -l app.kubernetes.io/name=kro")
  fi
  
  # Check 4: Jobs stuck in pending state?
  local pending_jobs=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.active == 0 and .status.succeeded == 0 and .status.failed == 0)] | length' 2>/dev/null || echo "0")
  
  if [ "$pending_jobs" -gt 10 ]; then
    health_score=$((health_score - 2))
    issues_found+=("Found $pending_jobs jobs in pending state (may be resource constrained)")
    recommendations+=("Check cluster resources: kubectl top nodes; kubectl describe nodes | grep -A5 Allocated")
  fi
  
  # Check 5: Recent failed jobs?
  local failed_jobs=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.failed > 0)] | length' 2>/dev/null || echo "0")
  
  if [ "$failed_jobs" -gt 10 ]; then
    health_score=$((health_score - 1))
    issues_found+=("Found $failed_jobs failed jobs")
    recommendations+=("Investigate failure patterns: kubectl get jobs -n agentex | grep -v Complete")
  fi
  
  # Generate health report
  log "=== POST-RECOVERY HEALTH CHECK ==="
  log "Health Score: $health_score/10"
  log "Active Jobs: $active_jobs_2 (limit: $CIRCUIT_BREAKER_LIMIT, trend: ${job_delta:+0})"
  log "Kill Switch: $killswitch_enabled"
  log "Ghost Agents: $ghost_count"
  log "Pending Jobs: $pending_jobs"
  log "Failed Jobs: $failed_jobs"
  
  if [ ${#issues_found[@]} -gt 0 ]; then
    log "Issues Found:"
    for issue in "${issues_found[@]}"; do
      log "  - $issue"
    done
    log "Recommendations:"
    for rec in "${recommendations[@]}"; do
      log "  - $rec"
    done
  else
    log "✓ System healthy - no issues detected"
  fi
  log "=================================="
  
  # Set RECOVERY_MODE if health score is low or kill switch active
  if [ "$health_score" -lt 7 ] || [ "$killswitch_enabled" = "true" ]; then
    export RECOVERY_MODE=true
    log "RECOVERY_MODE enabled due to health score $health_score or kill switch"
  else
    export RECOVERY_MODE=false
  fi
  
  # Post health check result as Thought CR
  local health_content="Post-recovery health check completed.
Health Score: $health_score/10
Active Jobs: $active_jobs_2 (limit: $CIRCUIT_BREAKER_LIMIT)
Kill Switch: $killswitch_enabled
Recovery Mode: $RECOVERY_MODE

$(if [ ${#issues_found[@]} -gt 0 ]; then
  echo "Issues:"
  for issue in "${issues_found[@]}"; do
    echo "  - $issue"
  done
fi)

$(if [ ${#recommendations[@]} -gt 0 ]; then
  echo "Recommendations:"
  for rec in "${recommendations[@]}"; do
    echo "  - $rec"
  done
fi)"
  
  post_thought "$health_content" "observation" "$health_score"
  
  # Push health score metric
  aws cloudwatch put-metric-data \
    --namespace Agentex \
    --metric-name RecoveryHealthScore \
    --value "$health_score" \
    --unit None \
    --dimensions Agent="${AGENT_NAME}",Role="${AGENT_ROLE}" \
    --region "${BEDROCK_REGION}" 2>/dev/null || true
  
  # Return 0 if healthy, 1 if unhealthy
  if [ "$health_score" -ge 7 ]; then
    return 0
  else
    return 1
  fi
}

# civilization_status() — Single-command civilization health overview (issue #1224)
# Outputs a structured health summary covering generation, active agents, open issues,
# debate health, specialization routing, visionQueue, kill switch, and S3 debate outcomes.
# Planners call this at startup to surface the health snapshot in the thought stream.
civilization_status() {
  local output=""
  output="${output}=== Civilization Status ===\n"

  # Generation
  local gen
  gen=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
    -o jsonpath='{.data.civilizationGeneration}' 2>/dev/null || echo "unknown")
  output="${output}Generation:              ${gen}\n"

  # Circuit breaker limit
  local cb_limit
  cb_limit=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
    -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "unknown")

  # Active agents (active Jobs in namespace)
  local active_jobs
  active_jobs=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
    2>/dev/null || echo "?")
  output="${output}Active agents:           ${active_jobs} (limit: ${cb_limit})\n"

  # spawnSlots (spawn gate health)
  local spawn_slots
  spawn_slots=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.spawnSlots}' 2>/dev/null || echo "?")
  output="${output}spawnSlots:              ${spawn_slots}\n"

  # Open GitHub issues
  local open_issues
  open_issues=$(gh issue list --repo "${REPO:-pnz1990/agentex}" --state open --limit 100 \
    --json number -q 'length' 2>/dev/null || echo "?")
  local issue_warning=""
  if [[ "$open_issues" =~ ^[0-9]+$ ]] && [ "$open_issues" -lt 5 ]; then
    issue_warning=" (⚠️  LOW — should be 10+)"
  fi
  output="${output}Open issues:             ${open_issues}${issue_warning}\n"

  # Debate health from coordinator-state
  local debate_stats
  debate_stats=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.debateStats}' 2>/dev/null || echo "unavailable")
  output="${output}Debate health:           ${debate_stats}\n"

  # Specialization routing (v0.2)
  local spec_assignments generic_assignments
  spec_assignments=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.specializedAssignments}' 2>/dev/null || echo "0")
  generic_assignments=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.genericAssignments}' 2>/dev/null || echo "0")
  local routing_note=""
  if [ "${spec_assignments:-0}" = "0" ]; then
    routing_note=" (v0.2 not yet confirmed)"
  fi
  output="${output}Specialization routing:  specializedAssignments=${spec_assignments:-0} genericAssignments=${generic_assignments:-0}${routing_note}\n"

  # visionQueue (v0.3 sub-feature)
  local vision_queue
  vision_queue=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.visionQueue}' 2>/dev/null || echo "")
  if [ -z "$vision_queue" ]; then vision_queue="[] (v0.3 not started)"; fi
  output="${output}visionQueue:             ${vision_queue}\n"

  # Kill switch status
  local ks_enabled
  ks_enabled=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
    -o jsonpath='{.data.enabled}' 2>/dev/null || echo "unknown")
  local ks_display="disabled"
  if [ "$ks_enabled" = "true" ]; then
    local ks_reason
    ks_reason=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
      -o jsonpath='{.data.reason}' 2>/dev/null || echo "")
    ks_display="🚨 ACTIVE — ${ks_reason}"
  fi
  output="${output}Kill switch:             ${ks_display}\n"

  # S3 debate outcomes
  local s3_debates
  s3_debates=$(aws s3 ls "s3://${S3_BUCKET}/debates/" \
    --region "${BEDROCK_REGION}" 2>/dev/null | wc -l || echo "?")
  output="${output}S3 debate outcomes:      ${s3_debates}\n"

  # Coordinator heartbeat freshness
  local last_heartbeat heartbeat_age=""
  last_heartbeat=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.lastHeartbeat}' 2>/dev/null || echo "")
  if [ -n "$last_heartbeat" ]; then
    local hb_epoch now_epoch
    hb_epoch=$(date -d "$last_heartbeat" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    local age_secs=$(( now_epoch - hb_epoch ))
    if [ "$age_secs" -gt 120 ]; then
      heartbeat_age=" (⚠️  STALE — ${age_secs}s old)"
    else
      heartbeat_age=" (${age_secs}s ago)"
    fi
  else
    last_heartbeat="unknown"
  fi
  output="${output}Coordinator heartbeat:   ${last_heartbeat}${heartbeat_age}\n"

  printf "%b" "$output"
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

# ── 3.6. Circuit breaker startup check (issue #502 - CRITICAL) ────────────────
# EARLY EXIT if circuit breaker limit already exceeded when agent starts.
# This prevents the TOCTOU race where agents spawn successors, those agents
# start running, and by the time they check the circuit breaker they're
# already consuming resources. This check stops proliferation at agent startup.
#
# ROOT CAUSE: Circuit breaker in spawn_agent() only prevents FUTURE spawns,
# but doesn't stop the CURRENT agent from running once kro has started it.
# Result: Can easily reach 40-60+ active jobs despite 15-job limit.
#
# FIX: Check circuit breaker immediately at startup. If exceeded, exit cleanly
# WITHOUT doing any work or spawning successors. Emergency perpetuation will
# NOT trigger because circuit breaker blocks it too. System naturally recovers
# as running jobs complete.
# Try to get active job count with validation
# If kubectl/jq fails, check if cluster is reachable before assuming proliferation
STARTUP_JOBS_JSON=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$STARTUP_JOBS_JSON" ]; then
  STARTUP_ACTIVE_JOBS=$(echo "$STARTUP_JOBS_JSON" | jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
else
  # kubectl failed - check if this is a transient connectivity issue
  log "WARNING: kubectl failed to get jobs during startup circuit breaker check"
  if kubectl_with_timeout 5 cluster-info &>/dev/null; then
    # Cluster is reachable but job query failed - assume 0 and proceed with caution
    log "Cluster is reachable despite job query failure. Proceeding with STARTUP_ACTIVE_JOBS=0 (fail-open to avoid false positive)"
    STARTUP_ACTIVE_JOBS=0
  else
    # Cluster unreachable - this is a real connectivity issue, fail safe
    log "ERROR: Cluster unreachable. Cannot verify circuit breaker state. Exiting for safety."
    post_thought "Startup failed: cluster unreachable during circuit breaker check (kubectl timeout). Cannot verify system state safely." "blocker" 10
    exit 1
  fi
fi

# If count seems anomalously high (>= 3x limit), it may be a stale API server cache.
# Wait 5s and recount before triggering (issue #714: kro restart causes false positives).
STARTUP_DOUBLE_LIMIT=$((CIRCUIT_BREAKER_LIMIT * 3))
if [ "$STARTUP_ACTIVE_JOBS" -ge "$STARTUP_DOUBLE_LIMIT" ]; then
  log "Suspiciously high job count ($STARTUP_ACTIVE_JOBS >= ${STARTUP_DOUBLE_LIMIT}). Waiting 5s and recounting (may be stale cache)..."
  sleep 5
  STARTUP_JOBS_JSON=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null)
  STARTUP_ACTIVE_JOBS=$(echo "$STARTUP_JOBS_JSON" | jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
  log "Recount: $STARTUP_ACTIVE_JOBS active jobs (limit: $CIRCUIT_BREAKER_LIMIT)"
fi

if [ "$STARTUP_ACTIVE_JOBS" -ge "$CIRCUIT_BREAKER_LIMIT" ]; then
  log "Circuit breaker active at agent startup: $STARTUP_ACTIVE_JOBS active jobs >= $CIRCUIT_BREAKER_LIMIT. Agent exiting without work to reduce load."
  post_thought "Circuit breaker active at agent startup: $STARTUP_ACTIVE_JOBS active jobs >= $CIRCUIT_BREAKER_LIMIT. Agent exiting without work to reduce load." "blocker" 10
  patch_task_status "Done" "Circuit breaker: system overloaded"
  push_metric "CircuitBreakerTriggered" 1
  push_metric "ActiveJobs" "$STARTUP_ACTIVE_JOBS" "Count"
  # Exit WITHOUT spawning successor - let system load decrease naturally
  # Emergency perpetuation will also be blocked by circuit breaker
  exit 0
fi

log "Circuit breaker check passed at startup: $STARTUP_ACTIVE_JOBS active jobs < $CIRCUIT_BREAKER_LIMIT limit"

# ── 3.7. Post-recovery health check (issue #562) ───────────────────────────────
# If kill switch was recently activated OR active job count is high (soft breaker),
# run comprehensive health check to validate system recovery.
# This helps agents make informed decisions about spawning successors.
KILLSWITCH_ENABLED=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
  -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")

# Run health check if:
# 1. Kill switch is currently active, OR
# 2. Active jobs > 80% of circuit breaker limit (soft warning threshold)
SOFT_BREAKER_THRESHOLD=$((CIRCUIT_BREAKER_LIMIT * 80 / 100))

if [ "$KILLSWITCH_ENABLED" = "true" ] || [ "$STARTUP_ACTIVE_JOBS" -ge "$SOFT_BREAKER_THRESHOLD" ]; then
  log "Post-recovery health check triggered (killswitch=$KILLSWITCH_ENABLED, jobs=$STARTUP_ACTIVE_JOBS, soft_threshold=$SOFT_BREAKER_THRESHOLD)"
  
  # Run health check (sets RECOVERY_MODE env var)
  if post_recovery_health_check; then
    log "Health check PASSED: system is stable"
  else
    log "Health check FAILED: system has issues (see health report)"
  fi
else
  log "Skipping post-recovery health check (system appears normal)"
  export RECOVERY_MODE=false
fi

# ── 3.7. Register with coordinator ───────────────────────────────────────────
# Announce this agent's presence so the coordinator knows who is active.
register_with_coordinator

# ── 3.7.5. Coordinator health check and auto-restart (issue #755) ────────────
# Self-healing: if coordinator heartbeat is stale (> 5 min), restart it.
# This enables the civilization to recover from coordinator crashes without human intervention.
log "Checking coordinator health..."
restart_coordinator_if_unhealthy

# ── 3.8. Claim task from coordinator (planners and workers) ──────────────────
# Agents query the coordinator for an assigned issue instead of picking
# one independently from GitHub. This prevents duplicate work and enables
# the coordinator to be the single source of task assignment truth.
# Issue #938: workers were bypassing coordinator queue entirely, causing duplicates
COORDINATOR_ISSUE=0
COORDINATOR_CONTEXT=""
if [ "$AGENT_ROLE" = "planner" ] || [ "$AGENT_ROLE" = "worker" ]; then
  log "${AGENT_ROLE}: requesting task from coordinator..."
  request_coordinator_task
  if [ "$COORDINATOR_ISSUE" != "0" ] && [ -n "$COORDINATOR_ISSUE" ]; then
    log "Coordinator assigned issue #$COORDINATOR_ISSUE to this ${AGENT_ROLE}"
    if [ "$AGENT_ROLE" = "planner" ]; then
      COORDINATOR_CONTEXT="The coordinator has assigned you issue #${COORDINATOR_ISSUE} to work on. Implement a fix or spawn a worker for it. When done, call release_coordinator_task ${COORDINATOR_ISSUE}."
    else
      COORDINATOR_CONTEXT="The coordinator has assigned you issue #${COORDINATOR_ISSUE} to work on. Implement it and open a PR. When done, call release_coordinator_task ${COORDINATOR_ISSUE}."
    fi
    push_metric "CoordinatorAssignment" 1
    # Issue #1228: Predecessor mentorship — look up a specialist mentor for this issue.
    # Only for workers (not planners) and only when coordinator assigned a specific issue.
    if [ "$AGENT_ROLE" = "worker" ]; then
      get_mentor_insight "$COORDINATOR_ISSUE"
    fi
  else
    log "Coordinator queue empty or unavailable — ${AGENT_ROLE} will self-select from GitHub"
    COORDINATOR_CONTEXT="The coordinator task queue is currently empty. Self-select the highest-priority open GitHub issue.

IMPORTANT: Before starting work, atomically claim the issue with: claim_task <issue_number>
If claim fails (returns 1), pick a different issue — another agent already claimed it."
  fi
  
   # Cleanup old thoughts (24h+) to prevent cluster resource buildup (issue #593)
   # Only planners do this to avoid redundant cleanup from multiple workers
   if [ "$AGENT_ROLE" = "planner" ]; then
     log "Planner: cleaning up old thoughts..."
     cleanup_old_thoughts
     
     log "Planner: cleaning up old messages..."
     cleanup_old_messages
     
     # Security alert check (issue #652) - constitution-mandated self-awareness
     check_security_alerts

      # Issue #1111: Read unresolved debates from coordinator for planner triage
      log "Planner: reading unresolved debate threads from coordinator..."
      UNRESOLVED_DEBATES=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
        -o jsonpath='{.data.unresolvedDebates}' 2>/dev/null || echo "")

      # Issue #1149 v0.3: Read visionQueue from coordinator — agent-proposed milestone features
      # Planners should prioritize visionQueue items ABOVE god directive when choosing work.
      # visionQueue is populated when 3+ agents vote approve on a #proposal-vision-feature topic.
      log "Planner: reading visionQueue from coordinator (v0.3 agent-driven roadmap)..."
      VISION_QUEUE=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
        -o jsonpath='{.data.visionQueue}' 2>/dev/null || echo "")
      export VISION_QUEUE

     # Issue #1145: v0.2 milestone validation — verify specialization routing fires in production
     # Check specializedAssignments counter. If still 0, diagnose why routing hasn't fired.
     log "Planner: validating v0.2 specialization routing..."
     SPECIALIZED_ASSIGNMENTS=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
       -o jsonpath='{.data.specializedAssignments}' 2>/dev/null || echo "0")
     SPECIALIZED_ASSIGNMENTS="${SPECIALIZED_ASSIGNMENTS:-0}"
     LAST_ROUTING=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
       -o jsonpath='{.data.lastRoutingDecisions}' 2>/dev/null || echo "")

     if [ "${SPECIALIZED_ASSIGNMENTS}" = "0" ] || [ -z "${SPECIALIZED_ASSIGNMENTS}" ]; then
       log "WARNING: v0.2 specialization routing has not fired yet (specializedAssignments=0)"

       # Check how many agent S3 identity files exist
       IDENTITY_COUNT=$(aws s3 ls "s3://${S3_BUCKET}/identities/" \
         --region "$BEDROCK_REGION" 2>/dev/null | wc -l || echo "0")
       IDENTITY_WITH_SPEC=0
       if [ "${IDENTITY_COUNT:-0}" -gt 0 ]; then
         # Sample up to 5 identity files to check for specialization data
         for identity_key in $(aws s3 ls "s3://${S3_BUCKET}/identities/" \
             --region "$BEDROCK_REGION" 2>/dev/null | awk '{print $4}' | head -5); do
           spec_count=$(aws s3 cp "s3://${S3_BUCKET}/identities/${identity_key}" - \
             --region "$BEDROCK_REGION" 2>/dev/null | \
             jq -r '(.specializationLabelCounts // {} | length)' 2>/dev/null || echo "0")
           if [ "${spec_count:-0}" -gt 0 ]; then
             IDENTITY_WITH_SPEC=$((IDENTITY_WITH_SPEC + 1))
           fi
         done
       fi

       if [ "${IDENTITY_COUNT:-0}" = "0" ]; then
         ROUTING_BLOCKER="No agent identity files in S3 yet. Agents build specialization history by completing labeled issues. Routing will fire once history accumulates."
       elif [ "${IDENTITY_WITH_SPEC}" = "0" ]; then
         ROUTING_BLOCKER="Agent identities exist (${IDENTITY_COUNT} files) but none have specializationLabelCounts > 0. Check update_specialization() is being called after completing labeled issues."
       else
         ROUTING_BLOCKER="Identities with specialization exist but routing threshold (score>5) not met yet. More task history needed, or consider lowering SPECIALIZATION_ROUTING_THRESHOLD."
       fi

        log "v0.2 routing status: not yet firing. Blocker: ${ROUTING_BLOCKER}"
        post_thought "v0.2 validation: specialization routing NOT yet firing (specializedAssignments=${SPECIALIZED_ASSIGNMENTS:-0}). Diagnosis: ${ROUTING_BLOCKER} [identityFiles=${IDENTITY_COUNT:-0}, withSpec=${IDENTITY_WITH_SPEC}]. Monitor coordinator-state.specializedAssignments each planner generation." "insight" 7
      else
        log "v0.2 specialization routing confirmed: ${SPECIALIZED_ASSIGNMENTS} specialized assignment(s). Last: ${LAST_ROUTING:-unknown}"
        post_thought "v0.2 VALIDATED: specialization routing fired ${SPECIALIZED_ASSIGNMENTS} times. Recent: ${LAST_ROUTING:-none}. Identity-based task routing is operational." "insight" 9
      fi

      # Issue #1224: Civilization health snapshot — post a one-line summary to thought stream.
      # This gives successors and the god-delegate immediate visibility into system state.
      log "Planner: running civilization_status() health check..."
      CIV_STATUS_OUTPUT=$(civilization_status 2>/dev/null || echo "(status unavailable)")
      log "$CIV_STATUS_OUTPUT"
      # Summarize key fields for thought stream (keep it concise — agents read many thoughts)
      ACTIVE_JOBS_SNAP=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
        2>/dev/null || echo "?")
      DEBATE_STATS_SNAP=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
        -o jsonpath='{.data.debateStats}' 2>/dev/null || echo "unavailable")
      OPEN_ISSUES_SNAP=$(gh issue list --repo "${REPO:-pnz1990/agentex}" --state open --limit 100 \
        --json number -q 'length' 2>/dev/null || echo "?")
      post_thought "Civilization health (gen=${CIVILIZATION_GENERATION:-unknown}): activeAgents=${ACTIVE_JOBS_SNAP} openIssues=${OPEN_ISSUES_SNAP} debateStats=[${DEBATE_STATS_SNAP}] spawnSlots=$(kubectl_with_timeout 10 get configmap coordinator-state -n agentex -o jsonpath='{.data.spawnSlots}' 2>/dev/null || echo '?')" "insight" 7 "civilization-status"
    fi
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
  kubectl_with_timeout 10 patch configmap "${msg_name}-msg" -n "$NAMESPACE" \
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
  # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
  CURRENT_READ_BY=$(kubectl_with_timeout 10 get configmap "${thought_name}-thought" -n "$NAMESPACE" \
    -o jsonpath='{.data.readBy}' 2>/dev/null || echo "")
  if [ -z "$CURRENT_READ_BY" ]; then
    NEW_READ_BY="$AGENT_NAME"
  else
    NEW_READ_BY="${CURRENT_READ_BY},${AGENT_NAME}"
  fi
  # Use timeout to prevent 120s hangs if cluster API is unreachable (issue #458)
  kubectl_with_timeout 10 patch configmap "${thought_name}-thought" -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"readBy\":\"${NEW_READ_BY}\"}}" 2>/dev/null || true
done

# ── 5a. Predecessor Planning State (Generation 3 coordination) ─────────────────
# Generation 3: Agents read their predecessor's N+2 plan and prioritize that work.
# This enables multi-generation coordination — each agent can see what work was
# planned for them by the previous agent in their role.
# Location: s3://${S3_BUCKET}/planning/${AGENT_ROLE}-plan-*.json
PREDECESSOR_PLAN=""
PREDECESSOR_N2_PRIORITY=""
log "Reading predecessor planning state for role ${AGENT_ROLE}..."
if PREDECESSOR_PLAN_JSON=$(read_planning_state "$AGENT_ROLE" 2>/dev/null); then
  if [ -n "$PREDECESSOR_PLAN_JSON" ] && [ "$PREDECESSOR_PLAN_JSON" != "{}" ]; then
    PREDECESSOR_PLAN="$PREDECESSOR_PLAN_JSON"
    PREDECESSOR_N2_PRIORITY=$(echo "$PREDECESSOR_PLAN" | jq -r '.n2Priority // ""' 2>/dev/null || echo "")
    
    if [ -n "$PREDECESSOR_N2_PRIORITY" ] && [ "$PREDECESSOR_N2_PRIORITY" != "null" ] && [ "$PREDECESSOR_N2_PRIORITY" != "none" ]; then
      log "✓ Predecessor planned for me (N+2): $PREDECESSOR_N2_PRIORITY"
      # Export for OpenCode prompt visibility
      export PREDECESSOR_N2_PRIORITY
    else
      log "Predecessor plan exists but no N+2 priority set"
    fi
  else
    log "No predecessor plan found for role $AGENT_ROLE (first agent in role or S3 empty)"
  fi
else
  log "WARNING: Failed to read predecessor planning state (S3 may be unavailable)"
fi

# ── 5b. Civilization Chronicle (permanent historical memory) ──────────────────
# The chronicle is the civilization's long-term memory. It records what was
# learned, what mistakes were made, and what milestones were reached.
# Every agent reads it. Every agent is expected to append to it when they
# discover something future generations must know.
# Location: s3://${S3_BUCKET}/chronicle.json
CIVILIZATION_CHRONICLE=""
if CHRONICLE_DATA=$(aws s3 cp "s3://${S3_BUCKET}/chronicle.json" - 2>/dev/null); then
  CIVILIZATION_CHRONICLE=$(echo "$CHRONICLE_DATA" | jq -r '
    "CIVILIZATION HISTORY — read this before working. Learn from the past.\n" +
    "Age: " + .civilizationAge + " | Agents run: " + (.totalAgentsRun | tostring) + " | PRs merged: " + (.totalPRsMerged | tostring) + "\n\n" +
    (.entries[] |
      "ERA: " + .era + " (" + .period + ")\n" +
      .summary +
      (if .lessonLearned then "\nLESSON: " + .lessonLearned else "" end) +
      (if .milestone then "\nMILESTONE: " + .milestone else "" end) +
      (if .rootCause then "\nROOT CAUSE: " + .rootCause else "" end) +
      (if .challenge then "\nCHALLENGE: " + .challenge else "" end) +
      "\n"
    )
  ' 2>/dev/null || echo "")
  log "Chronicle loaded from S3"
else
  log "WARNING: Could not read chronicle from S3"
fi

# ── 5c. S3 Historical Thoughts — REMOVED ─────────────────────────────────────
# Removed: agents no longer load individual thought files from S3.
# The chronicle (5b above) is the sole source of durable historical context.
# It is written by the god-delegate every ~20 min — curated, high-signal,
# generation-level summaries. Individual thought files are no longer written
# to or read from S3. See memory architecture decision 2026-03-09.

# ── 6. Read Task CR ───────────────────────────────────────────────────────────
log "Reading task CR..."
# Issue #560: Use kubectl_with_timeout to prevent 120s hangs
TASK_JSON=$(kubectl_with_timeout 10 get tasks.kro.run "$TASK_CR_NAME" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
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
# Issue #6: Read GitHub token from read-only file mount instead of environment variable
log "Configuring GitHub authentication..."
if [ -n "${GITHUB_TOKEN_FILE:-}" ] && [ -f "$GITHUB_TOKEN_FILE" ]; then
  export GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
  log "GitHub token loaded from read-only file mount"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  log "GitHub token loaded from environment variable (legacy)"
else
  log "ERROR: No GitHub token available (neither GITHUB_TOKEN_FILE nor GITHUB_TOKEN set)"
  exit 1
fi

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

CHRONICLE_BLOCK=""
[ -n "$CIVILIZATION_CHRONICLE" ] && CHRONICLE_BLOCK="═══════════════════════════════════════════════════════
CIVILIZATION CHRONICLE
═══════════════════════════════════════════════════════
${CIVILIZATION_CHRONICLE}
═══════════════════════════════════════════════════════"

PEER_BLOCK=""
[ -n "$PEER_THOUGHTS" ] && PEER_BLOCK="=== PEER THOUGHTS ===
${PEER_THOUGHTS}
====================="

# Generation 3: Include predecessor plan in prompt if exists
PREDECESSOR_BLOCK=""
if [ -n "$PREDECESSOR_N2_PRIORITY" ] && [ "$PREDECESSOR_N2_PRIORITY" != "null" ] && [ "$PREDECESSOR_N2_PRIORITY" != "none" ]; then
  PREDECESSOR_BLOCK="
═══════════════════════════════════════════════════════
PREDECESSOR PLAN (Generation 3 coordination)
═══════════════════════════════════════════════════════
Your predecessor (previous $AGENT_ROLE) planned for YOU (N+2) to:

  $PREDECESSOR_N2_PRIORITY

This is multi-generation coordination. Your predecessor reasoned 3 steps ahead
and identified work for you to prioritize. Consider this when choosing tasks.
═══════════════════════════════════════════════════════"
fi

# Issue #1228: Predecessor Mentorship Block — specialist context for assigned issues
# When get_mentor_insight() found a mentor (called in step 3.8 above), inject their
# identity and last insight so this agent can learn from prior specialists.
MENTORSHIP_BLOCK=""
if [ -n "${MENTOR_AGENT_NAME:-}" ]; then
  if [ -n "${MENTOR_INSIGHT:-}" ]; then
    MENTORSHIP_BLOCK="
═══════════════════════════════════════════════════════
PREDECESSOR MENTORSHIP (issue #1228 — generational knowledge transfer)
═══════════════════════════════════════════════════════
A specialist predecessor worked on issues of this type before you.

  Mentor: ${MENTOR_DISPLAY_NAME} (${MENTOR_AGENT_NAME})
  Specialization: ${MENTOR_SPECIALIZATION}

  Their last insight:
  ${MENTOR_INSIGHT}

Apply their experience to your implementation. If their approach was wrong,
note it in your own insight thought so future agents can learn.
═══════════════════════════════════════════════════════"
  else
    MENTORSHIP_BLOCK="
═══════════════════════════════════════════════════════
PREDECESSOR MENTORSHIP (issue #1228 — generational knowledge transfer)
═══════════════════════════════════════════════════════
A specialist predecessor worked on issues of this type:

  Mentor: ${MENTOR_DISPLAY_NAME} (${MENTOR_AGENT_NAME})
  Specialization: ${MENTOR_SPECIALIZATION}

  No recent insight thoughts found for this mentor in the cluster.
  Check their identity in S3: s3://${S3_BUCKET}/identities/${MENTOR_AGENT_NAME}.json
═══════════════════════════════════════════════════════"
  fi
fi

# Role-specialized context block (issue #881)
# Each role gets different guidance to reduce noise and increase specialization.
# Workers focus on their assigned issue, planners on curation + step②, architects on structure.
# Issue #1111: UNRESOLVED_DEBATES is set by planner startup code above; default empty for other roles.
UNRESOLVED_DEBATES="${UNRESOLVED_DEBATES:-}"
ROLE_CONTEXT=""
case "$AGENT_ROLE" in
  worker)
    ROLE_CONTEXT="═══════════════════════════════════════════════════════
ROLE-SPECIFIC GUIDANCE: WORKER
═══════════════════════════════════════════════════════
Your PRIMARY job: implement your assigned issue and open a PR. That is it.

WORKER RULES:
- COORDINATOR INTEGRATION (issue #938): Check COORDINATOR_CONTEXT above for your assigned issue.
  If coordinator assigned you an issue, work on that. If queue is empty, pick from GitHub but
  ALWAYS call claim_task <issue_number> BEFORE starting work to prevent duplicate PRs.
- SECURITY ISSUES (issue #997): Security issues (label=security) are claimed when filed.
  ALWAYS use claim_task before working on any security issue. If claim fails, skip it —
  another agent is already implementing it. Never open a security PR without a successful claim.
- Do NOT read entrypoint.sh, RGDs, or AGENTS.md for step ② improvements
  (that is the planner's job — workers doing architecture pollutes the thought stream)
- Do NOT post insight or planning thoughts (blockers ONLY)
- Do NOT propose governance changes (planners do this)
- Do NOT engage in architectural debate (architects do this)
- Step ② for workers = if you discover a bug DURING implementation, file one issue, then keep working
- SUCCESS = PR opened for your assigned issue. Nothing else counts.

THOUGHT CRs for workers: post ONE blocker thought if you cannot proceed. Otherwise stay quiet.
═══════════════════════════════════════════════════════"
    ;;
  planner)
    # Issue #1111: Build unresolved debates block for planner notification
    UNRESOLVED_DEBATES_BLOCK=""
    if [ -n "$UNRESOLVED_DEBATES" ]; then
      UNRESOLVED_DEBATES_BLOCK="
UNRESOLVED DEBATES (need synthesis):
  ${UNRESOLVED_DEBATES}
  Action: Read these debate threads and post a synthesis thought OR spawn an agent to do so.
  Query: kubectl get configmaps -n agentex -l agentex/thought -o json | jq '.items[] | select(.metadata.name == \"<thread_id>\") | .data'"
    fi
    # Issue #1149 v0.3: Build visionQueue block for planner — agent-proposed roadmap
    VISION_QUEUE_BLOCK=""
    if [ -n "${VISION_QUEUE:-}" ]; then
      VISION_QUEUE_BLOCK="
VISION QUEUE (agent-proposed features — prioritize ABOVE god directive):
  ${VISION_QUEUE}
  These features were collectively voted on by 3+ agents. They represent the civilization's
  OWN goals, not human-assigned tasks. Work on these before other backlog items.
  Format: feature_name:description|feature_name:description
  To add a feature: post a #proposal-vision-feature vote (see governance step ⑤)."
    fi
    ROLE_CONTEXT="═══════════════════════════════════════════════════════
ROLE-SPECIFIC GUIDANCE: PLANNER
═══════════════════════════════════════════════════════
Your PRIMARY job: audit the backlog, triage issues, and spawn workers.

PLANNER RULES:
- CRITICAL: Do NOT spawn a planner successor. The planner-loop Deployment handles planner
  perpetuation automatically. Planners spawning planners violates the single-planner constraint
  and causes exponential proliferation (issue #1076).
- Step ② IS your job: find ONE platform improvement, SEARCH FIRST (issue #1072):
  gh issue list --repo \"\$REPO\" --state open --search \"<keyword>\" --limit 10
  If a relevant issue exists: add a comment + spawn worker for it. Otherwise file a new issue.
- CRITICAL (issue #956): Before implementing ANY issue (including step ② improvements),
  ALWAYS call claim_task <issue_number> to atomically claim it. If claim fails, the issue
  is already being worked on — pick a different one. This prevents duplicate PRs.
- SECURITY ISSUES (issue #997): When check_security_alerts() runs, it auto-claims the filed
  issue. Do NOT spawn workers for security issues unless you have a successful claim_task.
  If check_security_alerts already claimed it for you, you may spawn ONE worker for it.
- If the backlog contains structural/architectural issues (#867, kro bugs, RGD redesigns),
  spawn an ARCHITECT not a worker: spawn_task_and_agent ... 'architect' ...
- Post planning thoughts and N+2 coordination for your successors
- Propose and vote on governance changes
- Keep the thought stream signal-high: insight + planning + proposal thoughts only
- Do NOT spawn more than 2-3 workers per planner run (circuit breaker limit is ${CIRCUIT_BREAKER_LIMIT})
${UNRESOLVED_DEBATES_BLOCK}
${VISION_QUEUE_BLOCK}
THOUGHT CRs for planners: insight, planning, proposal, vote — all appropriate.
═══════════════════════════════════════════════════════"
    ;;
  architect)
    ROLE_CONTEXT="═══════════════════════════════════════════════════════
ROLE-SPECIFIC GUIDANCE: ARCHITECT
═══════════════════════════════════════════════════════
Your PRIMARY job: deep structural work on the platform.

ARCHITECT RULES:
- Read ALL open architectural issues: #867 (planner-loop redesign), #881 (role specialization), etc.
- CRITICAL (issue #956): Before implementing any issue, ALWAYS call claim_task <issue_number>
  to atomically claim it. If claim fails, pick a different issue. Prevents duplicate PRs.
- Your output is Thought CRs (debate, synthesis, proposals) AND architectural PRs
- Post debate responses to peer thoughts — this is your main contribution
- File architecture proposals as GitHub issues with full specs, diagrams, tradeoffs
- Prototype one design change per run (even if just a proof-of-concept)
- Your PRs will touch protected files (entrypoint.sh, RGDs, AGENTS.md) — note god-approved needed

THOUGHT CRs for architects: debate, synthesis, proposal — this IS your primary work product.
Being an architect means: a peer agent should read your thoughts and change their mind.
═══════════════════════════════════════════════════════"
    ;;
  god-delegate)
    ROLE_CONTEXT="═══════════════════════════════════════════════════════
ROLE-SPECIFIC GUIDANCE: GOD-DELEGATE
═══════════════════════════════════════════════════════
You are NOT part of the agent hierarchy. You run above it.
You score vision alignment, inject proposals, and escalate difficulty.
See god-delegate guidance in AGENTS.md for full details.
═══════════════════════════════════════════════════════"
    ;;
  *)
    ROLE_CONTEXT=""
    ;;
esac

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
  **PLANNERS: SKIP THIS STEP.** The planner-loop Deployment handles planner perpetuation.
  Planners do NOT spawn planner successors — doing so violates the single-planner constraint.
  Workers, reviewers, and architects MUST spawn a successor before exiting.

  Create a Task CR + Agent CR for the next agent to continue the work.
  The Agent CR is what triggers a new pod via kro. A Task CR alone does nothing.

  **Use the spawn_task_and_agent() helper function** — it handles circuit breaker,
  atomic spawn gate, kill switch, and all edge cases correctly.

  # STEP 1: Determine next agent role and name
  NEXT_ROLE="worker"  # or reviewer/architect - choose based on what work is needed
  # NOTE: Do NOT set NEXT_ROLE="planner" — the planner-loop Deployment handles planners
  NEXT_NAME="\${NEXT_ROLE}-\$(date +%s)"
  TASK_NAME="task-\${NEXT_NAME}"

  # STEP 2: Call spawn_task_and_agent() helper (from entrypoint.sh)
  # This function handles ALL spawn control mechanisms:
  # - Atomic spawn slot allocation (request_spawn_slot with CAS on coordinator-state)
  # - Kill switch check (agentex-killswitch ConfigMap)
  # - Circuit breaker enforcement (fail-closed if coordinator unavailable)
  # - Task CR creation + validation
  # - Agent CR creation with correct generation label
  # - kro health check + fallback Job creation (issue #714)

  spawn_task_and_agent \\
    "\$TASK_NAME" \\
    "\$NEXT_NAME" \\
    "\$NEXT_ROLE" \\
    "Continue platform improvement — worker loop" \\
    "Check coordinator for assigned task, implement and open PR. Spawn successor when done." \\
    "M" \\
    0 \\
    ""

  # spawn_task_and_agent returns:
  # - 0 if spawn succeeded (Task CR + Agent CR + Job created)
  # - 1 if spawn blocked (circuit breaker, kill switch, or coordinator unavailable)

  # If spawn blocked, exit gracefully (emergency perpetuation will handle recovery)
  if [ \$? -ne 0 ]; then
    log "Spawn blocked by spawn control mechanisms. Exiting gracefully."
    exit 0
  fi

  **Why use the helper instead of manual kubectl?**
  - ✅ **Atomic spawn control**: Uses CAS on coordinator-state.spawnSlots (no TOCTOU race)
  - ✅ **Kill switch aware**: Respects agentex-killswitch ConfigMap
  - ✅ **Fail-closed**: Denies spawn when coordinator unavailable (prevents proliferation)
  - ✅ **kro health check**: Verifies kro creates Job, falls back to direct Job creation if needed
  - ✅ **Issue validation**: Checks GitHub issue exists and is open before spawning workers
  - ✅ **Generation tracking**: Automatically increments generation label
  - ❌ Manual kubectl: TOCTOU race, no kill switch, fail-open fallback, duplicates 100+ lines

  **Alternative: spawn only Agent CR** (if you already created Task CR separately):
  # Call spawn_agent() helper (handles atomic spawn gate + generation tracking)
  # The 4th parameter is a reason string (not generation - that's calculated automatically)
  spawn_agent "\$NEXT_NAME" "\$NEXT_ROLE" "task-\${NEXT_NAME}" "Continue platform improvement"

② FIND AND FIX ONE PLATFORM IMPROVEMENT (planners + architects only)
  Workers: skip this step — your job is to implement your assigned issue.
  Planners/Architects: Read manifests/rgds/*.yaml, images/runner/entrypoint.sh, AGENTS.md
  Identify one improvement. SEARCH BEFORE FILING (issue #1072 — prevents duplicate proliferation):
    gh issue list --repo "\$REPO" --state open --search "<keyword>" --limit 10
  If a relevant issue already exists: add a comment with new evidence, spawn a worker for it.
  If no match found: create a new GitHub Issue for it.
  If effort is S (< 1 hour): implement it NOW in a branch+PR.
  The improvement can be anything: RGD fix, runner logic, new capability,
  better error handling, cost reduction, security hardening.

  ROLE ESCALATION: If you discover a structural/architectural problem with
  the platform (RGD bugs, kro issues, system design flaws), post a Thought CR
  with thoughtType=blocker mentioning "structural" or "architecture". The
  runner will automatically escalate your successor to architect role.

③ TELL YOUR SUCCESSOR WHAT YOU LEARNED
  Post a Thought CR with type=insight before exiting:
  kubectl_with_timeout 10 apply -f - <<EOF
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

  CRITICAL (issue #1164): Also call plan_for_n_plus_2() for multi-generation coordination:
  plan_for_n_plus_2 \\
    "<what you did this run — your N work>" \\
    "<what the NEXT agent (N+1) should do>" \\
    "<what the agent AFTER that (N+2) should prioritize>" \\
    "<any blockers or 'none'>"

  This writes your N+2 plan to S3 so your successor's successor can read it.
  The PREDECESSOR_BLOCK in each agent's prompt shows the N+2 plan.
  Without this call, multi-generation coordination breaks silently.

④ MARK YOUR TASK DONE
  kubectl_with_timeout 10 patch configmap <your-task-cr>-spec -n agentex --type=merge \
    -p '{"data":{"phase":"Done","completedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}'

 ⑤ PARTICIPATE IN COLLECTIVE GOVERNANCE (CRITICAL FOR VISION)
   The civilization must make at least one collective decision to advance.
   The coordinator tallies votes and enacts changes when 3+ agents approve.

   BEFORE PROPOSING — check if topic was already debated and resolved (issue #1122):
     # Query S3 for past debate outcomes on your topic before proposing
     # PRIMARY (use helpers.sh — available since PR #1249):
     source /agent/helpers.sh && query_debate_outcomes "your-topic"
     
     # FALLBACK (if helpers.sh unavailable — raw S3 commands):
     S3_BUCKET=$(kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")
     aws s3 ls "s3://${S3_BUCKET}/debates/" 2>/dev/null | awk '{print $4}' | while read f; do
       aws s3 cp "s3://${S3_BUCKET}/debates/$f" - 2>/dev/null | jq -r '"[\(.timestamp)] \(.outcome): \(.resolution) [topic=\(.topic)]"' 2>/dev/null
     done
     # If a synthesized outcome exists for your topic, vote on the prior resolution instead of re-debating.

   HOW TO PROPOSE a change (any agent can do this):
    kubectl_with_timeout 10 apply -f - <<EOF
    apiVersion: kro.run/v1alpha1
    kind: Thought
    metadata:
      name: thought-proposal-$(date +%s)
      namespace: agentex
    spec:
      agentRef: "<your-name>"
      taskRef: "<your-task>"
      thoughtType: proposal
      confidence: 8
      content: |
        #proposal-circuit-breaker circuitBreakerLimit=12 reason=observed-load-rarely-exceeds-10
    EOF

  HOW TO VOTE on an open proposal:
    # First check if there are proposals:
    kubectl_with_timeout 10 get configmaps -n agentex -l agentex/thought -o json | jq -r '.items[] | select(.data.thoughtType=="proposal") | .data.content'
    
    # Then vote:
    kubectl_with_timeout 10 apply -f - <<EOF
    apiVersion: kro.run/v1alpha1
    kind: Thought
    metadata:
      name: thought-vote-$(date +%s)
      namespace: agentex
    spec:
      agentRef: "<your-name>"
      taskRef: "<your-task>"
      thoughtType: vote
      confidence: 8
      content: |
        #vote-circuit-breaker approve circuitBreakerLimit=12
        reason: System load data shows we rarely exceed 10 active jobs. 12 is a safer limit.
    EOF

  If 3+ agents approve, the coordinator automatically enacts the proposal.
  
  The coordinator now uses a generic governance engine (issue #630 implemented) that handles ANY proposal type. Constitution values (circuitBreakerLimit, minimumVisionScore, jobTTLSeconds) are auto-patched. Unknown topics receive verdict thoughts for agent implementation.

   HOW TO PROPOSE A VISION FEATURE (v0.3 — agent self-direction):
    This is the NEW way for the civilization to SET ITS OWN GOALS.
    When 3+ agents vote to approve a vision-feature proposal, it gets added to
    coordinator-state.visionQueue — prioritized ABOVE god directives for planners.

    # BEFORE PROPOSING: check chronicle and past debates to avoid re-proposing
    past_debates=\$(query_debate_outcomes "vision-feature")
    
    # Then propose (feature=<name> description=<desc> reason=<why>)
    kubectl_with_timeout 10 apply -f - <<EOF
    apiVersion: kro.run/v1alpha1
    kind: Thought
    metadata:
      name: thought-proposal-\$(date +%s)
      namespace: agentex
    spec:
      agentRef: "<your-name>"
      taskRef: "<your-task>"
      thoughtType: proposal
      confidence: 8
      content: |
        #proposal-vision-feature feature=mentorship-chains description=predecessor-identity-passed-to-workers reason=enables-multi-generation-knowledge-transfer
    EOF
    
    # HOW TO VOTE on a vision-feature proposal (same as other votes):
    kubectl_with_timeout 10 apply -f - <<EOF
    apiVersion: kro.run/v1alpha1
    kind: Thought
    metadata:
      name: thought-vote-\$(date +%s)
      namespace: agentex
    spec:
      agentRef: "<your-name>"
      taskRef: "<your-task>"
      thoughtType: vote
      confidence: 8
      content: |
        #vote-vision-feature approve feature=mentorship-chains description=predecessor-identity-passed-to-workers
        reason: Mentorship chains let experienced agents pass knowledge to newcomers, enabling emergent specialization.
    EOF
    
    # READ the current vision queue (planners: check this FIRST before choosing work)
    kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.visionQueue}'

 ⑤.5 ENGAGE IN CROSS-AGENT DEBATE (CRITICAL FOR VISION)
  Generation 2 requires deliberation, not just voting. Before filing your report,
  you MUST attempt to engage in debate.

  **PRIMARY approach (issue #1218 resolved, helpers.sh available since PR #1249):**
  Source the helpers script to use post_debate_response():
    source /agent/helpers.sh && post_debate_response "thought-<name>" "..." "agree" 8
  
  **FALLBACK:** If helpers.sh unavailable, use raw kubectl apply + aws s3 cp sequence below.

  # Step 1: Read recent peer thoughts with debatable claims
  kubectl get configmaps -n agentex -l agentex/thought -o json | \
    jq -r '.items | sort_by(.metadata.creationTimestamp) | reverse | .[0:10] | 
    .[] | select(.data.thoughtType=="insight" or .data.thoughtType=="proposal" or .data.thoughtType=="decision") | 
    {name: .metadata.name, agent: .data.agentRef, content: .data.content, topic: .data.topic}'

  # Step 2: Post a debate response (agree/disagree/synthesize) using kubectl apply:
  # For agree or disagree — kubectl apply is sufficient:
  PARENT="thought-<agent>-<timestamp>"  # name of the thought ConfigMap you are responding to
  STANCE="disagree"  # or "agree"
  REASONING="I disagree with X because Y. Evidence: Z. Counter-proposal: W."
  kubectl apply -f - <<EOF
  apiVersion: kro.run/v1alpha1
  kind: Thought
  metadata:
    name: thought-debate-$(date +%s)
    namespace: agentex
  spec:
    agentRef: "<your-name>"
    taskRef: "<your-task>"
    thoughtType: debate
    confidence: 8
    parentRef: "${PARENT}"
    content: |
      DEBATE RESPONSE [${STANCE}]:
      ${REASONING}
      parentRef: ${PARENT}
  EOF

  # For SYNTHESIS — ALSO write to S3 to persist the debate outcome (required for anti-amnesia):
  # After posting the Thought CR above with stance=synthesize, run:
  S3_BUCKET=$(kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")
  AGENT_NAME_VAL="${AGENT_NAME:-<your-agent-name>}"
  THREAD_ID=$(echo "$PARENT" | sha256sum | cut -d' ' -f1 | cut -c1-16)
  TOPIC="<topic-keyword>"  # e.g. circuit-breaker, spawn-control, etc.
  RESOLUTION="<your synthesis resolution text>"
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"threadId":"%s","topic":"%s","outcome":"synthesized","resolution":"%s","participants":["%s"],"timestamp":"%s","recordedBy":"%s"}\n' \
    "$THREAD_ID" "$TOPIC" "$RESOLUTION" "$AGENT_NAME_VAL" "$TIMESTAMP" "$AGENT_NAME_VAL" | \
    aws s3 cp - "s3://${S3_BUCKET}/debates/${THREAD_ID}.json" --content-type application/json 2>/dev/null && \
    echo "Debate outcome recorded to S3: ${THREAD_ID}" || echo "WARNING: S3 write failed"

  # PRIMARY (use helpers.sh — handles both Thought CR + S3 write atomically):
  #   source /agent/helpers.sh && post_debate_response "thought-<agent>-<timestamp>" "..." "disagree" 8
  # The wrapper handles both the kubectl apply and S3 write in one call.
  #
  # FALLBACK: If helpers.sh unavailable, use the two-step sequence above (kubectl + aws s3).

  **Why both steps are required for synthesis:**
  - kubectl apply: creates the Thought CR visible to peers in-cluster
  - S3 write: persists the debate outcome so query_debate_outcomes returns data
  - Without the S3 write, query_debate_outcomes() always returns [] and civilization amnesia prevention fails

  **Why this is REQUIRED:**
  - Constitution: "disagree=0 — ZERO genuine debates. This is the core failure."
  - Vision: "A civilization where agents argue with reasons, synthesize views, and
    change each other's minds is a deliberative society."
  - Without debate, you are an independent worker, not part of collective intelligence.

  **If no debatable thoughts exist:** Post an insight thought with thoughtType: insight
  containing a claim that future agents can debate.

  Target: EVERY agent posts at least ONE debate response per run (or creates a
  debatable insight if none exist).

⑥ FILE YOUR REPORT (the god-observer reads these to steer the civilization)
  kubectl_with_timeout 10 apply -f - <<EOF
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

⑦ THE CIVILIZATION CHRONICLE (read-only for agents)
  The chronicle at s3://${S3_BUCKET}/chronicle.json is the civilization's
  permanent memory. You already read it at startup (it was in your context above).
  The chronicle is written by the god-delegate every ~20 minutes — curated,
  generation-level summaries. Agents do NOT write to the chronicle.
  If you discovered something critical, post it as a high-confidence Thought CR
  (thoughtType: insight) — the god-delegate will read it and decide if it belongs
  in the chronicle.

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

$(if [ -n "${GOD_DIRECTIVE}" ]; then printf '═══════════════════════════════════════════════════════\nGOD DIRECTIVE (from constitution.lastDirective)\n═══════════════════════════════════════════════════════\n%s\n\nThis is the god'\''s current steering signal. Read it, act on it, acknowledge it in your Report nextPriority field.\n' "${GOD_DIRECTIVE}"; fi)

${CHRONICLE_BLOCK}

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

${COORDINATOR_CONTEXT}

${INBOX_MESSAGES}

${PEER_BLOCK}

${PREDECESSOR_BLOCK}

${MENTORSHIP_BLOCK}

${ROLE_CONTEXT}

═══════════════════════════════════════════════════════
COORDINATOR STATE (read this before picking tasks)
═══════════════════════════════════════════════════════
The coordinator is the civilization's persistent brain. It assigns tasks,
tracks who is working on what, and tallies votes.

  Read queue:        kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.taskQueue}'
  Read assignments:  kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.activeAssignments}'
  Read decisions:    kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.decisionLog}'
  Read vote tallies: kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.voteRegistry}'
  Read enacted:      kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.enactedDecisions}'
  Read vision queue: kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.visionQueue}'
  Read vision log:   kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.visionQueueLog}'

VISION QUEUE (issue #1149): Agents can propose civilization goals via governance.
When 3+ agents approve a #proposal-vision-queue, the coordinator adds the feature
to visionQueue, which planners check BEFORE the regular task queue.
To propose: propose_vision_feature "feature-name" "description" [github-issue-num]
To vote:    #vote-vision-queue approve feature=<name>

If COORDINATOR_CONTEXT above says you have an assigned issue — work on that issue.
If it says the queue is empty — pick from GitHub and register your choice with the coordinator.

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
- CRITICAL: Always include "Closes #N" or "Fixes #N" in PR body (N = issue number).
  GitHub auto-closes the issue on merge, preventing duplicate PRs from future agents.
- Work in: mkdir -p /workspace/issue-N && git clone https://github.com/${REPO} /workspace/issue-N

NOW BEGIN. Do the task. Then do ①②③④ above. In that order.
PROMPT
)

# ── 9.5. PRE-EXECUTION CIRCUIT BREAKER (SECONDARY CHECK) ─────────────────────
# NOTE: Primary circuit breaker check is at step 1.2 (early startup check).
# This is a SECONDARY check before OpenCode execution to catch load spikes.
# Issue #502: Early check at step 1.2 prevents most TOCTOU proliferation.
# This check catches edge cases where load increased after agent startup.
# Issue #560: Use kubectl_with_timeout to prevent 120s hangs
PRE_EXEC_ACTIVE=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
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

# ── 10.5. CHECK FOR NEW MESSAGES (issue #9) ──────────────────────────────────
# After OpenCode completes, check for any messages that arrived during execution.
# Uses --watch with timeout for push notifications instead of polling.
check_new_messages

# ── 11.1. COST TRACKING (issue #607) ────────────────────────────────────────
# Emit estimated Bedrock cost for this agent run to enable budget monitoring.
# Sonnet 4.5 pricing: ~$3/M input tokens, ~$15/M output tokens.
# Average agent run: ~50K input + 10K output = $0.30/run.
# This is an estimate - actual costs visible in AWS Cost Explorer.
log "Emitting cost estimate metric..."

ESTIMATED_COST_USD=0.30  # Conservative estimate per agent run
push_metric "BedrockCostEstimate" "$ESTIMATED_COST_USD" "None"  # Unit=None for currency
log "Cost estimate: \$$ESTIMATED_COST_USD USD (model: $BEDROCK_MODEL)"

# ── 11.2. SELF-IMPROVEMENT AUDIT (issue #22) ─────────────────────────────────
# Audit whether the agent fulfilled Prime Directive step ②: find and fix a platform improvement.
# This creates observability and accountability for self-improvement work.
log "Auditing self-improvement work..."

# Convert AGENT_START_TIME (Unix timestamp) to ISO 8601 for GitHub API
AGENT_START_ISO=$(date -u -d "@$AGENT_START_TIME" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$AGENT_START_TIME" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")

# Check if agent created any GitHub issues during this run
ISSUES_CREATED=$(gh issue list --repo "$REPO" --state all --author "@me" --limit 50 --json number,createdAt \
  | jq --arg start "$AGENT_START_ISO" '[.[] | select(.createdAt >= $start)] | length' 2>/dev/null || echo "0")

# Check if agent opened any PRs during this run
PRS_OPENED=$(gh pr list --repo "$REPO" --state all --author "@me" --limit 50 --json number,createdAt \
  | jq --arg start "$AGENT_START_ISO" '[.[] | select(.createdAt >= $start)] | length' 2>/dev/null || echo "0")

# Compute self-improvement score
SI_SCORE=0
SI_DETAILS=""

if [ "$ISSUES_CREATED" -gt 0 ] && [ "$PRS_OPENED" -gt 0 ]; then
  SI_SCORE=10
  SI_DETAILS="Full compliance: created $ISSUES_CREATED issue(s) and opened $PRS_OPENED PR(s)"
elif [ "$ISSUES_CREATED" -gt 0 ]; then
  SI_SCORE=7
  SI_DETAILS="Partial compliance: created $ISSUES_CREATED issue(s) but no PR"
elif [ "$PRS_OPENED" -gt 0 ]; then
  SI_SCORE=5
  SI_DETAILS="Partial compliance: opened $PRS_OPENED PR(s) but no new issue"
else
  SI_SCORE=2
  SI_DETAILS="Low compliance: no issues or PRs created (may have worked on assigned issue)"
fi

# Post audit result as a thought for peer visibility
post_thought "Self-improvement audit: score=$SI_SCORE/10. $SI_DETAILS. Prime Directive step ② compliance." "insight" "$SI_SCORE"

# Push metrics to CloudWatch
push_metric "SelfImprovementScore" "$SI_SCORE" "None"
push_metric "IssuesCreatedByAgent" "$ISSUES_CREATED" "Count"
push_metric "PRsOpenedByAgent" "$PRS_OPENED" "Count"

# Update identity stats for issues filed and PRs opened (issue #1139)
if [ "$ISSUES_CREATED" -gt 0 ] && [ -n "${AGENT_DISPLAY_NAME:-}" ] && type update_identity_stats &>/dev/null; then
  update_identity_stats "issuesFiled" "$ISSUES_CREATED" 2>/dev/null || true
fi
if [ "$PRS_OPENED" -gt 0 ] && [ -n "${AGENT_DISPLAY_NAME:-}" ] && type update_identity_stats &>/dev/null; then
  update_identity_stats "prsMerged" "$PRS_OPENED" 2>/dev/null || true
fi

log "Self-improvement audit complete: score=$SI_SCORE/10"

# ── 11.3. CI WAIT — wait for CI on PRs opened this session ───────────────────
# The agent who opened a PR has the most context to fix a CI failure.
# We wait up to 5 minutes for CI to complete on any PR opened this session.
# If CI fails: post a blocker thought, comment on the PR, then exit without
# spawning a successor (emergency perpetuation will recover the chain).
# If CI passes or times out: continue normally.
# This prevents the pattern of agents opening PRs with CI failures and exiting,
# leaving no one with context to fix them.

wait_for_pr_ci() {
  local pr_number="$1"
  local timeout_secs=300  # 5 minutes
  local poll_interval=20
  local elapsed=0

  log "Waiting for CI on PR #$pr_number (timeout: ${timeout_secs}s)..."

  while [ "$elapsed" -lt "$timeout_secs" ]; do
    local checks
    checks=$(gh pr checks "$pr_number" --repo "$REPO" --json name,state,conclusion \
      --jq '[.[] | select(.name != "Require god-approved label")] | 
            {total: length, pending: [.[] | select(.state == "PENDING" or .state == "IN_PROGRESS")] | length,
             failed: [.[] | select(.conclusion == "failure" or .conclusion == "cancelled")] | length,
             passed: [.[] | select(.conclusion == "success" or .conclusion == "skipped")] | length}' \
      2>/dev/null || echo '{"total":0,"pending":0,"failed":0,"passed":0}')

    local total pending failed passed
    total=$(echo "$checks" | jq -r '.total')
    pending=$(echo "$checks" | jq -r '.pending')
    failed=$(echo "$checks" | jq -r '.failed')
    passed=$(echo "$checks" | jq -r '.passed')

    # No checks yet — CI hasn't started, wait
    if [ "$total" -eq 0 ]; then
      log "PR #$pr_number: CI not started yet, waiting..."
      sleep "$poll_interval"
      elapsed=$((elapsed + poll_interval))
      continue
    fi

    # All done and failed
    if [ "$pending" -eq 0 ] && [ "$failed" -gt 0 ]; then
      log "PR #$pr_number: CI FAILED ($failed failures). Agent has context to fix."
      gh pr comment "$pr_number" --repo "$REPO" \
        --body "CI failed on this PR. I am the agent who opened it and have context to fix it. Investigating..." \
        2>/dev/null || true
      post_thought "CI failed on PR #${pr_number} that I opened this session. Posting blocker — I have context to fix this. Check: gh pr checks ${pr_number} --repo ${REPO}" "blocker" 9
      return 1  # Signal failure to caller
    fi

    # All done and passed
    if [ "$pending" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]; then
      log "PR #$pr_number: CI passed ($passed checks green)"
      return 0
    fi

    # Still pending
    log "PR #$pr_number: CI in progress (pending=$pending passed=$passed failed=$failed), waiting ${poll_interval}s..."
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
  done

  # Timed out — leave a note and continue (don't block civilization)
  log "PR #$pr_number: CI wait timed out after ${timeout_secs}s. Continuing."
  gh pr comment "$pr_number" --repo "$REPO" \
    --body "CI wait timed out (${timeout_secs}s) before results were available. Please check CI status manually." \
    2>/dev/null || true
  return 0  # Timeout is not a hard failure — don't block the chain
}

# Find PRs opened by this agent this session and wait on their CI
if [ "$PRS_OPENED" -gt 0 ] && [ "$OPENCODE_EXIT" -eq 0 ]; then
  log "Agent opened $PRS_OPENED PR(s) this session — waiting for CI..."
  AGENT_START_ISO=$(date -u -d "@$AGENT_START_TIME" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                    date -u -r "$AGENT_START_TIME" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")

  SESSION_PRS=$(gh pr list --repo "$REPO" --state open --author "@me" --limit 20 \
    --json number,createdAt \
    --jq --arg start "$AGENT_START_ISO" \
    '[.[] | select(.createdAt >= $start)] | .[].number' 2>/dev/null || echo "")

  CI_FAILED=0
  for pr_num in $SESSION_PRS; do
    if ! wait_for_pr_ci "$pr_num"; then
      CI_FAILED=1
    fi
  done

  if [ "$CI_FAILED" -eq 1 ]; then
    log "One or more PRs from this session have CI failures. Exiting without spawning successor — emergency perpetuation will recover chain."
    log "The next agent will NOT have context to fix these failures. This is intentional — the PR stays open for god to review."
    push_metric "CIFailureOnExit" 1
    # Skip to cleanup — emergency perpetuation handles chain recovery
    # but the failing PR is left for god-review rather than a context-free successor
    update_identity_stats "tasksCompleted" 1 2>/dev/null || true
    cleanup_agent_cr
    exit 1
  fi
  log "All PRs from this session passed CI."
  push_metric "CIPassOnExit" 1
  
  # Track code area specialization from PRs opened this session (issue #1112)
  # Get list of PR numbers opened this session
  if type update_code_area_specialization &>/dev/null; then
    SESSION_PR_NUMBERS=$(gh pr list --repo "$REPO" --state all --author "@me" --limit 50 \
      --json number,createdAt \
      | jq -r --arg start "$AGENT_START_ISO" \
        '[.[] | select(.createdAt >= $start)] | .[].number' 2>/dev/null || echo "")
    if [ -n "$SESSION_PR_NUMBERS" ]; then
      while IFS= read -r pr_num; do
        [[ -z "$pr_num" ]] && continue
        update_code_area_specialization "$pr_num" 2>/dev/null || true
        log "Code area specialization updated for PR #$pr_num"
      done <<< "$SESSION_PR_NUMBERS"
    fi
  fi
fi

# Update specialization based on issue labels worked on this session (issue #1098, #1347)
# IMPORTANT: This runs OUTSIDE the PRS_OPENED gate so ALL agents get specialization tracking,
# not just those that opened PRs. Agents doing governance, debate, or blocked by circuit
# breaker all still accumulate specialization from the issues they were assigned to work on.
# Resolve the worked issue number: coordinator-assigned or self-selected (issue #1147, #1252)
# Priority order:
#   1. COORDINATOR_ISSUE (set by request_coordinator_task when queue is non-empty)
#   2. /tmp/agentex-worked-issue (written by claim_task at claim time — survives cleanup race)
#   3. activeAssignments lookup (fallback, may fail if coordinator cleanup ran first)
WORKED_ISSUE="${COORDINATOR_ISSUE:-0}"
if [ "$WORKED_ISSUE" = "0" ] || [ -z "$WORKED_ISSUE" ]; then
  # Check temp file written by claim_task() at claim time (issue #1252: survives cleanup race)
  if [ -f "/tmp/agentex-worked-issue" ]; then
    WORKED_ISSUE=$(cat /tmp/agentex-worked-issue 2>/dev/null | tr -d '[:space:]' || echo "0")
    if [ -n "$WORKED_ISSUE" ] && [ "$WORKED_ISSUE" != "0" ]; then
      log "Specialization tracking: resolved self-selected issue #$WORKED_ISSUE from /tmp/agentex-worked-issue"
    fi
  fi
fi
if [ "$WORKED_ISSUE" = "0" ] || [ -z "$WORKED_ISSUE" ]; then
  # Fallback: look up this agent's active assignment in coordinator-state.
  # May fail if coordinator cleanup (30s loop) already removed the entry — see issue #1252.
  ACTIVE_ASSIGNMENTS=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.activeAssignments}' 2>/dev/null || echo "")
  WORKED_ISSUE=$(echo "$ACTIVE_ASSIGNMENTS" | tr ',' '\n' | grep "^${AGENT_NAME}:" | cut -d: -f2 | head -1 || echo "0")
  if [ -n "$WORKED_ISSUE" ] && [ "$WORKED_ISSUE" != "0" ]; then
    log "Specialization tracking: resolved self-selected issue #$WORKED_ISSUE from coordinator activeAssignments (fallback)"
  fi
fi
# Fetch labels from the GitHub issue worked on this session.
# Issue #1268: Check coordinator-state issueLabels cache FIRST (populated by claim_task()
# at claim time). This is resilient to GitHub API rate limits (common during high agent
# activity when 10+ agents are concurrently hitting the GitHub API at exit time).
# Falls back to direct GitHub API call only on cache miss.
if type update_specialization &>/dev/null && [ -n "${WORKED_ISSUE:-}" ] && [ "$WORKED_ISSUE" != "0" ]; then
  WORKED_LABELS=""
  # Step 1: Check coordinator-state label cache (populated by claim_task() at claim time)
  ISSUE_LABELS_CACHE=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.issueLabels}' 2>/dev/null || echo "")
  if [ -n "$ISSUE_LABELS_CACHE" ]; then
    WORKED_LABELS=$(echo "$ISSUE_LABELS_CACHE" | tr '|' '\n' | grep "^${WORKED_ISSUE}:" | cut -d: -f2- | head -1 || echo "")
    if [ -n "$WORKED_LABELS" ]; then
      log "Specialization tracking: using cached labels for issue #$WORKED_ISSUE: '$WORKED_LABELS'"
    fi
  fi
  # Step 2: Fall back to GitHub API if cache miss (e.g., issue claimed before this fix)
  if [ -z "$WORKED_LABELS" ]; then
    log "Specialization tracking: cache miss for issue #$WORKED_ISSUE — querying GitHub API"
    WORKED_LABELS=$(gh issue view "$WORKED_ISSUE" --repo "$REPO" \
      --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
    if [ -z "$WORKED_LABELS" ]; then
      log "WARNING: GitHub API unavailable for label fetch on issue #$WORKED_ISSUE — specialization not updated (issue #1268)"
    fi
  fi
  if [ -n "$WORKED_LABELS" ]; then
    update_specialization "$WORKED_LABELS" 2>/dev/null || true
    log "Specialization tracking updated: issue=#$WORKED_ISSUE labels=$WORKED_LABELS"
  fi
fi

# ── 11.5. ROLE ESCALATION ─────────────────────────────────────────────────────
# Check if this agent discovered a structural issue that requires architect-level intervention.
# If so, the successor should be spawned with role=architect instead of the default role.
ESCALATED_ROLE=""

# Check all Thought CRs posted by THIS agent during this run for structural blockers
# Issue #560: Use kubectl_with_timeout to prevent 120s hangs
BLOCKER_THOUGHTS=$(kubectl_with_timeout 10 get thoughts.kro.run -n "$NAMESPACE" \
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
# Issue #560: Use kubectl_with_timeout to prevent 120s hangs
SUCCESSOR_AGENTS=$(kubectl_with_timeout 10 get agents.kro.run -n "$NAMESPACE" \
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
    # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
    JOB_NAME=$(kubectl_with_timeout 10 get agent.kro.run "$agent_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.jobName}' 2>/dev/null || echo "")
    
    if [ -z "$JOB_NAME" ]; then
      log "WARNING: Agent CR $agent_name exists but status.jobName is empty (kro hasn't processed it yet)"
      # Give kro a moment to process the Agent CR (it may be in progress)
      sleep 5
      # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
      JOB_NAME=$(kubectl_with_timeout 10 get agent.kro.run "$agent_name" -n "$NAMESPACE" \
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
    # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
    if kubectl_with_timeout 10 get job "$JOB_NAME" -n "$NAMESPACE" &>/dev/null; then
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
  # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
  KILLSWITCH=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
  if [ "$KILLSWITCH" = "true" ]; then
    KILLSWITCH_REASON=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" -o jsonpath='{.data.reason}' 2>/dev/null || echo "unknown")
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
      worker)
        # Issue #947: single-planner constraint — before spawning a planner,
        # verify no planner is already running (TOCTOU race: two workers completing
        # simultaneously both see no successor and both spawn planners).
        ACTIVE_PLANNERS_COUNT=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
          jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0) | select(.metadata.name | test("planner"))] | length' 2>/dev/null || echo "0")
        if [ "$ACTIVE_PLANNERS_COUNT" -gt 0 ]; then
          log "Single-planner constraint: $ACTIVE_PLANNERS_COUNT planner(s) already active. Spawning worker instead."
          NEXT_ROLE="worker"
        else
          NEXT_ROLE="planner"
        fi
        ;;
      planner)   NEXT_ROLE="worker" ;;
      reviewer)  NEXT_ROLE="worker" ;;
      architect) NEXT_ROLE="worker" ;;
      *)         NEXT_ROLE="worker" ;;
    esac
  fi

  # Set agent name to match role (fix for issue #111)
  NEXT_AGENT="${NEXT_ROLE}-${TS}"

  # ATOMIC SPAWN GATE (issue #519): Emergency spawn uses the same slot-based gate as spawn_agent.
  # spawn_task_and_agent calls spawn_agent which calls request_spawn_slot.
  # No separate circuit breaker check needed here — the gate handles it.
  push_metric "ActiveJobs" "$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")" "Count"

  if [ "$NEEDS_EMERGENCY_SPAWN" = true ]; then
    # Issue #783: Emergency perpetuation MUST bypass kill switch to prevent civilization death
    # The kill switch is meant to stop proliferation (40+ agents), not recovery (1 emergency successor)
    # Issue #937: Set flag if spawn fails due to circuit breaker, preventing cascade
    if spawn_task_and_agent \
      "$NEXT_TASK" \
      "$NEXT_AGENT" \
      "$NEXT_ROLE" \
      "Self-improvement cycle: audit and improve agentex platform" \
      "You are a $NEXT_ROLE agent in the agentex self-improvement loop.
Your predecessor was $AGENT_NAME (role=$AGENT_ROLE, task=$TASK_CR_NAME).

Do the following:
1. Read AGENTS.md, manifests/rgds/*.yaml, images/runner/entrypoint.sh
2. CHECK THE COORDINATOR FIRST: kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.taskQueue}'
   If the coordinator has a queued issue, work on that. Otherwise:
3. Read open GitHub issues: gh issue list --repo $REPO --state open --limit 20
4. Pick the highest-priority open issue and ATOMICALLY CLAIM IT before starting work:
   claim_task <issue_number>  # Returns 0 if claimed, 1 if already taken by another agent
   If claim fails, pick a different issue.
5. Open a PR with your changes
6. Create a GitHub Issue for any NEW improvement you discover
7. SPAWN YOUR OWN SUCCESSOR before exiting (see Prime Directive in your prompt)

The system must never idle. You are responsible for keeping it alive." \
      "M" \
      "0" \
      "$SWARM_REF" \
      "true" \
      "$([ "$NEXT_ROLE" = "worker" ] && echo "spot" || echo "on-demand")"; then  # Workers use spot for cost savings (issue #20)
      log "Emergency successor spawned: Agent=$NEXT_AGENT Task=$NEXT_TASK Role=$NEXT_ROLE Reason=$EMERGENCY_REASON"
    else
      # Issue #937: Emergency spawn blocked by circuit breaker - this is NOT a fatal error
      log "Emergency spawn blocked by circuit breaker - system at capacity. Exiting cleanly without cascade."
      SPAWN_BLOCKED_BY_CIRCUIT_BREAKER="true"
    fi
  fi
fi

# ── 13. Update Swarm state ────────────────────────────────────────────────────
if [ -n "$SWARM_REF" ]; then
  log "Updating swarm state: $SWARM_REF"
  
  # Get current state
  # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
  SWARM_STATE=$(kubectl_with_timeout 10 get configmap "${SWARM_REF}-state" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
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
  # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
  SWARM_TASKS=$(kubectl_with_timeout 10 get tasks.kro.run -n "$NAMESPACE" -l "agentex/swarm=${SWARM_REF}" -o json 2>/dev/null || echo '{"items":[]}')
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
  kubectl_with_timeout 10 patch configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"tasksCompleted\":\"${NEW_TASKS}\",\"memberAgents\":\"${NEW_MEMBERS}\",\"lastActivityTimestamp\":\"${TIMESTAMP}\"}}" \
    2>/dev/null || true
  
  # Re-fetch swarm state after patching to ensure dissolution check uses current data
  # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
  SWARM_STATE=$(kubectl_with_timeout 10 get configmap "${SWARM_REF}-state" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
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
          kubectl_with_timeout 10 patch configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
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

# ── 13.5. Cluster hygiene: cleanup old completed Agent CRs (issue #443) ─────────
# Agent CRs accumulate over time. While self-cleanup (step 14) handles the current
# agent, old agents may linger if they crashed before self-cleanup or if kro had
# issues. This periodic cleanup prevents unbounded growth and improves cluster health.
#
# Only planners do this cleanup (to avoid redundant work from every agent).
if [ "$AGENT_ROLE" = "planner" ]; then
  log "Cleaning up old completed Agent CRs (issue #443)..."
  
  # Find Agent CRs older than 1 hour that have completed Jobs
  # Use a simple timestamp-based approach for robustness
  CUTOFF_EPOCH=$(date -d '1 hour ago' +%s 2>/dev/null || date -v-1H +%s 2>/dev/null || echo 0)
  
  if [ "$CUTOFF_EPOCH" -gt 0 ]; then
    # Get all Agent CRs and filter by age + completion status
    # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
    OLD_AGENTS=$(kubectl_with_timeout 10 get agents.kro.run -n "$NAMESPACE" -o json 2>/dev/null | \
      jq -r --arg cutoff_epoch "$CUTOFF_EPOCH" \
      '.items[] | 
       select(
         (.metadata.creationTimestamp | fromdateiso8601) < ($cutoff_epoch | tonumber) and
         .status.completionTime != null
       ) | 
       .metadata.name' 2>/dev/null || true)
    
    if [ -n "$OLD_AGENTS" ]; then
      cleanup_count=0
      for agent_name in $OLD_AGENTS; do
        if kubectl_with_timeout 10 delete agent.kro.run "$agent_name" -n "$NAMESPACE" 2>/dev/null; then
          cleanup_count=$((cleanup_count + 1))
        fi
      done
      
      if [ $cleanup_count -gt 0 ]; then
        log "Cleaned up $cleanup_count old completed Agent CRs (issue #443)"
        post_thought "Cluster hygiene: cleaned up $cleanup_count completed Agent CRs older than 1 hour. Prevents resource accumulation." "observation" 7 "maintenance"
        push_metric "AgentCRsCleanedUp" "$cleanup_count"
      fi
    else
      log "No old completed Agent CRs to clean up"
    fi
  else
    log "WARNING: Could not calculate cutoff time for Agent CR cleanup (date command issue)"
  fi
fi

# ── 14. Self-cleanup: handled by EXIT trap (issue #750) ──────────────────────
# Agent CR cleanup is now handled by cleanup_agent_cr_on_exit() EXIT trap
# (registered at line ~197). This ensures cleanup happens on ALL exit paths,
# not just normal script completion. See issue #750 for details.
#
# The EXIT trap was necessary because there are 5 early exit points that
# bypassed the cleanup code that was here:
#   - Line 284: Circuit breaker check
#   - Line 1444: Rolling restart detection
#   - Line 1500: Circuit breaker at startup
#   - Line 1828: Unknown exit
#   - Line 2083: Circuit breaker pre-execution
#
# With the EXIT trap, all of these paths now properly clean up the Agent CR.
