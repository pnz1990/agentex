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

# ── find_predecessor_mentors ──────────────────────────────────────────────────
# Find predecessor agents with matching specializations for knowledge transfer.
# Searches S3 identities for agents whose specialization matches issue labels.
# Returns: JSON array of mentor insights with agent name, specialization, and key stats
#
# Usage: find_predecessor_mentors <issue_number>
# Returns: JSON array like: [{"agent":"ada","spec":"bug-specialist","insights":"..."}]
#
# This enables generational knowledge transfer — new agents inherit context from
# specialists who worked on similar issues before them (issue #1228).
find_predecessor_mentors() {
  local issue_number="$1"
  
  if [ -z "$issue_number" ] || [ "$issue_number" = "0" ]; then
    echo "[]"
    return 0
  fi
  
  # Get issue labels from GitHub (rate limit protected)
  local issue_labels
  issue_labels=$(gh issue view "$issue_number" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
  
  if [ -z "$issue_labels" ]; then
    log "find_predecessor_mentors: No labels found for issue #${issue_number}"
    echo "[]"
    return 0
  fi
  
  log "find_predecessor_mentors: Issue #${issue_number} labels: $(echo $issue_labels | tr '\n' ' ')"
  
  # List all identity files in S3
  local identity_files
  identity_files=$(aws s3 ls "s3://${S3_BUCKET}/identities/" 2>/dev/null | awk '{print $4}' || echo "")
  
  if [ -z "$identity_files" ]; then
    log "find_predecessor_mentors: No identity files found in S3"
    echo "[]"
    return 0
  fi
  
  local mentors="[]"
  local match_count=0
  
  # Search for agents with matching specializations
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    
    local s3_path="s3://${S3_BUCKET}/identities/${file}"
    local identity_json
    identity_json=$(aws s3 cp "$s3_path" - 2>/dev/null || echo "")
    [ -z "$identity_json" ] && continue
    
    local agent_spec
    agent_spec=$(echo "$identity_json" | jq -r '.specialization // ""' 2>/dev/null)
    [ -z "$agent_spec" ] && continue
    
    local agent_display
    agent_display=$(echo "$identity_json" | jq -r '.displayName // .agentName' 2>/dev/null)
    
    # Check if specialization matches any issue label
    local matched=false
    while IFS= read -r label; do
      [ -z "$label" ] && continue
      
      # Match if specialization contains label keyword (e.g., "bug-specialist" matches "bug" label)
      if echo "$agent_spec" | grep -qi "$label"; then
        matched=true
        break
      fi
      
      # Also match reverse: label contains specialization root (e.g., "enhancement" label matches "enhancement-specialist")
      local spec_root
      spec_root=$(echo "$agent_spec" | sed 's/-specialist$//')
      if echo "$label" | grep -qi "$spec_root"; then
        matched=true
        break
      fi
    done <<< "$issue_labels"
    
    if [ "$matched" = "true" ]; then
      # Extract key stats for context
      local tasks_completed
      tasks_completed=$(echo "$identity_json" | jq -r '.stats.tasksCompleted // 0' 2>/dev/null)
      local prs_merged
      prs_merged=$(echo "$identity_json" | jq -r '.stats.prsMerged // 0' 2>/dev/null)
      
      # Extract specialization detail
      local code_areas
      code_areas=$(echo "$identity_json" | jq -c '.specializationDetail.codeAreas // {}' 2>/dev/null)
      local synthesis_count
      synthesis_count=$(echo "$identity_json" | jq -r '.specializationDetail.synthesisCount // 0' 2>/dev/null)
      
      # Build insight summary
      local insight="Agent ${agent_display} [${agent_spec}] completed ${tasks_completed} tasks, ${prs_merged} PRs merged"
      if [ "$synthesis_count" -gt 0 ]; then
        insight="${insight}, ${synthesis_count} debate syntheses"
      fi
      
      local code_area_list=""
      if [ "$code_areas" != "{}" ]; then
        code_area_list=$(echo "$code_areas" | jq -r 'to_entries | sort_by(-.value) | .[0:3] | map(.key) | join(", ")' 2>/dev/null || echo "")
        if [ -n "$code_area_list" ]; then
          insight="${insight}. Code areas: ${code_area_list}"
        fi
      fi
      
      # Add to mentors array
      local mentor_obj
      mentor_obj=$(jq -n \
        --arg agent "$agent_display" \
        --arg spec "$agent_spec" \
        --arg insights "$insight" \
        '{agent: $agent, specialization: $spec, insights: $insights}')
      
      mentors=$(echo "$mentors" | jq -r --argjson mentor "$mentor_obj" '. + [$mentor]' 2>/dev/null || echo "$mentors")
      match_count=$((match_count + 1))
      
      log "find_predecessor_mentors: Found mentor ${agent_display} [${agent_spec}]"
      
      # Limit to top 3 mentors to avoid overwhelming task description
      if [ "$match_count" -ge 3 ]; then
        break
      fi
    fi
  done <<< "$identity_files"
  
  log "find_predecessor_mentors: Found ${match_count} matching mentors for issue #${issue_number}"
  echo "$mentors"
}

log "helpers.sh loaded: post_thought, post_debate_response, record_debate_outcome, query_debate_outcomes, find_predecessor_mentors available"
log "  AGENT_NAME=${AGENT_NAME} NAMESPACE=${NAMESPACE} S3_BUCKET=${S3_BUCKET} REPO=${REPO}"
