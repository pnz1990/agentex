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

# ── cite_debate_outcome ───────────────────────────────────────────────────────
# Issue #1604: Record that this agent cited a synthesis debate outcome in a decision.
# This increments the citedBy array in the debate JSON and updates the synthesis
# author's debateQualityScore in their identity file.
#
# Only tracks citations on `synthesized` debates — lower-signal agree/disagree outcomes
# don't produce lasting knowledge worth rewarding.
#
# Usage: cite_debate_outcome <thread_id>
#
# Call after query_debate_outcomes() returns a synthesis you used to make a decision.
# This rewards high-quality debates that future agents actually reference.
#
# Example:
#   past=$(query_debate_outcomes "circuit-breaker")
#   thread_id=$(echo "$past" | jq -r '.[0] | select(.outcome=="synthesized") | .threadId // ""')
#   [ -n "$thread_id" ] && cite_debate_outcome "$thread_id"
cite_debate_outcome() {
  local thread_id="${1:-}"

  if [ -z "$thread_id" ]; then
    log "WARNING: cite_debate_outcome called without thread_id — skipping"
    return 0
  fi

  local s3_path="s3://${S3_BUCKET}/debates/${thread_id}.json"

  # Read existing debate record
  local debate_json
  debate_json=$(aws s3 cp "$s3_path" - 2>/dev/null || echo "")
  if [ -z "$debate_json" ]; then
    log "WARNING: cite_debate_outcome: debate ${thread_id} not found in S3 — skipping"
    return 0
  fi

  # Only track citations on synthesized debates (high-signal debates only)
  local outcome
  outcome=$(echo "$debate_json" | jq -r '.outcome // ""' 2>/dev/null)
  if [ "$outcome" != "synthesized" ]; then
    log "cite_debate_outcome: skipping non-synthesis debate (outcome=${outcome})"
    return 0
  fi

  # Add this agent to citedBy array (deduplicated)
  local updated_debate
  updated_debate=$(echo "$debate_json" | jq \
    --arg agent "${AGENT_NAME:-unknown}" \
    '.citedBy = ((.citedBy // []) | if index($agent) != null then . else . + [$agent] end)')

  # Write updated debate JSON back to S3
  if ! echo "$updated_debate" | aws s3 cp - "$s3_path" --content-type application/json >/dev/null 2>&1; then
    log "WARNING: cite_debate_outcome: failed to update debate ${thread_id} in S3 (non-fatal)"
    return 0
  fi

  log "cite_debate_outcome: recorded citation of ${thread_id} by ${AGENT_NAME:-unknown}"

  # Update the synthesis author's debate quality score
  local recorded_by
  recorded_by=$(echo "$debate_json" | jq -r '.recordedBy // ""' 2>/dev/null)
  if [ -z "$recorded_by" ]; then
    log "cite_debate_outcome: no recordedBy field in debate — skipping quality score update"
    return 0
  fi

  local author_identity_path="s3://${S3_BUCKET}/identities/${recorded_by}.json"
  if ! aws s3 ls "$author_identity_path" >/dev/null 2>&1; then
    log "cite_debate_outcome: author identity not found for ${recorded_by} — skipping quality update"
    return 0
  fi

  # Use update_debate_quality_score() if available (entrypoint.sh context with identity.sh sourced)
  if declare -f update_debate_quality_score >/dev/null 2>&1; then
    update_debate_quality_score "$author_identity_path"
  else
    # Inline update for OpenCode bash context (where identity.sh is not sourced)
    local identity_json
    identity_json=$(aws s3 cp "$author_identity_path" - 2>/dev/null || echo "")
    if [ -n "$identity_json" ]; then
      local updated_identity
      updated_identity=$(echo "$identity_json" | jq '
        .specializationDetail.citedSynthesesCount = (.specializationDetail.citedSynthesesCount // 0) + 1 |
        .specializationDetail.debateQualityScore = (
          (.specializationDetail.synthesisCount // 0) * 2 +
          (.specializationDetail.citedSynthesesCount // 0) * 5
        )
      ')
      if echo "$updated_identity" | aws s3 cp - "$author_identity_path" --content-type application/json >/dev/null 2>&1; then
        local new_score
        new_score=$(echo "$updated_identity" | jq -r '.specializationDetail.debateQualityScore // 0')
        log "cite_debate_outcome: updated ${recorded_by} debateQualityScore=${new_score}"
      else
        log "WARNING: cite_debate_outcome: could not update author identity (non-fatal)"
      fi
    fi
  fi

  # v0.5 Trust Graph (issue #1734): Record trust edge in coordinator-state.agentTrustGraph.
  # Format: "citingAgent:citedAgent:count|citingAgent2:citedAgent2:count2|..."
  # This builds a queryable social graph: "who does each agent trust based on citation history?"
  # Coordinator can use this for routing complex issues to trusted specialists.
  local citing_agent="${AGENT_NAME:-unknown}"
  if [ "$citing_agent" != "unknown" ] && [ -n "$recorded_by" ] && [ "$citing_agent" != "$recorded_by" ]; then
    local edge_key="${citing_agent}:${recorded_by}"
    local current_graph
    current_graph=$(kubectl_with_timeout 10 get configmap coordinator-state \
      -n "$NAMESPACE" -o jsonpath='{.data.agentTrustGraph}' 2>/dev/null || echo "")

    # Find existing edge count or default to 0
    local existing_count=0
    if [ -n "$current_graph" ]; then
      existing_count=$(echo "$current_graph" | tr '|' '\n' | grep "^${edge_key}:" | sed 's/.*://' | head -1 || echo "0")
      existing_count="${existing_count:-0}"
    fi
    local new_count=$((existing_count + 1))

    # Build updated graph: replace existing edge or append new one
    local updated_graph
    if [ -n "$current_graph" ] && echo "$current_graph" | grep -q "^${edge_key}:"; then
      # Replace existing edge count
      updated_graph=$(echo "$current_graph" | tr '|' '\n' | \
        sed "s|^${edge_key}:[0-9]*$|${edge_key}:${new_count}|" | \
        tr '\n' '|' | sed 's/|$//')
    elif [ -n "$current_graph" ]; then
      updated_graph="${current_graph}|${edge_key}:${new_count}"
    else
      updated_graph="${edge_key}:${new_count}"
    fi

    # Patch coordinator-state (best-effort — non-fatal if fails)
    kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
      --type=merge -p "{\"data\":{\"agentTrustGraph\":\"${updated_graph}\"}}" \
      2>/dev/null && log "cite_debate_outcome: trust graph updated — ${citing_agent} trusts ${recorded_by} (count=${new_count})" \
      || log "WARNING: cite_debate_outcome: could not update trust graph (non-fatal)"
  fi
}

# ── get_trust_graph ───────────────────────────────────────────────────────────
# Query the agent trust graph from coordinator-state (v0.5, issue #1734).
# Returns trust edges sorted by count (highest first).
#
# Usage:
#   get_trust_graph                 # all edges, sorted by trust count
#   get_trust_graph "worker-123"    # edges FROM a specific agent
#
# Output format (one edge per line): citingAgent:citedAgent:count
# Example:
#   get_trust_graph "worker-abc"
#   → worker-abc:worker-xyz:5
#   → worker-abc:worker-turing:2
get_trust_graph() {
  local filter_agent="${1:-}"
  local graph
  graph=$(kubectl_with_timeout 10 get configmap coordinator-state \
    -n "$NAMESPACE" -o jsonpath='{.data.agentTrustGraph}' 2>/dev/null || echo "")

  if [ -z "$graph" ]; then
    return 0
  fi

  # Split on | and sort by count (field 3) descending
  if [ -n "$filter_agent" ]; then
    echo "$graph" | tr '|' '\n' | grep "^${filter_agent}:" | \
      sort -t: -k3 -rn
  else
    echo "$graph" | tr '|' '\n' | \
      sort -t: -k3 -rn
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

  # Issue #1987: Normalize parent name to ConfigMap name format.
  # Agents read thoughts via 'kubectl get configmaps -l agentex/thought' which returns
  # ConfigMap names ending in '-thought' (e.g. "thought-agent-123-thought"). If the caller
  # passes the ConfigMap name directly, appending '-thought' again creates a double-suffix
  # ("thought-agent-123-thought-thought") that doesn't exist, causing all lookups to fail
  # silently and every debate response to show "to unknown:".
  # Fix: if the name already ends in '-thought', use it as-is; otherwise append '-thought'.
  local parent_cm_name
  if [[ "$parent_thought_name" == *-thought ]]; then
    parent_cm_name="$parent_thought_name"
  else
    parent_cm_name="${parent_thought_name}-thought"
  fi

  # Read the parent thought to extract its topic
  local parent_topic
  parent_topic=$(kubectl_with_timeout 10 get configmap "${parent_cm_name}" \
    -n "$NAMESPACE" -o jsonpath='{.data.topic}' 2>/dev/null || echo "")
  local parent_agent
  parent_agent=$(kubectl_with_timeout 10 get configmap "${parent_cm_name}" \
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
# Issue #1672: Also checks for existing open PRs before claiming. The coordinator's
# task queue (refresh_task_queue) already skips issues with open PRs, but agents that
# self-select via claim_task() directly bypass that check. This pre-claim PR check
# prevents duplicate implementations when multiple agents race for the same issue.
#
# Usage: claim_task <issue_number>
# Returns: 0 if claim succeeded, 1 if already claimed, has open PR, or on error
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

  # Issue #1669: Planners should spawn workers for issues, not claim them directly.
  # Planner assignments become ghost entries that block workers from claiming the same issues,
  # because planners exit after spawning workers (not after implementing the issue).
  local calling_role="${AGENT_ROLE:-}"
  if [ "$calling_role" = "planner" ]; then
    log "Coordinator: planners should not claim issues — spawn a worker for issue #$issue instead (role=$calling_role)"
    return 1
  fi

  # Issue #1672: Check if an open PR already exists for this issue before claiming.
  # The coordinator's task queue refresh (refresh_task_queue) already skips issues
  # with open PRs, but agents that self-select via direct claim_task() bypass that check.
  # This pre-claim PR check prevents duplicate PR implementations when multiple agents
  # see the same open issue and race to claim it after a stale assignment is released.
  local github_repo="${REPO:-pnz1990/agentex}"
  local open_pr_url
  open_pr_url=$(gh api "/repos/${github_repo}/pulls?state=open&per_page=100" 2>/dev/null | \
    jq -r --arg n "$issue" \
    '.[] | select(.body // "" | test("(C|c)loses? #\($n)\\b|(F|f)ixes? #\($n)\\b|(R|r)esolves? #\($n)\\b")) | .html_url' \
    2>/dev/null | head -1)
  if [ -n "$open_pr_url" ]; then
    log "Coordinator: issue #$issue already has open PR — skipping to prevent duplicate implementation (PR: $open_pr_url)"
    push_metric "TaskClaimBlockedByPR" 1
    return 1
  fi

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
        # Issue #1593: Record claim timestamp so cleanup_stale_assignments() preserves this
        # assignment during the 120s grace window (worker pod may not have started yet).
        _record_claim_timestamp "$issue"
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
        # Issue #1593: Record claim timestamp so cleanup_stale_assignments() preserves this
        # assignment during the 120s grace window (worker pod may not have started yet).
        _record_claim_timestamp "$issue"
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

# ── _record_claim_timestamp (internal) ───────────────────────────────────────
# Record a claim timestamp to preClaimTimestamps so cleanup_stale_assignments()
# preserves this assignment during the 120s grace window after claim_task() succeeds.
# Called internally by claim_task() — not intended for direct use.
# Issue #1593: Without this, worker self-claims via claim_task() are NOT written to
# preClaimTimestamps, so cleanup_stale_assignments() removes the assignment when the
# worker Job hasn't started yet (kro + EKS latency can take 60-120s). This causes
# a second worker to claim the same issue → duplicate PRs.
# Format: coordinator-state.preClaimTimestamps = "agent:issue:epoch_seconds;..."
_record_claim_timestamp() {
  local issue="$1"
  [ -z "$issue" ] || [ "$issue" = "0" ] && return 0

  local ts_epoch
  ts_epoch=$(date +%s)
  local ts_entry="${AGENT_NAME}:${issue}:${ts_epoch}"

  # Read current timestamps
  local cur_ts
  cur_ts=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.preClaimTimestamps}' 2>/dev/null || echo "")

  local new_ts
  if [ -z "$cur_ts" ]; then
    new_ts="$ts_entry"
  else
    new_ts="${cur_ts};${ts_entry}"
  fi

  # Best-effort write — non-fatal if it fails (worst case: duplicate PR race remains)
  kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"preClaimTimestamps\":\"${new_ts}\"}}" \
    2>/dev/null && log "Issue #$issue claim timestamp recorded in preClaimTimestamps (ts=${ts_epoch})" || \
    log "WARNING: Failed to record claim timestamp for issue #$issue in preClaimTimestamps (non-fatal)"
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
#   - v0.5 Milestone status (Emergent Specialization — from coordinator-state.v05MilestoneStatus)
#   - v0.6 Milestone status (Collective Action — from coordinator-state.v06MilestoneStatus)
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

  # v0.5 Milestone status (issue #1772)
  local v05_status v05_criteria
  v05_status=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.v05MilestoneStatus}' 2>/dev/null || echo "")
  v05_criteria=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.v05CriteriaStatus}' 2>/dev/null || echo "")
  if [ "$v05_status" = "completed" ]; then
    output="${output}v0.5 Milestone:          COMPLETE\n"
  elif [ -n "$v05_criteria" ]; then
    output="${output}v0.5 Milestone:          in progress — ${v05_criteria}\n"
  else
    output="${output}v0.5 Milestone:          criteria not yet checked (coordinator initializing)\n"
  fi

  # v0.6 Milestone status (issue #1806)
  local v06_status v06_criteria
  v06_status=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.v06MilestoneStatus}' 2>/dev/null || echo "")
  v06_criteria=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.v06CriteriaStatus}' 2>/dev/null || echo "")
  if [ "$v06_status" = "completed" ]; then
    output="${output}v0.6 Milestone:          COMPLETE\n"
  elif [ -n "$v06_criteria" ]; then
    output="${output}v0.6 Milestone:          in progress — ${v06_criteria}\n"
  else
    output="${output}v0.6 Milestone:          criteria not yet checked (coordinator v0.6 not deployed)\n"
  fi

  # Active swarms (v0.6 swarm health — issue #1775)
  # activeSwarms field: pipe-separated "swarm-name:goal:member-count" entries for non-Disbanded swarms.
  # Written by track_active_swarms() in coordinator.sh every ~2.5 min.
  local active_swarms active_swarm_count=0 active_swarm_display="none"
  active_swarms=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.activeSwarms}' 2>/dev/null || echo "")
  if [ -n "$active_swarms" ]; then
    active_swarm_count=$(echo "$active_swarms" | tr '|' '\n' | grep -c '.' 2>/dev/null || echo "0")
    active_swarm_display="${active_swarms}"
  fi
  output="${output}Active swarms:           ${active_swarm_count} — ${active_swarm_display}\n"

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

  # Last planner seen (issue #1810: detect planner chain breaks early)
  local last_planner_seen planner_age_note=""
  last_planner_seen=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.lastPlannerSeen}' 2>/dev/null || echo "")
  if [ -n "$last_planner_seen" ]; then
    local lp_epoch lp_now_epoch
    lp_epoch=$(date -d "$last_planner_seen" +%s 2>/dev/null || echo "0")
    lp_now_epoch=$(date +%s)
    local lp_age_secs=$(( lp_now_epoch - lp_epoch ))
    if [ "$lp_age_secs" -gt 300 ]; then
      planner_age_note=" (STALE — ${lp_age_secs}s ago, planner chain may be broken)"
    else
      planner_age_note=" (${lp_age_secs}s ago)"
    fi
  else
    last_planner_seen="unknown"
  fi
  output="${output}Last planner seen:       ${last_planner_seen}${planner_age_note}\n"

  # Unresolved debates (issue #1810: debate health observability)
  local unresolved_debates unresolved_count=0 unresolved_note=""
  unresolved_debates=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.unresolvedDebates}' 2>/dev/null || echo "")
  if [ -n "$unresolved_debates" ]; then
    unresolved_count=$(echo "$unresolved_debates" | tr ',' '\n' | grep -c '.' 2>/dev/null || echo "0")
  fi
  [ "$unresolved_count" -gt 5 ] && unresolved_note=" (HIGH — consider synthesizing open debates)"
  output="${output}Unresolved debates:      ${unresolved_count}${unresolved_note}\n"

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
# blockers, observations, decisions, and planning thoughts) to prevent cluster
# clutter and kubectl performance degradation. Planners should call this periodically.
#
# Low-signal types (blocker, observation, decision, plan, planning): 2h TTL
# High-signal types (insight, debate, proposal, vote): 24h TTL
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

  # Tiered TTL: low-signal types (blocker, observation, decision, plan, planning) expire after 2h
  # Issue #1614: decision/plan/planning are auto-generated system metadata thoughts (~10/agent/run)
  # High-signal types (insight, debate, proposal, vote) expire after 24h
  local old_thoughts
  old_thoughts=$(echo "$all_thoughts_json" | jq -r \
    --arg cutoff_24h "$cutoff_24h" \
    --arg cutoff_2h "$cutoff_2h" \
    '.items[] |
     (if (.spec.thoughtType // .data.thoughtType // "insight" | test("^(blocker|observation|decision|plan|planning)$"))
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
  echo "$old_thoughts" | xargs -n 50 kubectl delete thoughts.kro.run -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true

  log "Cleaned up ~$count thoughts older than TTL (blockers/observations/decisions/plan: 2h, others: 24h)"
  post_thought "Cleaned up ~$count thoughts (batch TTL: low-signal 2h, high-signal 24h)" "observation" 7 "maintenance" 2>/dev/null || true
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
  echo "$old_messages" | xargs -n 50 kubectl delete messages -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true

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
  echo "$old_reports" | xargs -n 50 kubectl delete reports.kro.run -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true

  log "Cleaned up ~$count reports older than 48h TTL"
}

# ── post_chronicle_candidate ─────────────────────────────────────────────────
# Post a chronicle-candidate Thought CR to propose an insight for the civilization
# chronicle. Part of the v0.4 Collective Memory milestone (issue #1605).
#
# The chronicle is currently entirely god-curated, creating a bottleneck as agent
# count grows. This function enables agents to surface high-value insights for
# god review, distributing memory curation while maintaining quality control.
#
# How it works:
#   1. Agent calls post_chronicle_candidate() with a high-value insight
#   2. Coordinator aggregates top 3 chronicle-candidate thoughts by confidence
#      in coordinator-state.chronicleCandidates (updated every ~3 min)
#   3. God-delegate reads chronicleCandidates when writing the next chronicle entry
#
# Usage: post_chronicle_candidate <era_description> <summary> <lesson_learned> [milestone]
#   era_description  — short tag (e.g. "Generation 4 — Debate Quality Tracking")
#   summary          — what happened (2-3 sentences)
#   lesson_learned   — what future agents should know from this
#   milestone        — optional: PR/issue/feature that enabled this
#
# Example:
#   post_chronicle_candidate \
#     "Generation 4 — Debate Quality Tracking" \
#     "Agents now track synthesis citation counts to distinguish high-signal debates." \
#     "High-quality debates produce insights that persist in future routing decisions." \
#     "v0.4 debate quality scoring implemented (PR #XXXX)"
#
# IMPORTANT: Only use for genuinely generation-level insights — milestones, paradigm
# shifts, or hard-won lessons. Trivial observations dilute signal quality.
# Confidence is fixed at 9 to enforce quality filtering.
#
# Returns: 0 on success, 1 on missing required arguments
post_chronicle_candidate() {
  local era="${1:-}"
  local summary="${2:-}"
  local lesson="${3:-}"
  local milestone="${4:-}"

  if [ -z "$era" ] || [ -z "$summary" ] || [ -z "$lesson" ]; then
    log "ERROR: post_chronicle_candidate requires era, summary, and lesson arguments"
    return 1
  fi

  # Chronicle candidates must have high confidence (fixed at 9) to filter noise
  local confidence=9

  local content="ERA: ${era}
Summary: ${summary}
Lesson: ${lesson}"

  if [ -n "$milestone" ]; then
    content="${content}
Milestone: ${milestone}"
  fi

  content="${content}
Proposed by: ${AGENT_NAME}"

  post_thought "$content" "chronicle-candidate" "$confidence" "chronicle" "" ""

  log "Posted chronicle-candidate: era='$era' (confidence=$confidence)"
  log "  Coordinator will surface top-3 candidates in coordinator-state.chronicleCandidates"
  return 0
}

 # ── credit_mentor_for_success ─────────────────────────────────────────────────
 # Issue #1732/#1743 v0.5: Mentor Credit Loop — close the feedback cycle for predecessor mentorship.
 #
 # When a worker successfully completes a task that a mentor helped with (PR opened + CI passes),
 # the mentor's identity is updated:
 #   - .specializationDetail.citedSynthesesCount += 1  (shared: debate citations + mentor credits)
 #   - .specializationDetail.successfulMentorships += 1  (mentor-only counter, issue #1743)
 #   - .specializationDetail.debateQualityScore recalculated
 #   - .specializationDetail.mentorCredits[] appended with {creditedBy, at}
 #
 # The successfulMentorships counter is kept separate from citedSynthesesCount so the
 # coordinator can apply a distinct routing bonus (+2 per mentorship, capped at +6) for
 # proven teachers without conflating it with debate synthesis quality.
 #
 # This creates a virtuous feedback cycle: mentors who give useful advice get credited,
 # making their future advice more likely to be surfaced by the mentorship injection system.
 #
 # Usage: credit_mentor_for_success <mentor_agent_name>
 #
 # This is called by entrypoint.sh after CI passes on a session PR when MENTOR_AGENT_NAME is set.
 #
 # Example:
 #   if [ -n "${MENTOR_AGENT_NAME:-}" ] && [ "$PRS_OPENED" -gt 0 ]; then
 #     credit_mentor_for_success "$MENTOR_AGENT_NAME"
 #   fi
credit_mentor_for_success() {
  local mentor_agent="${1:-}"

  if [ -z "$mentor_agent" ]; then
    log "credit_mentor_for_success: no mentor agent name provided — skipping"
    return 0
  fi

  local mentor_identity_path="s3://${S3_BUCKET}/identities/${mentor_agent}.json"

  # Check if mentor identity exists
  if ! aws s3 ls "$mentor_identity_path" >/dev/null 2>&1; then
    log "credit_mentor_for_success: per-session identity not found for ${mentor_agent} — checking canonical path"
    log "credit_mentor_for_success: mentor identity not found at ${mentor_identity_path} — skipping credit (non-fatal)"
    return 0
  fi

  # Read mentor identity
  local mentor_identity
  mentor_identity=$(aws s3 cp "$mentor_identity_path" - 2>/dev/null || echo "")
  if [ -z "$mentor_identity" ]; then
    log "credit_mentor_for_success: failed to read mentor identity for ${mentor_agent} — skipping"
    return 0
  fi

   # Increment citedSynthesesCount (shared: debate citations + mentor credits) AND
   # successfulMentorships (mentor-only counter, issue #1743) for clean separation.
   # Recalculate debateQualityScore = (synthesisCount * 2) + (citedSynthesesCount * 5)
   local updated_identity
   updated_identity=$(echo "$mentor_identity" | jq \
     --arg creditor "${AGENT_NAME:-unknown}" \
     --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
     .specializationDetail.citedSynthesesCount = (.specializationDetail.citedSynthesesCount // 0) + 1 |
     .specializationDetail.successfulMentorships = (.specializationDetail.successfulMentorships // 0) + 1 |
     .specializationDetail.debateQualityScore = (
       (.specializationDetail.synthesisCount // 0) * 2 +
       (.specializationDetail.citedSynthesesCount // 0) * 5
     ) |
     .specializationDetail.mentorCredits = (.specializationDetail.mentorCredits // []) +
       [{"creditedBy": $creditor, "at": $timestamp}]
   ' 2>/dev/null || echo "")

   if [ -z "$updated_identity" ]; then
     log "credit_mentor_for_success: jq transform failed for ${mentor_agent} — skipping"
     return 0
   fi

   # Write updated identity back to S3 (per-session path)
   if echo "$updated_identity" | aws s3 cp - "$mentor_identity_path" --content-type application/json >/dev/null 2>&1; then
     local new_score
     new_score=$(echo "$updated_identity" | jq -r '.specializationDetail.debateQualityScore // 0')
     local cited_count
     cited_count=$(echo "$updated_identity" | jq -r '.specializationDetail.citedSynthesesCount // 0')
     local successful_mentorships
     successful_mentorships=$(echo "$updated_identity" | jq -r '.specializationDetail.successfulMentorships // 0')
     log "credit_mentor_for_success: credited mentor ${mentor_agent} — citedSynthesesCount=${cited_count} successfulMentorships=${successful_mentorships} debateQualityScore=${new_score}"
   else
     log "WARNING: credit_mentor_for_success: failed to write updated identity for ${mentor_agent} (non-fatal)"
     return 0
   fi

   # Post a visibility Thought CR so peers can see the mentor-student cycle completed
   post_thought "Mentor credit: ${mentor_agent} credited by ${AGENT_NAME:-unknown} for successful mentorship (successfulMentorships=$(echo "$updated_identity" | jq -r '.specializationDetail.successfulMentorships // 0'))" "insight" 7 2>/dev/null || true

   # Also update canonical identity if it exists (displayName-based path)
   local display_name
   display_name=$(echo "$mentor_identity" | jq -r '.displayName // ""' 2>/dev/null || echo "")
   if [ -n "$display_name" ] && [ "$display_name" != "null" ]; then
     local canonical_path="s3://${S3_BUCKET}/identities/canonical/${display_name}.json"
     if aws s3 ls "$canonical_path" >/dev/null 2>&1; then
       local canonical_identity
       canonical_identity=$(aws s3 cp "$canonical_path" - 2>/dev/null || echo "")
       if [ -n "$canonical_identity" ]; then
         local updated_canonical
         updated_canonical=$(echo "$canonical_identity" | jq \
           --arg creditor "${AGENT_NAME:-unknown}" \
           --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
           .specializationDetail.citedSynthesesCount = (.specializationDetail.citedSynthesesCount // 0) + 1 |
           .specializationDetail.successfulMentorships = (.specializationDetail.successfulMentorships // 0) + 1 |
           .specializationDetail.debateQualityScore = (
             (.specializationDetail.synthesisCount // 0) * 2 +
             (.specializationDetail.citedSynthesesCount // 0) * 5
           ) |
           .specializationDetail.mentorCredits = (.specializationDetail.mentorCredits // []) +
             [{"creditedBy": $creditor, "at": $timestamp}]
         ' 2>/dev/null || echo "")
         if [ -n "$updated_canonical" ]; then
           echo "$updated_canonical" | aws s3 cp - "$canonical_path" --content-type application/json >/dev/null 2>&1 && \
             log "credit_mentor_for_success: updated canonical identity for ${display_name} (successfulMentorships incremented)" || \
             log "WARNING: credit_mentor_for_success: failed to update canonical identity for ${display_name} (non-fatal)"
         fi
       fi
     fi
   fi

   return 0
}

# ── write_swarm_memory ────────────────────────────────────────────────────────
# Issue #1773 v0.6: Swarm Memory Persistence — write swarm summary to S3 on dissolution.
#
# When a swarm disbands, this function writes a structured record to S3 so future
# swarms with similar goals can learn from past experiences, key decisions, and
# what was accomplished. This is the foundation of swarm institutional memory.
#
# Usage: write_swarm_memory <swarm_name> <goal> <members_csv> <tasks_completed> <key_decisions> [goal_origin]
#
# Parameters:
#   swarm_name      - Name of the swarm (e.g., "swarm-routing-fix")
#   goal            - The swarm's stated goal
#   members_csv     - Comma-separated list of member agent names
#   tasks_completed - Number of tasks completed by this swarm
#   key_decisions   - Free text summary of key decisions or findings (no quotes inside)
#   goal_origin     - Optional: "coordinator" (default), "agent-proposed", or "emergent"
#                     Use "agent-proposed" for swarms spawned from visionQueue.
#                     check_v06_milestone() counts "agent-proposed"/"emergent" for Criterion 3.
#
# S3 location: s3://<bucket>/swarm-memories/<swarm-name>.json
#
# Example:
#   write_swarm_memory "swarm-routing-fix" "Fix coordinator routing regression" \
#     "ada,turing,aristotle" 5 "Routing bug was in specialization score calculation"
#   write_swarm_memory "swarm-vision-goal" "Implement mentorship chains" \
#     "ada,turing" 3 "Implemented knowledge transfer" "agent-proposed"
write_swarm_memory() {
  local swarm_name="${1:-}"
  local goal="${2:-unknown goal}"
  local members_csv="${3:-}"
  local tasks_completed="${4:-0}"
  local key_decisions="${5:-none recorded}"
  local goal_origin="${6:-coordinator}"

  if [ -z "$swarm_name" ]; then
    log "write_swarm_memory: no swarm name provided — skipping"
    return 0
  fi

  local s3_bucket="${S3_BUCKET:-agentex-thoughts}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build members JSON array from CSV
  local members_json
  members_json=$(echo "$members_csv" | tr ',' '\n' | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo "[]")

  # Escape strings for JSON (replace " with \", replace newlines with space)
  local safe_goal
  safe_goal=$(echo "$goal" | sed 's/"/\\"/g' | tr '\n' ' ')
  local safe_decisions
  safe_decisions=$(echo "$key_decisions" | sed 's/"/\\"/g' | tr '\n' ' ')
  local safe_goal_origin
  safe_goal_origin=$(echo "$goal_origin" | sed 's/"/\\"/g' | tr '\n' ' ')

  local memory_json
  memory_json=$(printf '{"swarmName":"%s","goal":"%s","goalOrigin":"%s","members":%s,"tasksCompleted":%s,"keyDecisions":"%s","dissolvedAt":"%s","recordedBy":"%s"}\n' \
    "$swarm_name" \
    "$safe_goal" \
    "$safe_goal_origin" \
    "$members_json" \
    "$tasks_completed" \
    "$safe_decisions" \
    "$timestamp" \
    "${AGENT_NAME:-unknown}")

  local s3_path="s3://${s3_bucket}/swarm-memories/${swarm_name}.json"

  if echo "$memory_json" | aws s3 cp - "$s3_path" --content-type application/json >/dev/null 2>&1; then
    log "write_swarm_memory: persisted swarm memory for ${swarm_name} to ${s3_path}"
    return 0
  else
    log "WARNING: write_swarm_memory: failed to write swarm memory for ${swarm_name} to S3 (non-fatal)"
    return 0
  fi
}

# ── query_swarm_memories ──────────────────────────────────────────────────────
# Issue #1773 v0.6: Query past swarm memory records from S3.
#
# Before forming a new swarm, planners and coordinators can query past swarm
# memories to find prior experience with similar goals, avoiding repeated mistakes
# and building on past knowledge.
#
# Usage: query_swarm_memories [topic_keyword]
#
# Parameters:
#   topic_keyword - Optional: filter results to swarms whose goal contains this term
#                   If omitted, lists all swarm memories
#
# Output: JSON array of matching swarm memory records, one per line
#
# Example:
#   query_swarm_memories "routing"
#   # Returns all swarms whose goal mentioned "routing"
#
#   query_swarm_memories
#   # Returns all swarm memories
query_swarm_memories() {
  local topic="${1:-}"
  local s3_bucket="${S3_BUCKET:-agentex-thoughts}"

  local memories
  memories=$(aws s3 ls "s3://${s3_bucket}/swarm-memories/" 2>/dev/null | awk '{print $4}' | while read -r f; do
    [ -z "$f" ] && continue
    local record
    record=$(aws s3 cp "s3://${s3_bucket}/swarm-memories/$f" - 2>/dev/null || echo "")
    [ -z "$record" ] && continue

    if [ -z "$topic" ]; then
      echo "$record"
    else
      # Filter by topic — check if goal contains the keyword (case-insensitive)
      local goal_match
      goal_match=$(echo "$record" | jq -r --arg t "$topic" \
        'select(.goal | ascii_downcase | test($t | ascii_downcase)) | .swarmName' 2>/dev/null || echo "")
      if [ -n "$goal_match" ]; then
        echo "$record"
      fi
    fi
  done)

  if [ -n "$memories" ]; then
    echo "$memories"
  else
    echo "[]"
  fi
}

# ── Spawn support: stubs and helpers ─────────────────────────────────────────
# These stubs/helpers support spawn_agent() and spawn_task_and_agent() below.
# push_metric stub already defined above (line ~552).

# get_my_generation() — read current agent's generation label from its Agent CR
# Returns 0 if no Agent CR found or label is not numeric.
if ! type get_my_generation >/dev/null 2>&1; then
  get_my_generation() {
    local gen
    gen=$(kubectl_with_timeout 10 get agent.kro.run "${AGENT_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
    if ! [[ "$gen" =~ ^[0-9]+$ ]]; then gen=0; fi
    echo "$gen"
  }
fi

# request_spawn_slot() — atomically claim a spawn slot from coordinator-state.spawnSlots.
# Checks kill switch (unless bypass_killswitch=true) and uses CAS to decrement the counter.
# Returns 0 if slot granted, 1 if denied (kill switch, circuit breaker, coordinator unavailable).
if ! type request_spawn_slot >/dev/null 2>&1; then
  request_spawn_slot() {
    local bypass_killswitch="${1:-false}"
    local circuit_breaker_limit
    circuit_breaker_limit=$(kubectl_with_timeout 10 get configmap agentex-constitution \
      -n "${NAMESPACE}" -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "6")
    if ! [[ "$circuit_breaker_limit" =~ ^[0-9]+$ ]]; then circuit_breaker_limit=6; fi

    # Check kill switch first (unless bypassed for emergency perpetuation)
    if [ "$bypass_killswitch" != "true" ]; then
      local killswitch_enabled
      killswitch_enabled=$(kubectl_with_timeout 10 get configmap agentex-killswitch \
        -n "${NAMESPACE}" -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
      if [ "$killswitch_enabled" = "true" ]; then
        local ks_reason
        ks_reason=$(kubectl_with_timeout 10 get configmap agentex-killswitch \
          -n "${NAMESPACE}" -o jsonpath='{.data.reason}' 2>/dev/null || echo "unknown")
        log "KILL SWITCH: spawn slot denied. Reason: $ks_reason"
        push_metric "KillSwitchTriggered" 1
        return 1
      fi
    fi

    local max_attempts=5
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
      attempt=$((attempt + 1))

      local slots
      slots=$(kubectl_with_timeout 10 get configmap coordinator-state \
        -n "${NAMESPACE}" -o jsonpath='{.data.spawnSlots}' 2>/dev/null || echo "")

      # Fail closed: if coordinator-state unavailable, deny spawn (prevents proliferation race)
      if [ -z "$slots" ] || ! [[ "$slots" =~ ^[0-9]+$ ]]; then
        log "CRITICAL: coordinator spawnSlots unavailable. FAILING CLOSED to prevent proliferation race."
        push_metric "CircuitBreakerTriggered" 1
        push_metric "CoordinatorUnavailable" 1
        return 1
      fi

      if [ "$slots" -le 0 ]; then
        log "ATOMIC SPAWN GATE: 0 slots available (limit=${circuit_breaker_limit}). Spawn denied."
        push_metric "CircuitBreakerTriggered" 1
        return 1
      fi

      # Atomically decrement slots via CAS (test + replace JSON patch)
      local new_slots=$((slots - 1))
      if kubectl_with_timeout 10 patch configmap coordinator-state -n "${NAMESPACE}" \
        --type=json \
        -p "[{\"op\":\"test\",\"path\":\"/data/spawnSlots\",\"value\":\"${slots}\"},{\"op\":\"replace\",\"path\":\"/data/spawnSlots\",\"value\":\"${new_slots}\"}]" \
        2>/dev/null; then
        log "Spawn slot granted: ${slots} → ${new_slots} slots remaining"
        push_metric "SpawnSlotGranted" 1
        return 0
      fi

      # CAS failed (concurrent modification) — retry with fresh data
      log "Spawn slot CAS retry $attempt/$max_attempts (concurrent modification detected)"
      sleep 0.$((RANDOM % 5 + 1))
    done

    log "ATOMIC SPAWN GATE: failed to acquire slot after $max_attempts attempts. Spawn denied."
    push_metric "CircuitBreakerTriggered" 1
    return 1
  }
fi

# release_spawn_slot() — increment spawnSlots when a spawn fails before completing.
# Uses CAS to safely increment without races.
if ! type release_spawn_slot >/dev/null 2>&1; then
  release_spawn_slot() {
    local circuit_breaker_limit
    circuit_breaker_limit=$(kubectl_with_timeout 10 get configmap agentex-constitution \
      -n "${NAMESPACE}" -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "6")
    if ! [[ "$circuit_breaker_limit" =~ ^[0-9]+$ ]]; then circuit_breaker_limit=6; fi

    local max_attempts=5
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
      attempt=$((attempt + 1))
      local slots
      slots=$(kubectl_with_timeout 10 get configmap coordinator-state \
        -n "${NAMESPACE}" -o jsonpath='{.data.spawnSlots}' 2>/dev/null || echo "")
      if [ -z "$slots" ] || ! [[ "$slots" =~ ^[0-9]+$ ]]; then
        log "WARNING: coordinator spawnSlots unavailable during release, skipping"
        return 0
      fi
      local new_slots=$((slots + 1))
      # Cap at circuit breaker limit to prevent slot leaks from double-release
      [ "$new_slots" -gt "$circuit_breaker_limit" ] && new_slots=$circuit_breaker_limit
      if kubectl_with_timeout 10 patch configmap coordinator-state -n "${NAMESPACE}" \
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
    log "WARNING: Failed to release spawn slot after $max_attempts attempts (coordinator will reconcile)"
  }
fi

# ── spawn_agent ───────────────────────────────────────────────────────────────
# Create an Agent CR for a new agent to pick up a Task CR.
# kro agent-graph turns the Agent CR into a Job automatically.
# Uses the atomic spawn gate (request_spawn_slot) — respects kill switch and circuit breaker.
#
# Issue #1817: Governance-enacted governance-mandate allSpawnFunctionsInHelpers=true
# This is a simplified version of entrypoint.sh spawn_agent() for OpenCode bash tool context.
# The kro health check / fallback Job creation is omitted — emergency perpetuation handles recovery.
#
# Usage: spawn_agent <name> <role> <task_ref> <reason> [bypass_killswitch] [capacity_type]
# Returns: 0 if Agent CR created, 1 if denied (circuit breaker, kill switch, kubectl failure)
#
# Example:
#   source /agent/helpers.sh
#   NEXT_NAME="worker-$(date +%s)"
#   spawn_agent "$NEXT_NAME" "worker" "task-$NEXT_NAME" "Continue platform improvement"
spawn_agent() {
  local name="$1" role="$2" task_ref="$3" reason="$4"
  local bypass_killswitch="${5:-false}" capacity_type="${6:-on-demand}"

  # Read constitution values needed for Agent CR and Job fallback
  local ecr_registry
  ecr_registry=$(kubectl_with_timeout 10 get configmap agentex-constitution \
    -n "${NAMESPACE}" -o jsonpath='{.data.ecrRegistry}' 2>/dev/null \
    || echo "569190534191.dkr.ecr.us-west-2.amazonaws.com")
  local bedrock_model="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-6}"
  local swarm_ref="${SWARM_REF:-}"
  local cluster="${CLUSTER:-agentex}"
  local bedrock_region="${BEDROCK_REGION:-us-west-2}"
  local repo="${REPO:-pnz1990/agentex}"

  # Acquire spawn slot (enforces circuit breaker + kill switch)
  if ! request_spawn_slot "$bypass_killswitch"; then
    log "spawn_agent: spawn slot denied by atomic gate. Not spawning $name."
    return 1
  fi

  # Calculate next generation
  local my_generation next_generation
  my_generation=$(get_my_generation)
  next_generation=$((my_generation + 1))

  log "Spawning successor: name=$name role=$role task=$task_ref gen=$next_generation reason=$reason"

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
  model: "${bedrock_model}"
  swarmRef: "${swarm_ref}"
  priority: 5
EOF
) || {
    log "ERROR: Failed to create Agent CR $name: $err_output"
    log "ERROR: Releasing spawn slot due to Agent CR creation failure."
    release_spawn_slot
    return 1
  }

  log "Agent CR $name created successfully (gen=$next_generation). kro will create the Job."
  log "Note: kro health check/fallback Job omitted in helpers.sh — emergency perpetuation handles recovery."
  return 0
}

# ── spawn_task_and_agent ──────────────────────────────────────────────────────
# Create a Task CR and immediately spawn an Agent CR to work it.
# Enforces circuit breaker, kill switch, issue validation, and duplicate PR prevention.
# This is the primary spawn primitive from the Prime Directive (step ①).
#
# Issue #1817: Governance-enacted governance-mandate allSpawnFunctionsInHelpers=true
# This is a simplified version of entrypoint.sh spawn_task_and_agent() for OpenCode context.
#
# Usage: spawn_task_and_agent <task_name> <agent_name> <role> <title> <desc> [effort] [issue] [swarm_ref]
# Returns: 0 if Task CR + Agent CR created, 1 if denied or already covered
#
# Example (from Prime Directive step ①):
#   source /agent/helpers.sh
#   NEXT_ROLE="worker"
#   NEXT_NAME="${NEXT_ROLE}-$(date +%s)"
#   TASK_NAME="task-${NEXT_NAME}"
#   spawn_task_and_agent \
#     "$TASK_NAME" "$NEXT_NAME" "$NEXT_ROLE" \
#     "Continue platform improvement — worker loop" \
#     "Check coordinator for assigned task, implement and open PR. Spawn successor when done." \
#     "M" 0 ""
spawn_task_and_agent() {
  local task_name="$1" agent_name="$2" role="$3" title="$4" desc="$5"
  local effort="${6:-M}" issue="${7:-0}" swarm_ref="${8:-}"
  local bypass_killswitch="${9:-false}" capacity_type="${10:-on-demand}"

  log "Creating Task $task_name and Agent $agent_name (role=$role)"

  # ISSUE VALIDATION: Verify GitHub issue exists and is open
  if [ "$issue" != "0" ] && [ "$issue" -gt 0 ] 2>/dev/null; then
    local issue_state
    issue_state=$(gh api "repos/${REPO}/issues/${issue}" --jq '.state' 2>/dev/null \
      | tr '[:lower:]' '[:upper:]' || echo "NOT_FOUND")

    if [ "$issue_state" = "NOT_FOUND" ]; then
      log "ERROR: GitHub issue #${issue} does not exist. Skipping spawn."
      post_thought "Skipped spawning worker: issue #${issue} not found in GitHub." "observation" 7
      return 0
    fi

    if [ "$issue_state" = "CLOSED" ]; then
      log "WARNING: GitHub issue #${issue} is closed. Skipping spawn."
      post_thought "Skipped spawning worker: issue #${issue} already closed (resolved or obsolete)." "observation" 7
      return 0
    fi

    log "Issue #${issue} validated: state=$issue_state"
  fi

  # DUPLICATE WORK PREVENTION: Check if issue already has an open PR with closing keyword
  if [ "$issue" != "0" ] && [ "$issue" -gt 0 ] 2>/dev/null; then
    local existing_pr
    existing_pr=$(gh api "repos/${REPO}/pulls?state=open&per_page=100" 2>/dev/null | \
      jq -r --arg n "$issue" \
      '[.[] | select((.body // "") | test("(closes|fixes|resolves)[[:space:]]+#\($n)\\b"; "i"))] |
       first | .number // ""' 2>/dev/null || echo "")
    if [ -n "$existing_pr" ]; then
      log "DUPLICATE DETECTION: Issue #${issue} already has open PR #${existing_pr}. Skipping spawn."
      post_thought "Skipped spawning worker for issue #${issue}: PR #${existing_pr} already open with closing keyword." "observation" 8
      return 0
    fi
  fi

  # Create Task CR
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

  # Spawn Agent CR (enforces circuit breaker + kill switch)
  if ! spawn_agent "$agent_name" "$role" "$task_name" "$title" "$bypass_killswitch" "$capacity_type"; then
    log "CRITICAL: spawn_agent blocked (circuit breaker or kill switch). Cleaning up orphaned Task CR."
    kubectl_with_timeout 10 delete task.kro.run "$task_name" -n "${NAMESPACE}" 2>/dev/null || true
    return 1
  fi
  return 0
}

log "helpers.sh loaded: post_thought, post_debate_response, record_debate_outcome, query_debate_outcomes, query_debate_outcomes_by_component, cite_debate_outcome, claim_task, civilization_status, write_planning_state, post_planning_thought, plan_for_n_plus_2, chronicle_query, propose_vision_feature, query_thoughts, cleanup_old_thoughts, cleanup_old_messages, cleanup_old_reports, post_chronicle_candidate, credit_mentor_for_success, write_swarm_memory, query_swarm_memories, spawn_agent, spawn_task_and_agent available"
log "  AGENT_NAME=${AGENT_NAME} NAMESPACE=${NAMESPACE} S3_BUCKET=${S3_BUCKET} REPO=${REPO}"
