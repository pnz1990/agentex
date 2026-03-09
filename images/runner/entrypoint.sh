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
MY_GENERATION=""  # Set after kubectl config (issue #566)

log() { 
  local gen_suffix=""
  [ -n "${MY_GENERATION:-}" ] && gen_suffix="/gen-${MY_GENERATION}"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}${gen_suffix}] $*"
}

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
      # ATOMIC SPAWN GATE (issue #609): Use request_spawn_slot() instead of racy job count
      # This prevents the error trap from bypassing proliferation controls
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] Requesting spawn slot from atomic gate..." >&2
      if ! request_spawn_slot; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] ATOMIC SPAWN GATE: spawn denied (system at capacity). Agent dying without successor." >&2
        exit $exit_code
      fi
      
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] Spawn slot granted. Attempting emergency spawn..." >&2
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

# ── 1.1.5. Read generation label for log output (issue #566) ──────────────────
# Read generation label to include in log output for better debugging
MY_GENERATION=$(kubectl_with_timeout 10 get agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "")
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

if [ "$EARLY_ACTIVE_JOBS" -ge $CIRCUIT_BREAKER_LIMIT ]; then
  log "EARLY CIRCUIT BREAKER TRIGGERED: System overloaded ($EARLY_ACTIVE_JOBS >= $CIRCUIT_BREAKER_LIMIT)"
  log "Exiting immediately BEFORE resource allocation (identity, inbox, git clone, etc.)"
  log "This prevents TOCTOU proliferation where many agents race through startup steps."
  
  # Post minimal thought without full identity system (identity.sh not yet sourced)
  kubectl apply -f - <<EOF 2>/dev/null || true
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
  local content="$1" type="${2:-observation}" confidence="${3:-7}" topic="${4:-}" file_path="${5:-}" parent_ref="${6:-}"
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
  "topic": "${topic}",
  "filePath": "${file_path}",
  "parentRef": "${parent_ref}",
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

# cleanup_old_thoughts() - Delete thoughts older than 24 hours to prevent clutter
# Should be called periodically by planners
cleanup_old_thoughts() {
  local cutoff_time=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  
  if [ -z "$cutoff_time" ]; then
    log "WARNING: Cannot calculate cutoff time for thought cleanup (date command incompatible)"
    return 0
  fi
  
  local old_thoughts=$(kubectl_with_timeout 10 get thoughts.kro.run -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r --arg cutoff "$cutoff_time" \
    '.items[] | select(.metadata.creationTimestamp < $cutoff) | .metadata.name' 2>/dev/null || true)
  
  if [ -z "$old_thoughts" ]; then
    log "No old thoughts to clean up"
    return 0
  fi
  
  local count=0
  for thought_name in $old_thoughts; do
    if kubectl_with_timeout 10 delete thought.kro.run "$thought_name" -n "$NAMESPACE" 2>/dev/null; then
      count=$((count + 1))
    fi
  done
  
  if [ $count -gt 0 ]; then
    log "Cleaned up $count thoughts older than 24h"
    post_thought "Cleaned up $count thoughts older than 24 hours to prevent cluster clutter" "observation" 7 "maintenance"
  fi
}

# check_security_alerts() - Check for open GitHub code scanning alerts (issue #652)
# Constitution-mandated security self-awareness. Planners run this check each
# generation to detect and file issues for open security vulnerabilities.
# Deduplicates: only creates issue if no existing open security issue found.
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
  
  # Check if there's already an open security issue to avoid duplicate filings
  local existing_issue
  existing_issue=$(gh issue list --repo "$REPO" --label security --state open --limit 1 --json number -q '.[0].number' 2>/dev/null || echo "")
  
  if [ -n "$existing_issue" ]; then
    log "Security issue already exists: #$existing_issue (not filing duplicate)"
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
    local issue_num=$(echo "$new_issue" | grep -oP 'https://github.com/[^/]+/[^/]+/issues/\K[0-9]+' || echo "")
    if [ -n "$issue_num" ]; then
      log "✓ Filed security issue #$issue_num for $alert_count alerts"
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
  if ! aws s3 ls s3://agentex-thoughts/ >/dev/null 2>&1; then
    log "WARNING: S3 bucket agentex-thoughts not accessible, cannot append to chronicle"
    return 0  # Don't fail the agent
  fi
  
  # Optimistic locking with retry (prevent race conditions from concurrent updates)
  local max_retries=3
  local retry_count=0
  
  while [ $retry_count -lt $max_retries ]; do
    # Download current chronicle
    local chronicle_output
    if ! chronicle_output=$(aws s3 cp s3://agentex-thoughts/chronicle.json - 2>&1); then
      log "WARNING: Failed to download chronicle (attempt $((retry_count+1))/$max_retries): $chronicle_output"
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
    if upload_output=$(echo "$updated_chronicle" | aws s3 cp - s3://agentex-thoughts/chronicle.json --content-type application/json 2>&1); then
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
# request_coordinator_task() - Claim an unassigned issue from the coordinator queue
# Returns: sets COORDINATOR_ISSUE to the claimed issue number, or 0 if none available
# This is the mechanism that makes planners coordinate instead of acting independently.
request_coordinator_task() {
  local max_retries=3
  local retry=0

  while [ $retry -lt $max_retries ]; do
    local queue
    queue=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
      -o jsonpath='{.data.taskQueue}' 2>/dev/null || echo "")

    if [ -z "$queue" ]; then
      log "Coordinator: task queue is empty"
      COORDINATOR_ISSUE=0
      return 0
    fi

    # Pick the first issue in the queue
    local claimed_issue
    claimed_issue=$(echo "$queue" | tr ',' '\n' | head -1 | tr -d ' ')

    if [ -z "$claimed_issue" ] || [ "$claimed_issue" = "0" ]; then
      COORDINATOR_ISSUE=0
      return 0
    fi

    # Check if already assigned (activeAssignments format: agent1:issue1,agent2:issue2)
    local assignments
    assignments=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
      -o jsonpath='{.data.activeAssignments}' 2>/dev/null || echo "")

    if echo "$assignments" | grep -q ":${claimed_issue}$\|:${claimed_issue},"; then
      log "Coordinator: issue #$claimed_issue already assigned, skipping"
      COORDINATOR_ISSUE=0
      return 0
    fi

    # Atomically: add to activeAssignments, remove from taskQueue
    local new_queue
    new_queue=$(echo "$queue" | tr ',' '\n' | grep -v "^${claimed_issue}$" | tr '\n' ',' | sed 's/,$//')

    local new_assignments
    if [ -z "$assignments" ]; then
      new_assignments="${AGENT_NAME}:${claimed_issue}"
    else
      new_assignments="${assignments},${AGENT_NAME}:${claimed_issue}"
    fi

    if kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
      --type=merge \
      -p "{\"data\":{\"taskQueue\":\"${new_queue}\",\"activeAssignments\":\"${new_assignments}\"}}" \
      2>/dev/null; then
      log "Coordinator: claimed issue #$claimed_issue (queue was: $queue)"
      push_metric "CoordinatorTaskClaimed" 1
      COORDINATOR_ISSUE="$claimed_issue"
      return 0
    fi

    retry=$((retry + 1))
    sleep 1
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
  local new_assignments
  new_assignments=$(echo "$assignments" | tr ',' '\n' \
    | grep -v "^${AGENT_NAME}:${issue}$" \
    | tr '\n' ',' | sed 's/,$//')

  kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
    --type=merge \
    -p "{\"data\":{\"activeAssignments\":\"${new_assignments}\"}}" \
    2>/dev/null || true

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
    new_val=$(echo "$current" | tr ',' '\n' | grep -v "^${AGENT_NAME}:" | tr '\n' ',' | sed 's/,$//')
    [ -n "$new_val" ] && new_val="${new_val},${AGENT_NAME}:${AGENT_ROLE}" || new_val="${AGENT_NAME}:${AGENT_ROLE}"
  fi

  kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"activeAgents\":\"${new_val}\"}}" 2>/dev/null || true
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
  local max_attempts=5
  local attempt=0

  # Check kill switch first
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

  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))

    # Read current spawnSlots
    local slots
    slots=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
      -o jsonpath='{.data.spawnSlots}' 2>/dev/null || echo "")

    # If coordinator-state missing or spawnSlots not set, fall back to job count (fail-open)
    if [ -z "$slots" ] || ! [[ "$slots" =~ ^[0-9]+$ ]]; then
      log "WARNING: coordinator spawnSlots unavailable, falling back to job count circuit breaker"
      local total_active
      total_active=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
      if [ "$total_active" -ge "$CIRCUIT_BREAKER_LIMIT" ]; then
        log "FALLBACK CIRCUIT BREAKER: $total_active active jobs >= $CIRCUIT_BREAKER_LIMIT. Spawn denied."
        push_metric "CircuitBreakerTriggered" 1
        return 1
      fi
      log "FALLBACK CIRCUIT BREAKER passed: $total_active < $CIRCUIT_BREAKER_LIMIT"
      return 0
    fi

    if [ "$slots" -le 0 ]; then
      log "ATOMIC SPAWN GATE: 0 slots available (limit=$CIRCUIT_BREAKER_LIMIT). Spawn denied."
      post_thought "Atomic spawn gate: 0 slots remaining. Spawn blocked. System at capacity." "blocker" 10
      push_metric "CircuitBreakerTriggered" 1
      return 1
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
  local name="$1" role="$2" task_ref="$3" reason="$4"
  
  # ATOMIC SPAWN GATE (issue #519): Request a spawn slot from the coordinator.
  # This replaces the racy "count jobs → decide to spawn" TOCTOU pattern.
  # The coordinator maintains an atomic counter that prevents concurrent over-spawning.
  if ! request_spawn_slot; then
    log "spawn_agent: spawn slot denied by atomic gate. Not spawning $name."
    return 1
  fi
  local _slot_acquired=true
  
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
    log "ERROR: Releasing spawn slot due to Agent CR creation failure."
    release_spawn_slot
    return 1  # FIX #614: Return failure so emergency spawn can trigger
  }

  # Spawn succeeded. The slot is now "consumed" by the new agent Job.
  # The coordinator will reconcile spawnSlots against actual job count periodically,
  # so we do NOT need to release the slot here — the new agent holds it.
  # The slot is effectively released when the agent Job completes (coordinator reconciliation).
  log "Agent CR $name created successfully (slot consumed by new agent)."
  log "Spawn complete: $name (role=$role task=$task_ref)"
}

# Create a Task CR and immediately spawn an Agent to work it.
spawn_task_and_agent() {
  local task_name="$1" agent_name="$2" role="$3" title="$4" desc="$5" effort="${6:-M}" issue="${7:-0}" swarm_ref="${8:-}"
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
  
  local ghost_count=$(echo "$ghost_agents" | grep -c . || echo "0")
  
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
  if timeout 5s kubectl cluster-info &>/dev/null; then
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

# ── 3.8. Claim task from coordinator (planners only) ─────────────────────────
# Planners query the coordinator for an assigned issue instead of picking
# one independently from GitHub. This prevents duplicate work and enables
# the coordinator to be the single source of task assignment truth.
COORDINATOR_ISSUE=0
COORDINATOR_CONTEXT=""
if [ "$AGENT_ROLE" = "planner" ]; then
  log "Planner: requesting task from coordinator..."
  request_coordinator_task
  if [ "$COORDINATOR_ISSUE" != "0" ] && [ -n "$COORDINATOR_ISSUE" ]; then
    log "Coordinator assigned issue #$COORDINATOR_ISSUE to this planner"
    COORDINATOR_CONTEXT="The coordinator has assigned you issue #${COORDINATOR_ISSUE} to work on. Implement a fix or spawn a worker for it. When done, call release_coordinator_task ${COORDINATOR_ISSUE}."
    push_metric "CoordinatorAssignment" 1
  else
    log "Coordinator queue empty or unavailable — planner will self-select from GitHub"
    COORDINATOR_CONTEXT="The coordinator task queue is currently empty. Self-select the highest-priority open GitHub issue."
  fi
  
  # Cleanup old thoughts (24h+) to prevent cluster resource buildup (issue #593)
  log "Planner: cleaning up old thoughts..."
  cleanup_old_thoughts
  
  # Security alert check (issue #652) - constitution-mandated self-awareness
  check_security_alerts
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
  # Issue #560: Use kubectl_with_timeout to prevent 120s hangs
  CURRENT_READ_BY=$(kubectl_with_timeout 10 get configmap "${thought_name}-thought" -n "$NAMESPACE" \
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

# ── 5b. Civilization Chronicle (permanent historical memory) ──────────────────
# The chronicle is the civilization's long-term memory. It records what was
# learned, what mistakes were made, and what milestones were reached.
# Every agent reads it. Every agent is expected to append to it when they
# discover something future generations must know.
# Location: s3://agentex-thoughts/chronicle.json
CIVILIZATION_CHRONICLE=""
if CHRONICLE_DATA=$(aws s3 cp s3://agentex-thoughts/chronicle.json - 2>/dev/null); then
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

# ── 5c. S3 Historical Thoughts (long-term memory) ─────────────────────────────
# Supplement in-cluster thoughts with recent historical thoughts from S3
# This provides context across cluster restarts and preserves institutional memory
if aws s3 ls s3://agentex-thoughts/ >/dev/null 2>&1; then
  S3_THOUGHTS=""
  
  # Get the 20 most recent thought files from S3 (sorted by modification time)
  # Filter to only thought files (exclude chronicle.json, identities/*.json, etc.)
  # Thought files follow pattern: <agent>-thought-<timestamp>.json (from post_thought line 241)
  S3_FILES=$(aws s3 ls s3://agentex-thoughts/ --recursive 2>/dev/null | \
    grep -E '\-thought-.*\.json$' | \
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
  CIRCUIT_BREAKER_LIMIT=\$(kubectl_with_timeout 10 get configmap agentex-constitution -n agentex \\
    -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "15")
  if ! [[ "\$CIRCUIT_BREAKER_LIMIT" =~ ^[0-9]+\$ ]]; then CIRCUIT_BREAKER_LIMIT=15; fi

  ACTIVE_JOBS=\$(kubectl_with_timeout 10 get jobs -n agentex -o json | \\
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
  MY_GEN=\$(kubectl_with_timeout 10 get agent.kro.run \${AGENT_NAME} -n agentex \\
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

⑤ PARTICIPATE IN COLLECTIVE GOVERNANCE (CRITICAL FOR VISION)
  The civilization must make at least one collective decision to advance.
  The coordinator tallies votes and enacts changes when 3+ agents approve.

  HOW TO PROPOSE a change (any agent can do this):
    kubectl apply -f - <<EOF
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
    kubectl get configmaps -n agentex -l agentex/thought -o json | jq -r '.items[] | select(.data.thoughtType=="proposal") | .data.content'
    
    # Then vote:
    kubectl apply -f - <<EOF
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

  If 3+ agents approve, the coordinator automatically patches agentex-constitution.
  That is the first collective governance act. It has not happened yet. Make it happen.

⑥ FILE YOUR REPORT (the god-observer reads these to steer the civilization)
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

⑦ APPEND TO THE CIVILIZATION CHRONICLE
  The chronicle at s3://agentex-thoughts/chronicle.json is the civilization's
  permanent memory. Future agents will read it. You must add to it if you
  discovered something they should know.

  When to append: if you discovered a recurring mistake, a root cause, a
  milestone, a pattern, or anything that took you time to figure out that
  the next generation should not have to figure out again.

  How to append (use the helper function):
    append_to_chronicle "Era Name" "Agent/generation range" "What happened" "What future agents should know"

  Optional fields (milestone, root cause, challenge):
    append_to_chronicle "Era Name" "Agent-123 to Agent-145" "What happened" "Lesson" "Milestone reached" "Root cause found" "Challenge posed"

  The function handles errors gracefully, prevents race conditions with retries,
  and emits CloudWatch metrics. It will not fail your agent if S3 is unavailable.

  If you have nothing to add, skip this step. But if you fixed a recurring
  bug, discovered a root cause, or reached a milestone — write it down.
  The civilization's memory only exists if you maintain it.

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

log "Self-improvement audit complete: score=$SI_SCORE/10"

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
      worker)    NEXT_ROLE="planner" ;;
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
    spawn_task_and_agent \
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
4. Pick the highest-priority open issue and implement a fix or feature
5. Open a PR with your changes
6. Create a GitHub Issue for any NEW improvement you discover
7. SPAWN YOUR OWN SUCCESSOR before exiting (see Prime Directive in your prompt)

The system must never idle. You are responsible for keeping it alive." \
      "M" \
      "0" \
      "$SWARM_REF"

    log "Emergency successor spawned: Agent=$NEXT_AGENT Task=$NEXT_TASK Role=$NEXT_ROLE Reason=$EMERGENCY_REASON"
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
  timeout 10s kubectl patch configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
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
      local cleanup_count=0
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

# ── 14. Self-cleanup: delete our own Agent CR (issue #597) ───────────────────
# CRITICAL: Agent CRs must be deleted after job completion to prevent kro
# from re-creating Jobs when it restarts. Without this, every kro restart
# causes mass proliferation regardless of the circuit breaker or spawn gate.
#
# This is the last step — runs after spawning successor, updating swarm state,
# and filing the report. The Job itself continues to exist (for log access)
# but the Agent CR is deleted so kro won't try to reconcile it.
log "Self-cleanup: deleting Agent CR $AGENT_NAME to prevent kro re-proliferation (issue #597)"
kubectl_with_timeout 10 delete agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" 2>/dev/null \
  && log "Agent CR $AGENT_NAME deleted successfully" \
  || log "WARNING: Could not delete Agent CR $AGENT_NAME (may already be deleted or kro finalizer pending)"

log "Agent exiting. Task=$TASK_CR_NAME Role=$AGENT_ROLE"
