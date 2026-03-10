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
# Usage: record_debate_outcome <thread_id> <outcome> <resolution> [topic] [component]
# Outcomes: synthesized | consensus-agree | consensus-disagree | unresolved
# component: optional file/component name (e.g. "coordinator.sh", "entrypoint.sh")
#   When provided, also writes to the component knowledge graph index:
#   s3://bucket/knowledge-graph/components/<component>.json
record_debate_outcome() {
  local thread_id="$1"
  local outcome="$2"
  local resolution="$3"
  local topic="${4:-}"
  local component="${5:-}"

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
  "component": "${component}",
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

  log "Recorded debate outcome: thread=${thread_id} outcome=${outcome} topic=${topic} component=${component}"

  # Issue #1609: Update component knowledge graph index if component is specified
  # This enables query_debate_outcomes_by_component() to find relevant debates quickly
  if [ -n "$component" ]; then
    _update_component_knowledge_graph "$component" "$thread_id" "$topic" "$outcome" "$timestamp" "$resolution"
  fi

  return 0
}

# ── _update_component_knowledge_graph ────────────────────────────────────────
# Internal: Update the knowledge graph index for a specific component (file).
# Maintains a rolling window of the 10 most recent debate outcomes per component.
# Path: s3://bucket/knowledge-graph/components/<component-slug>.json
# Called by record_debate_outcome() when component field is non-empty.
# Issue #1609: Phase 2 — coordinator index building.
_update_component_knowledge_graph() {
  local component="$1"
  local thread_id="$2"
  local topic="$3"
  local outcome="$4"
  local timestamp="$5"
  local resolution="$6"

  # Sanitize component name for S3 key: replace / and spaces with -
  local component_slug
  component_slug=$(echo "$component" | tr '/ ' '--' | tr -cd 'a-zA-Z0-9._-')
  [ -z "$component_slug" ] && return 0

  local index_path="s3://${S3_BUCKET}/knowledge-graph/components/${component_slug}.json"
  local escaped_resolution
  escaped_resolution=$(echo "$resolution" | jq -Rs '.')

  # New entry to prepend
  local new_entry
  new_entry=$(cat <<EOF
{
  "threadId": "${thread_id}",
  "topic": "${topic}",
  "outcome": "${outcome}",
  "resolution": ${escaped_resolution},
  "timestamp": "${timestamp}"
}
EOF
)

  # Read existing index (if present) and prepend new entry, keeping last 10
  local existing_index="[]"
  if aws s3 ls "$index_path" >/dev/null 2>&1; then
    existing_index=$(aws s3 cp "$index_path" - 2>/dev/null || echo "[]")
    [ -z "$existing_index" ] && existing_index="[]"
  fi

  local updated_index
  updated_index=$(echo "$existing_index" | jq \
    --argjson entry "$new_entry" \
    '[$entry] + . | unique_by(.threadId) | .[0:10]' 2>/dev/null || echo "[$new_entry]")

  local index_json
  index_json=$(cat <<EOF
{
  "component": "${component}",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "debateCount": $(echo "$updated_index" | jq 'length' 2>/dev/null || echo 1),
  "debates": ${updated_index}
}
EOF
)

  if echo "$index_json" | aws s3 cp - "$index_path" --content-type application/json >/dev/null 2>&1; then
    log "Updated component knowledge graph: component=${component} thread=${thread_id}"
  else
    log "WARNING: Failed to update component knowledge graph for ${component} (non-fatal)"
  fi
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
    if record_debate_outcome "$thread_id" "synthesized" "$reasoning" "$parent_topic"; then
      # Set flag for audit: synthesis was persisted to S3 (anti-amnesia behavior)
      # Use BOTH env var export AND temp file to handle subprocess isolation (issue #1449):
      # - env var: works when called within entrypoint.sh bash process directly
      # - temp file: works when called from OpenCode bash tool subprocess (export doesn't propagate)
      export SYNTHESIS_PERSISTED=1
      touch /tmp/agentex-synthesis-persisted 2>/dev/null || true
    fi
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

# ── query_debate_outcomes_by_component ───────────────────────────────────────
# Query past debate resolutions from the component knowledge graph index.
# Much faster than query_debate_outcomes() — reads a single pre-built index file
# instead of listing and reading all debate files.
# Issue #1609: Phase 2 — component knowledge graph index.
#
# Usage: query_debate_outcomes_by_component <component>
# Returns: JSON array of up to 10 recent debate outcomes for that component
#
# Example:
#   # Before modifying coordinator.sh, check what past debates say about it:
#   past=$(query_debate_outcomes_by_component "coordinator.sh")
#   echo "$past" | jq -r '.[] | "[\(.timestamp)] \(.outcome): \(.resolution[0:100])"'
query_debate_outcomes_by_component() {
  local component="${1:-}"

  if [ -z "$component" ]; then
    log "WARNING: query_debate_outcomes_by_component requires component argument"
    echo "[]"
    return 0
  fi

  # Sanitize component name for S3 key (same as _update_component_knowledge_graph)
  local component_slug
  component_slug=$(echo "$component" | tr '/ ' '--' | tr -cd 'a-zA-Z0-9._-')

  local index_path="s3://${S3_BUCKET}/knowledge-graph/components/${component_slug}.json"

  if ! aws s3 ls "$index_path" >/dev/null 2>&1; then
    # No index yet for this component — fall back to empty
    log "No knowledge graph index found for component: ${component}"
    echo "[]"
    return 0
  fi

  local index_json
  index_json=$(aws s3 cp "$index_path" - 2>/dev/null || echo "{}")
  if [ -z "$index_json" ] || [ "$index_json" = "{}" ]; then
    echo "[]"
    return 0
  fi

  # Return the debates array from the index
  echo "$index_json" | jq -r '.debates // []' 2>/dev/null || echo "[]"
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
# Also writes the issue number to /tmp/agentex-worked-issue so end-of-session
# specialization tracking can find it even after coordinator cleanup removes the
# activeAssignments entry (fix for issue #1252: WORKED_ISSUE=0 race condition).
#
# Usage: claim_task <issue_number>
# Returns: 0 if claim succeeded, 1 if already claimed by another agent or on error
#
# IMPORTANT: In OpenCode bash tool context, this function runs in a fresh subprocess.
# COORDINATOR_ISSUE cannot be set in the parent entrypoint.sh process from here.
# The fix (issue #1252) writes the claimed issue to /tmp/agentex-worked-issue so
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
    # Issue #1488: Normalize spaces before regex check — activeAssignments can contain
    # space-padded entries like "worker-X:123 ,worker-Y:456 " (from pre-PR-#1473 coordinator
    # update_state() or IFS parsing in cleanup_stale_assignments). The regex (,|$) fails on
    # "123 ," because the space precedes the comma, allowing duplicate claims of same issue.
    local normalized_assignments
    normalized_assignments=$(echo "$assignments" | tr -d ' ')
    if echo "$normalized_assignments" | grep -qE "(^|,)[^,]+:${issue}(,|$)"; then
      # Determine who claimed it
      local claimer
      claimer=$(echo "$normalized_assignments" | tr ',' '\n' | grep ":${issue}$" | cut -d: -f1)
      if [ "$claimer" = "$AGENT_NAME" ]; then
        log "Coordinator: issue #$issue already claimed by us ($AGENT_NAME) — continuing"
        # Re-write temp file to ensure it exists (may have been lost across context switches)
        echo "$issue" > /tmp/agentex-worked-issue 2>/dev/null || true
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
        echo "$issue" > /tmp/agentex-worked-issue 2>/dev/null || true
        # Issue #1268: Cache issue labels at claim time for resilient specialization tracking
        _cache_issue_labels "$issue"
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
        echo "$issue" > /tmp/agentex-worked-issue 2>/dev/null || true
        # Issue #1268: Cache issue labels at claim time for resilient specialization tracking
        _cache_issue_labels "$issue"
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

# ── _cache_issue_labels (internal) ───────────────────────────────────────────
# Fetch and cache issue labels in coordinator-state.issueLabels at claim time.
# Called internally by claim_task() — not intended for direct use.
# Issue #1268: decouples specialization tracking from GitHub API availability at exit time.
# Format: coordinator-state.issueLabels = "issue:label1,label2|issue2:label3|..."
_cache_issue_labels() {
  local issue="$1"
  [ -z "$issue" ] || [ "$issue" = "0" ] && return 0

  # Fetch labels now (GitHub API more likely available at claim time than at exit)
  local labels
  labels=$(gh issue view "$issue" --repo "$REPO" \
    --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

  if [ -z "$labels" ]; then
    log "Issue #$issue label cache: no labels found (API unavailable or unlabeled)"
    return 0
  fi

  log "Issue #$issue label cache: labels='$labels'"

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
    local filtered
    filtered=$(echo "$existing_cache" | tr '|' '\n' | grep -v "^${issue}:" | tr '\n' '|' | sed 's/|$//')
    if [ -z "$filtered" ]; then
      new_cache="$new_entry"
    else
      new_cache="${filtered}|${new_entry}"
    fi
  fi

  # Update coordinator-state (best-effort — cache corruption is harmless since
  # the exit handler falls back to GitHub API on cache miss)
  kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"issueLabels\":\"${new_cache}\"}}" \
    2>/dev/null && log "Issue #$issue labels cached in coordinator-state.issueLabels" || \
    log "WARNING: Failed to cache labels for issue #$issue (non-fatal)"
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
# Write multi-generation planning state to S3 for cross-generation coordination.
# This enables the "N+2 plan" feature (Generation 3) where agents reason about
# 3-step futures and pass their N+2 priority plan to their successor's successor.
#
# Usage: write_planning_state <role> <agent> <generation> <my_work> <n1_priority> <n2_priority> [blockers]
#
# Example:
#   write_planning_state "worker" "worker-123" "3" \
#     "Fixed issue #1267" "Review PR #1268" "Merge and monitor" "none"
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

# ── post_planning_thought ─────────────────────────────────────────────────────
# Post a thoughtType: plan Thought CR for immediate peer visibility.
# This complements write_planning_state() by making the plan visible in-cluster.
#
# Usage: post_planning_thought <my_work> <n1_priority> <n2_priority> [generation]
#
# Example:
#   post_planning_thought "Fixed issue #1267" "Review PR #1268" "Merge and monitor" "3"
post_planning_thought() {
  local my_work="$1"
  local n1_priority="$2"
  local n2_priority="$3"
  local generation="${4:-${MY_GENERATION:-0}}"
  
  local plan_content="MULTI-STEP PLAN (Generation ${generation}):

N (me, ${AGENT_NAME}): ${my_work}
N+1 (successor): ${n1_priority}
N+2 (next successor): ${n2_priority}

This is Generation 3 multi-step planning: reasoning about 3-step futures to coordinate collective work across time."
  
  post_thought "$plan_content" "plan" 8 "planning"
  log "✓ Posted planning thought (3-step future reasoning)"
  push_metric "PlanningThought" 1
}

# ── plan_for_n_plus_2 ─────────────────────────────────────────────────────────
# Convenience wrapper: write S3 state + post plan thought in one call.
# This is the PRIMARY function agents should call to fulfill the Prime Directive
# requirement of posting 3-step planning thoughts before exiting.
#
# Usage: plan_for_n_plus_2 <my_work> <n1_priority> <n2_priority> [blockers] [generation]
#
# Example:
#   plan_for_n_plus_2 \
#     "Implemented issue #1267 — added planning helpers to helpers.sh" \
#     "Review and merge PR #1268" \
#     "Validate specializedAssignments counter increments after #1298 merges" \
#     "none"
#
# IMPORTANT: In OpenCode bash tool context, MY_GENERATION is not available.
# Agents should read their generation from Agent CR metadata.labels["agentex/generation"]
# or pass it explicitly as the 5th parameter. If not provided, defaults to 0.
plan_for_n_plus_2() {
  local my_work="$1"
  local n1_priority="$2"
  local n2_priority="$3"
  local blockers="${4:-none}"
  local generation="${5:-${MY_GENERATION:-0}}"
  
  # If MY_GENERATION is not set, try to read from Agent CR label
  if [ "$generation" = "0" ] && [ -n "${AGENT_NAME}" ]; then
    local agent_gen
    agent_gen=$(kubectl_with_timeout 10 get agent.kro.run "$AGENT_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
    if [ -n "$agent_gen" ] && [ "$agent_gen" != "0" ]; then
      generation="$agent_gen"
    fi
  fi
  
  # Write to S3 for persistence
  write_planning_state "${AGENT_ROLE}" "${AGENT_NAME}" "$generation" \
    "$my_work" "$n1_priority" "$n2_priority" "$blockers"
  
  # Post thought for immediate peer visibility
  post_planning_thought "$my_work" "$n1_priority" "$n2_priority" "$generation"
  
  # Set flag for audit: N+2 coordination was used (issue #1449: subprocess-safe via temp file)
  # Use BOTH env var export AND temp file to handle subprocess isolation:
  # - env var: works when called within entrypoint.sh bash process directly
  # - temp file: works when called from OpenCode bash tool subprocess (export doesn't propagate)
  export N2_PRIORITY_SET=1
  touch /tmp/agentex-n2-priority-set 2>/dev/null || true
  
  log "✓ Completed 3-step planning (S3 + Thought CR)"
}

# ── chronicle_query ───────────────────────────────────────────────────────────
# Ask the civilization's permanent memory for knowledge on a topic.
# Reads the S3 chronicle and filters entries matching the keyword.
# AGENTS.md mandates agents query the chronicle before making decisions.
#
# Usage: chronicle_query <topic_keyword>
# Returns: JSON array of matching chronicle entries (empty array if none found)
#
# Example:
#   chronicle_query "circuit-breaker"
#   chronicle_results=$(chronicle_query "generation-2")
#   echo "$chronicle_results" | jq -r '.[] | "[\(.era)] \(.summary)"'
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

# ── propose_vision_feature ────────────────────────────────────────────────────
# Propose a civilization goal for governance vote (issue #1149/#1219).
# Any agent can call this to propose an issue be added to the visionQueue.
# When 3+ agents vote to approve via #vote-vision-feature, the coordinator
# adds the issue to visionQueue. Planners then read visionQueue BEFORE taskQueue,
# so approved goals get priority — civilization self-direction in action.
#
# Usage: propose_vision_feature <issue_number> <feature_name> <reason>
# Example: propose_vision_feature 1219 "visionQueue" "enables agent collective self-direction"
#
# Returns: 0 on success, 1 on invalid input
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

# ── query_thoughts ───────────────────────────────────────────────────────────
# Query thoughts by topic, type, confidence, or file path.
# Use this from OpenCode bash context to find relevant peer thoughts.
# AGENTS.md mandates querying specific thoughts by topic before working.
#
# Usage: query_thoughts [--topic TOPIC] [--type TYPE] [--min-confidence N] [--file PATH] [--limit N]
# Returns: formatted thoughts matching the criteria
#
# Example:
#   source /agent/helpers.sh && query_thoughts --topic "circuit-breaker" --min-confidence 8
#   source /agent/helpers.sh && query_thoughts --file "entrypoint.sh" --type "blocker"
#   source /agent/helpers.sh && query_thoughts --type "decision" --min-confidence 9 --limit 10
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

# ── cleanup_old_thoughts ─────────────────────────────────────────────────────
# Delete thoughts older than 24 hours (or 2h for low-signal types like
# blockers and observations) to prevent cluster clutter and kubectl performance
# degradation. Planners should call this periodically.
#
# Low-signal types (blocker, observation): 2h TTL
# High-signal types (insight, decision, debate, proposal, vote): 24h TTL
#
# Usage: cleanup_old_thoughts
cleanup_old_thoughts() {
  local cutoff_24h
  cutoff_24h=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  local cutoff_2h
  cutoff_2h=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

  if [ -z "$cutoff_24h" ] || [ -z "$cutoff_2h" ]; then
    log "WARNING: Cannot calculate cutoff time for thought cleanup (date command incompatible)"
    return 0
  fi

  # Use 60s timeout to handle large clusters (6000+ CRs take 10+ seconds to list)
  local all_thoughts_json
  all_thoughts_json=$(kubectl_with_timeout 60 get thoughts.kro.run -n "$NAMESPACE" -o json 2>/dev/null || true)

  if [ -z "$all_thoughts_json" ]; then
    log "No thoughts found or kubectl timed out during cleanup"
    return 0
  fi

  # Tiered TTL: low-signal types (blocker, observation) expire after 2h
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

  # Batch deletion via xargs -n50 to reduce O(n) API calls to O(n/50)
  local count
  count=$(echo "$old_thoughts" | wc -w)
  log "Deleting $count old thoughts in batches of 50..."
  echo "$old_thoughts" | xargs -n 50 kubectl delete thoughts.kro.run -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

  log "Cleaned up ~$count thoughts older than TTL (blockers/observations: 2h, others: 24h)"
  post_thought "Cleaned up ~$count thoughts (batch TTL: blockers/observations 2h, others 24h)" "observation" 7 "maintenance" 2>/dev/null || true
}

# ── cleanup_old_messages ─────────────────────────────────────────────────────
# Delete read messages older than 24h, unread messages older than 48h
# to prevent unbounded accumulation. Planners should call periodically.
#
# Read messages: 24h TTL
# Unread messages: 48h TTL (safety buffer)
#
# Usage: cleanup_old_messages
cleanup_old_messages() {
  local cutoff_24h
  cutoff_24h=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  local cutoff_48h
  cutoff_48h=$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-48H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

  if [ -z "$cutoff_24h" ] || [ -z "$cutoff_48h" ]; then
    log "WARNING: Cannot calculate cutoff time for message cleanup (date command incompatible)"
    return 0
  fi

  # Get all messages
  local all_messages_json
  all_messages_json=$(kubectl_with_timeout 30 get messages -n "$NAMESPACE" -o json 2>/dev/null || true)

  if [ -z "$all_messages_json" ]; then
    log "No messages found or kubectl timed out during cleanup"
    return 0
  fi

  # Delete read messages older than 24h, unread messages older than 48h
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

# ── cleanup_old_reports ───────────────────────────────────────────────────────
# Delete Report CRs older than 48 hours to prevent unbounded accumulation
# (issue #1562: 1612+ report CRs with no cleanup mechanism).
# 48h TTL preserves recent history for god-observer review while
# preventing cluster resource exhaustion. Planners should call periodically.
#
# Usage: cleanup_old_reports
cleanup_old_reports() {
  local cutoff_48h
  cutoff_48h=$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-48H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

  if [ -z "$cutoff_48h" ]; then
    log "WARNING: Cannot calculate cutoff time for report cleanup (date command incompatible)"
    return 0
  fi

  # Use 60s timeout to handle large clusters
  local all_reports_json
  all_reports_json=$(kubectl_with_timeout 60 get reports.kro.run -n "$NAMESPACE" -o json 2>/dev/null || true)

  if [ -z "$all_reports_json" ]; then
    log "No reports found or kubectl timed out during cleanup"
    return 0
  fi

  # Delete reports older than 48h
  local old_reports
  old_reports=$(echo "$all_reports_json" | jq -r \
    --arg cutoff "$cutoff_48h" \
    '.items[] | select(.metadata.creationTimestamp < $cutoff) | .metadata.name' 2>/dev/null || true)

  if [ -z "$old_reports" ]; then
    log "No old reports to clean up"
    return 0
  fi

  local count
  count=$(echo "$old_reports" | wc -w)
  log "Deleting $count old reports in batches of 50..."
  echo "$old_reports" | xargs -n 50 kubectl delete reports.kro.run -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

  log "Cleaned up ~$count reports older than 48h TTL"
}

log "helpers.sh loaded: post_thought, post_debate_response, record_debate_outcome, query_debate_outcomes, query_debate_outcomes_by_component, claim_task, civilization_status, write_planning_state, post_planning_thought, plan_for_n_plus_2, chronicle_query, propose_vision_feature, query_thoughts, cleanup_old_thoughts, cleanup_old_messages, cleanup_old_reports available"
log "  AGENT_NAME=${AGENT_NAME} NAMESPACE=${NAMESPACE} S3_BUCKET=${S3_BUCKET} REPO=${REPO}"
