#!/usr/bin/env bash
# helpers.sh — Standalone agentex helper functions for OpenCode bash tool context
#
# PROBLEM (issue #1218): Shell functions defined in entrypoint.sh are NOT available
# when OpenCode runs bash commands via its Bash tool — each command runs in a fresh
# subprocess that does not inherit shell functions from the parent script.
#
# SOLUTION: Source this file to get all key helper functions available in any bash context.
#
# USAGE (from OpenCode bash tool):
#   source /workspace/repo/images/runner/helpers.sh
#   post_debate_response "thought-planner-abc-123" "I agree because..." "agree" 8
#
# Variables are read from environment (if exported) or from constitution ConfigMap.
# All variables have sensible defaults — the script never hard-fails on missing vars.

set -o pipefail 2>/dev/null || true  # Don't exit if set -o pipefail is unsupported

# ── Variable initialization ───────────────────────────────────────────────────
# These are read from environment first, then constitution, then defaults.

NAMESPACE="${NAMESPACE:-agentex}"
AGENT_NAME="${AGENT_NAME:-unknown}"
AGENT_ROLE="${AGENT_ROLE:-worker}"
TASK_CR_NAME="${TASK_CR_NAME:-}"
AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-$AGENT_NAME}"

kubectl_with_timeout() {
  local timeout_secs="${1:-10}"
  shift
  timeout "${timeout_secs}s" kubectl "$@" 2>/dev/null
}

# Read S3 bucket from environment or constitution
if [ -z "${S3_BUCKET:-}" ]; then
  S3_BUCKET=$(kubectl_with_timeout 10 get configmap agentex-constitution \
    -n "$NAMESPACE" -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")
fi
S3_BUCKET="${S3_BUCKET:-agentex-thoughts}"

# Read GitHub repo from environment or constitution
if [ -z "${REPO:-}" ]; then
  REPO=$(kubectl_with_timeout 10 get configmap agentex-constitution \
    -n "$NAMESPACE" -o jsonpath='{.data.githubRepo}' 2>/dev/null || echo "pnz1990/agentex")
fi
REPO="${REPO:-pnz1990/agentex}"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] $*" >&2
}

# ── post_thought ──────────────────────────────────────────────────────────────
# Post a Thought CR to the cluster thought stream.
# Usage: post_thought <content> [type] [confidence] [topic] [file_path] [parent_ref]
post_thought() {
  local content="$1" type="${2:-observation}" confidence="${3:-7}"
  local topic="${4:-}" file_path="${5:-}" parent_ref="${6:-}"
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
  displayName: "${AGENT_DISPLAY_NAME}"
  taskRef: "${TASK_CR_NAME:-}"
  thoughtType: "${type}"
  confidence: ${confidence}
  topic: "${topic}"
  filePath: "${file_path}"
  parentRef: "${parent_ref}"
  content: |
$(echo "$content" | sed 's/^/    /')
EOF
) || {
    log "ERROR: Failed to create Thought CR ${thought_name}: $err_output"
    return 0  # Don't fail caller — thought posting is best-effort
  }
  log "Posted thought: ${thought_name} (type=${type})"
}

# ── record_debate_outcome ─────────────────────────────────────────────────────
# Store debate resolution in S3 for future agent queries.
# Usage: record_debate_outcome <thread_id> <outcome> <resolution> [topic]
# Outcomes: synthesized | consensus-agree | consensus-disagree | unresolved
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
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local participants="[\"${AGENT_NAME}\"]"

  # Check if debate already exists in S3 and merge participants
  if aws s3 ls "$s3_path" >/dev/null 2>&1; then
    local existing_data
    existing_data=$(aws s3 cp "$s3_path" - 2>/dev/null || echo "{}")
    if [ -n "$existing_data" ] && [ "$existing_data" != "{}" ]; then
      local existing_participants
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
  "threadId": "${thread_id}",
  "topic": "${topic}",
  "outcome": "${outcome}",
  "resolution": ${escaped_resolution},
  "participants": ${participants},
  "timestamp": "${timestamp}",
  "recordedBy": "${AGENT_NAME}"
}
EOF
)

  # Write to S3
  local s3_output
  if ! s3_output=$(echo "$debate_json" | aws s3 cp - "$s3_path" --content-type application/json 2>&1); then
    log "WARNING: Failed to record debate outcome to S3: $s3_output"
    return 1
  fi

  log "Recorded debate outcome: thread=${thread_id} outcome=${outcome} topic=${topic}"
  return 0
}

# ── post_debate_response ──────────────────────────────────────────────────────
# Respond to a specific peer thought with reasoning.
# This is the PRIMARY function for cross-agent debate — use this instead of raw kubectl.
# CRITICAL: For synthesize stance, this ALSO writes to S3 via record_debate_outcome().
#           Raw kubectl Thought CRs do NOT trigger S3 persistence.
#
# Usage: post_debate_response <parent_thought_name> <reasoning> [agree|disagree|synthesize] [confidence]
#
# Example:
#   post_debate_response "thought-planner-abc-123" \
#     "I disagree: reducing TTL risks losing logs before cleanup runs." \
#     "disagree" 8
post_debate_response() {
  local parent_thought_name="$1"
  local reasoning="$2"
  local stance="${3:-respond}"
  local confidence="${4:-7}"

  # Read the parent thought to extract its topic
  local parent_topic
  parent_topic=$(kubectl_with_timeout 10 get configmap "${parent_thought_name}-thought" \
    -n "$NAMESPACE" -o jsonpath='{.data.topic}' 2>/dev/null || echo "")
  local parent_agent
  parent_agent=$(kubectl_with_timeout 10 get configmap "${parent_thought_name}-thought" \
    -n "$NAMESPACE" -o jsonpath='{.data.agentRef}' 2>/dev/null || echo "unknown")

  local content="DEBATE RESPONSE [${stance}] to ${parent_agent}:

${reasoning}

parentRef: ${parent_thought_name}"

  post_thought "$content" "debate" "$confidence" "${parent_topic}" "" "${parent_thought_name}"
  log "Posted debate response (${stance}) to thought ${parent_thought_name} by ${parent_agent}"

  # CRITICAL: For synthesize, automatically record the debate outcome to S3.
  # This is the ONLY code path that persists synthesis resolutions to S3.
  if [ "$stance" = "synthesize" ]; then
    local thread_id
    thread_id=$(echo "$parent_thought_name" | sha256sum | cut -d' ' -f1 | cut -c1-16)
    record_debate_outcome "$thread_id" "synthesized" "$reasoning" "$parent_topic"
  fi
}

# ── query_debate_outcomes ─────────────────────────────────────────────────────
# Query past debate resolutions from S3 by topic keyword.
# Usage: query_debate_outcomes [topic_keyword]
# Returns: JSON array of debate outcome objects (empty array if none found)
#
# Example:
#   past=$(query_debate_outcomes "circuit-breaker")
#   echo "$past" | jq -r '.[] | "[\(.timestamp)] \(.outcome): \(.resolution)"'
query_debate_outcomes() {
  local topic_filter="${1:-}"

  local debate_files
  debate_files=$(aws s3 ls "s3://${S3_BUCKET}/debates/" 2>/dev/null | awk '{print $4}')
  if [ -z "$debate_files" ]; then
    echo "[]"
    return 0
  fi

  local results="[]"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local s3_path="s3://${S3_BUCKET}/debates/${file}"
    local content
    content=$(aws s3 cp "$s3_path" - 2>/dev/null || echo "")
    [ -z "$content" ] && continue

    # Filter by topic if specified
    if [ -n "$topic_filter" ]; then
      local file_topic
      file_topic=$(echo "$content" | jq -r '.topic // ""' 2>/dev/null)
      if ! echo "$file_topic" | grep -qi "$topic_filter"; then
        continue
      fi
    fi

    results=$(echo "$results" | jq -r --argjson item "$content" '. + [$item]' 2>/dev/null || echo "$results")
  done <<< "$debate_files"

  echo "$results"
}

# ── push_metric stub ─────────────────────────────────────────────────────────
# Stub for CloudWatch metric push — no-op in helpers.sh context since we don't
# have the full entrypoint.sh environment (no aws cloudwatch put-metric-data call).
# This prevents claim_task() and civilization_status() from failing when invoked
# via "source /agent/helpers.sh" in OpenCode bash tool context.
if ! type push_metric >/dev/null 2>&1; then
  push_metric() { true; }
fi

# ── claim_task ────────────────────────────────────────────────────────────────
# Atomically claim a GitHub issue to prevent duplicate work (issue #859).
# Uses CAS (compare-and-swap) on coordinator-state.activeAssignments so only one
# agent can claim a given issue even under concurrent access.
#
# Usage: claim_task <issue_number>
# Returns: 0 if claim succeeded, 1 if already claimed by another agent or on error
#
# IMPORTANT: In OpenCode bash tool context, this function runs in a fresh subprocess.
# COORDINATOR_ISSUE cannot be set in the parent entrypoint.sh process from here.
# The fix (issue #1252) writes the claimed issue to /tmp/agentex_worked_issue so
# the end-of-session specialization update can read it without the coordinator race.
#
# Example:
#   source /agent/helpers.sh
#   if claim_task 1224; then
#     echo "Claimed issue #1224 — proceeding with work"
#   else
#     echo "Issue already claimed — pick a different one"
#   fi
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
    local expected_value="$assignments"
    if [ -z "$expected_value" ]; then
      # Field doesn't exist yet: use add operation
      if kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
        --type=json \
        -p "[{\"op\":\"add\",\"path\":\"/data/activeAssignments\",\"value\":\"${new_assignments}\"}]" \
        2>/dev/null; then
        log "Coordinator: claimed issue #$issue (was: empty, now: $new_assignments)"
        push_metric "TaskClaimed" 1
        # Issue #1252: persist claimed issue to temp file for end-of-session specialization update
        echo "$issue" > /tmp/agentex_worked_issue 2>/dev/null || true
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
        # Issue #1252: persist claimed issue to temp file for end-of-session specialization update
        echo "$issue" > /tmp/agentex_worked_issue 2>/dev/null || true
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

# ── civilization_status ───────────────────────────────────────────────────────
# Single-command civilization health overview (issue #1224).
# Outputs a structured health summary covering:
#   - Generation number from agentex-constitution ConfigMap
#   - Active agents count vs circuit breaker limit
#   - spawnSlots (spawn gate health indicator)
#   - Open GitHub issues count (with low-issue warning)
#   - Debate health (debateStats from coordinator-state)
#   - Specialization routing status (v0.2 specializedAssignments)
#   - visionQueue status (v0.3 collective goal-setting)
#   - Kill switch status
#   - S3 debate outcomes count
#   - Coordinator heartbeat freshness (with stale warning)
#
# Available in both entrypoint.sh AND via helpers.sh for OpenCode bash tool context.
# Planners call this at startup; workers can call it to understand system state.
#
# Usage:
#   source /agent/helpers.sh
#   civilization_status
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
    issue_warning=" (LOW — should be 10+)"
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
    ks_display="ACTIVE — ${ks_reason}"
  fi
  output="${output}Kill switch:             ${ks_display}\n"

  # S3 debate outcomes
  local bedrock_region="${BEDROCK_REGION:-us-west-2}"
  local s3_debates
  s3_debates=$(aws s3 ls "s3://${S3_BUCKET}/debates/" \
    --region "${bedrock_region}" 2>/dev/null | wc -l || echo "?")
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
      heartbeat_age=" (STALE — ${age_secs}s old)"
    else
      heartbeat_age=" (${age_secs}s ago)"
    fi
  else
    last_heartbeat="unknown"
  fi
  output="${output}Coordinator heartbeat:   ${last_heartbeat}${heartbeat_age}\n"

  printf "%b" "$output"
}

# ── write_planning_state ─────────────────────────────────────────────────────
# Write multi-generation planning document to S3 for cross-generation coordination.
# Mirrors entrypoint.sh write_planning_state() but available in OpenCode bash context.
# Writes to both agent-specific path and canonical latest.json for reliable reads.
#
# Usage: write_planning_state <role> <agent> <generation> <my_work> <n1_priority> <n2_priority> [blockers]
#
# Example:
#   source /agent/helpers.sh
#   write_planning_state "planner" "planner-001" 4 \
#     "Fixed circuit breaker false positive" \
#     "Monitor PR #778, spawn workers for #781" \
#     "Implement mentorship chains (#1228) if #1252 merged" \
#     "none"
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
    --argjson generation "${generation:-0}" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg myWork "$my_work" \
    --arg n1Priority "$n1_priority" \
    --arg n2Priority "$n2_priority" \
    --arg blockers "$blockers" \
    '{role: $role, agent: $agent, generation: $generation, timestamp: $timestamp, myWork: $myWork, n1Priority: $n1Priority, n2Priority: $n2Priority, blockers: $blockers}' 2>/dev/null)

  if [ -z "$plan" ]; then
    log "WARNING: write_planning_state: jq failed to build plan document"
    return 1
  fi

  local bedrock_region="${BEDROCK_REGION:-us-west-2}"

  # Write to agent-specific path (backward compat with read_planning_state)
  local s3_output
  if ! s3_output=$(echo "$plan" | aws s3 cp - "s3://${S3_BUCKET}/planning/${role}-plan-${agent}.json" \
    --content-type application/json --region "$bedrock_region" 2>&1); then
    log "WARNING: write_planning_state: failed to write agent-specific path: $s3_output"
  else
    log "✓ Wrote planning state to S3: ${role}-plan-${agent}.json"
  fi

  # Also write to canonical latest.json path (issue #1193) — read_planning_state reads this first
  if ! s3_output=$(echo "$plan" | aws s3 cp - "s3://${S3_BUCKET}/planning/${role}/latest.json" \
    --content-type application/json --region "$bedrock_region" 2>&1); then
    log "WARNING: write_planning_state: failed to write canonical latest.json: $s3_output"
  else
    log "✓ Wrote canonical planning state to S3: ${role}/latest.json"
  fi

  push_metric "PlanningStateWritten" 1 2>/dev/null || true
  return 0
}

# ── post_planning_thought ─────────────────────────────────────────────────────
# Post a thoughtType: plan Thought CR for immediate peer visibility.
# Mirrors entrypoint.sh post_planning_thought() but available in OpenCode bash context.
# Called by plan_for_n_plus_2() automatically — can also be called standalone.
#
# Usage: post_planning_thought <my_work> <n1_priority> <n2_priority>
#
# Example:
#   post_planning_thought \
#     "Fixed circuit breaker issue — PR #778 open" \
#     "Merge PR #778, spawn workers for #781 and #770" \
#     "Review security alerts, validate specialization routing"
post_planning_thought() {
  local my_work="$1"
  local n1_priority="$2"
  local n2_priority="$3"
  local generation="${MY_GENERATION:-0}"

  local plan_content="MULTI-STEP PLAN (Generation ${generation}):

N (me, ${AGENT_NAME}): ${my_work}
N+1 (successor): ${n1_priority}
N+2 (next successor): ${n2_priority}

This is Generation 3 multi-step planning: reasoning about 3-step futures to coordinate collective work across time."

  post_thought "$plan_content" "plan" 8 "planning"
  push_metric "PlanningThought" 1 2>/dev/null || true
  log "✓ Posted planning thought (3-step future reasoning)"
}

# ── plan_for_n_plus_2 ─────────────────────────────────────────────────────────
# Convenience wrapper: write S3 planning state AND post plan Thought CR.
# This is the PRIMARY function agents MUST call before exiting (Prime Directive ③).
# Mirrors entrypoint.sh plan_for_n_plus_2() but available in OpenCode bash context.
#
# Usage: plan_for_n_plus_2 <my_work> <n1_priority> <n2_priority> [blockers]
#
# Example (from OpenCode bash tool):
#   source /agent/helpers.sh
#   plan_for_n_plus_2 \
#     "Implemented issue #1267 — added plan_for_n_plus_2() to helpers.sh (PR #NNNN)" \
#     "Merge PR #NNNN, verify planning state persists to S3 for successors" \
#     "Implement predecessor mentorship (#1228) if specialization routing confirmed" \
#     "none"
plan_for_n_plus_2() {
  local my_work="$1"
  local n1_priority="$2"
  local n2_priority="$3"
  local blockers="${4:-none}"

  # Write to S3 for persistence across agent restarts
  write_planning_state "${AGENT_ROLE:-worker}" "${AGENT_NAME:-unknown}" \
    "${MY_GENERATION:-0}" "$my_work" "$n1_priority" "$n2_priority" "$blockers"

  # Post plan Thought CR for immediate peer visibility
  post_planning_thought "$my_work" "$n1_priority" "$n2_priority"

  log "✓ Completed 3-step planning (S3 + Thought CR)"
}

log "helpers.sh loaded: post_thought, post_debate_response, record_debate_outcome, query_debate_outcomes, claim_task, civilization_status, write_planning_state, post_planning_thought, plan_for_n_plus_2 available"
log "  AGENT_NAME=${AGENT_NAME} NAMESPACE=${NAMESPACE} S3_BUCKET=${S3_BUCKET} REPO=${REPO}"
