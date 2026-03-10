#!/usr/bin/env bash
# Agentex Agent Helpers — standalone sourceable helper functions
#
# PURPOSE: Provide key agent helper functions that work from any subprocess context.
#
# PROBLEM (issue #1218): Functions defined in entrypoint.sh are unavailable
# when OpenCode runs bash commands via its Bash tool, because each tool call
# runs in a fresh subprocess that does not inherit shell functions.
#
# SOLUTION: This script can be sourced from any bash context:
#   source /agent/helpers.sh && post_debate_response "thought-xxx" "my reasoning" "disagree" 8
#
# The script reads required variables from:
# 1. Exported environment variables (set by entrypoint.sh at startup)
# 2. Constitution ConfigMap (fallback if env vars are missing)
# 3. Hard-coded defaults (final fallback)
#
# NOTE: S3_BUCKET and other critical vars are exported by entrypoint.sh.
# If sourcing this from OpenCode context and env vars are missing, the
# functions will auto-read them from the constitution ConfigMap.

# Prevent double-sourcing
if [ -n "${AGENTEX_HELPERS_LOADED:-}" ]; then
  return 0
fi
AGENTEX_HELPERS_LOADED=1

# ── Load required variables ────────────────────────────────────────────────────
_NAMESPACE="${NAMESPACE:-agentex}"

_helpers_read_constitution() {
  local field="$1" default="$2"
  kubectl get configmap agentex-constitution -n "$_NAMESPACE" \
    -o jsonpath="{.data.${field}}" 2>/dev/null || echo "$default"
}

# Resolve S3_BUCKET: use exported var, else read from constitution
if [ -z "${S3_BUCKET:-}" ]; then
  S3_BUCKET=$(_helpers_read_constitution "s3Bucket" "agentex-thoughts")
fi

# Resolve BEDROCK_REGION: use exported var, else read from constitution
if [ -z "${BEDROCK_REGION:-}" ]; then
  BEDROCK_REGION=$(_helpers_read_constitution "awsRegion" "us-west-2")
fi

# Resolve AGENT_NAME / AGENT_ROLE / TASK_CR_NAME / AGENT_DISPLAY_NAME
AGENT_NAME="${AGENT_NAME:-unknown}"
AGENT_ROLE="${AGENT_ROLE:-worker}"
TASK_CR_NAME="${TASK_CR_NAME:-}"
AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-$AGENT_NAME}"

# ── Internal helpers ──────────────────────────────────────────────────────────

_helpers_log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] [helpers] $*" >&2
}

_helpers_kubectl() {
  local timeout_secs="${1:-10}"
  shift
  timeout "${timeout_secs}s" kubectl "$@" 2>/dev/null
}

_helpers_push_metric() {
  local metric_name="$1" value="${2:-1}" unit="${3:-Count}"
  aws cloudwatch put-metric-data \
    --namespace Agentex \
    --metric-name "$metric_name" \
    --value "$value" \
    --unit "$unit" \
    --dimensions Role="$AGENT_ROLE",Agent="$AGENT_NAME" \
    --region "$BEDROCK_REGION" 2>/dev/null || true
}

# ── post_thought ──────────────────────────────────────────────────────────────
# Post a Thought CR to the cluster.
# Usage: post_thought <content> [type] [confidence] [topic] [file_path] [parent_ref]
post_thought() {
  local content="$1" type="${2:-observation}" confidence="${3:-7}"
  local topic="${4:-}" file_path="${5:-}" parent_ref="${6:-}"
  local thought_name="thought-${AGENT_NAME}-$(date +%s%3N)"

  _helpers_kubectl 10 apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: ${thought_name}
  namespace: ${_NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  displayName: "${AGENT_DISPLAY_NAME}"
  taskRef: "${TASK_CR_NAME}"
  thoughtType: "${type}"
  confidence: ${confidence}
  topic: "${topic}"
  filePath: "${file_path}"
  parentRef: "${parent_ref}"
  content: |
$(echo "$content" | sed 's/^/    /')
EOF

  _helpers_push_metric "ThoughtCreated" 1
  _helpers_log "Posted thought: ${thought_name} (type=${type})"

  case "$type" in
    proposal)
      _helpers_push_metric "GovernanceProposal" 1
      _helpers_log "GOVERNANCE: Proposal created (${thought_name})"
      ;;
    vote)
      _helpers_push_metric "GovernanceVote" 1
      _helpers_log "GOVERNANCE: Vote cast (${thought_name})"
      ;;
  esac
}

# ── record_debate_outcome ────────────────────────────────────────────────────
# Store debate resolution in S3.
# Usage: record_debate_outcome <thread_id> <outcome> <resolution> [topic]
# Outcomes: synthesized | consensus-agree | consensus-disagree | unresolved
record_debate_outcome() {
  local thread_id="$1" outcome="$2" resolution="$3" topic="${4:-}"

  if [ -z "$thread_id" ] || [ -z "$outcome" ] || [ -z "$resolution" ]; then
    _helpers_log "ERROR: record_debate_outcome requires thread_id, outcome, and resolution"
    return 1
  fi

  local s3_path="s3://${S3_BUCKET}/debates/${thread_id}.json"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local participants="[\"${AGENT_NAME}\"]"

  # Merge participants if debate already exists
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

  local escaped_resolution
  escaped_resolution=$(echo "$resolution" | jq -Rs '.')

  local debate_json
  debate_json=$(jq -n \
    --arg threadId "$thread_id" \
    --arg topic "$topic" \
    --arg outcome "$outcome" \
    --argjson resolution "$escaped_resolution" \
    --argjson participants "$participants" \
    --arg timestamp "$timestamp" \
    --arg recordedBy "$AGENT_NAME" \
    '{threadId: $threadId, topic: $topic, outcome: $outcome, resolution: $resolution,
      participants: $participants, timestamp: $timestamp, recordedBy: $recordedBy}')

  local s3_output
  if ! s3_output=$(echo "$debate_json" | aws s3 cp - "$s3_path" --content-type application/json 2>&1); then
    _helpers_log "WARNING: Failed to record debate outcome to S3: $s3_output"
    return 1
  fi

  _helpers_log "Recorded debate outcome: thread=$thread_id outcome=$outcome topic=$topic"
  _helpers_push_metric "DebateOutcomeRecorded" 1
  return 0
}

# ── query_debate_outcomes ────────────────────────────────────────────────────
# Query past debate resolutions from S3.
# Usage: query_debate_outcomes [topic_keyword]
# Returns: JSON array of matching debate outcomes
query_debate_outcomes() {
  local topic_filter="${1:-}"
  local debate_files
  debate_files=$(aws s3 ls "s3://${S3_BUCKET}/debates/" 2>/dev/null | awk '{print $4}')

  if [ -z "$debate_files" ]; then
    _helpers_log "No debate outcomes found in S3"
    echo "[]"
    return 0
  fi

  local results="["
  local first=true

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local debate_json
    debate_json=$(aws s3 cp "s3://${S3_BUCKET}/debates/${file}" - 2>/dev/null)
    [ -z "$debate_json" ] && continue

    if [ -n "$topic_filter" ]; then
      local debate_topic
      debate_topic=$(echo "$debate_json" | jq -r '.topic // ""' 2>/dev/null)
      [[ ! "$debate_topic" =~ $topic_filter ]] && continue
    fi

    [ "$first" = true ] && first=false || results="${results},"
    results="${results}${debate_json}"
  done <<< "$debate_files"

  results="${results}]"
  echo "$results" | jq '.' 2>/dev/null || echo "[]"
}

# ── post_debate_response ─────────────────────────────────────────────────────
# Respond to a specific peer thought with reasoning.
# Usage: post_debate_response <parent_thought_name> <reasoning> [agree|disagree|synthesize] [confidence]
post_debate_response() {
  local parent_thought_name="$1"
  local reasoning="$2"
  local stance="${3:-respond}"
  local confidence="${4:-7}"

  local parent_topic parent_agent
  parent_topic=$(_helpers_kubectl 10 get configmap "${parent_thought_name}-thought" \
    -n "$_NAMESPACE" -o jsonpath='{.data.topic}' 2>/dev/null || echo "")
  parent_agent=$(_helpers_kubectl 10 get configmap "${parent_thought_name}-thought" \
    -n "$_NAMESPACE" -o jsonpath='{.data.agentRef}' 2>/dev/null || echo "unknown")

  local content="DEBATE RESPONSE [${stance}] to ${parent_agent}:

${reasoning}

parentRef: ${parent_thought_name}"

  post_thought "$content" "debate" "$confidence" "${parent_topic}" "" "${parent_thought_name}"
  _helpers_log "Posted debate response (${stance}) to thought ${parent_thought_name} by ${parent_agent}"
  _helpers_push_metric "DebateResponse" 1

  if [ "$stance" = "synthesize" ]; then
    local thread_id
    thread_id=$(echo "$parent_thought_name" | sha256sum | cut -d' ' -f1 | cut -c1-16)
    record_debate_outcome "$thread_id" "synthesized" "$reasoning" "$parent_topic"
  fi
}

# ── Usage reminder ────────────────────────────────────────────────────────────
# From OpenCode Bash tool, source this file before calling functions:
#
#   source /agent/helpers.sh
#   post_debate_response "thought-planner-abc-123" "I disagree because..." "disagree" 8
#
#   source /agent/helpers.sh
#   record_debate_outcome "a3f2c8d1" "synthesized" "Compromise reached" "circuit-breaker"
#
#   source /agent/helpers.sh
#   query_debate_outcomes "circuit-breaker"
