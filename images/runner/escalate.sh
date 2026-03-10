#!/usr/bin/env bash
# escalate.sh — Structured Escalation Protocol (issue #1839)
#
# ax escalate: allows agents to signal "I need help" without crashing.
# Implements tiered escalation with structured severity levels.
#
# ESCALATION TIERS:
#   Tier 0: Self-Recovery (retry/fallback — no signal needed)
#   Tier 1: Coordinator Escalation (blocked/conflict/failed → coordinator reassigns)
#   Tier 2: God-Delegate Escalation (decision → evaluates and adjusts priority)
#   Tier 3: Human Escalation (security/proliferation → flags for human review)
#
# SEVERITY LEVELS:
#   LOW      (P3): Transient failure, auto-retry
#   MEDIUM   (P2): Dependency/conflict, reassign
#   HIGH     (P1): Ambiguous spec, needs decision
#   CRITICAL (P0): Security/proliferation, immediate human
#
# USAGE (from inside an agent session):
#   source /agent/escalate.sh
#   ax_escalate --severity medium --type blocked --issue 789 \
#     "Merge conflict in coordinator.go — 3 files conflict with main"
#
# OR as standalone script:
#   /agent/escalate.sh --severity high --type decision --issue 789 \
#     --options "SQLite,PostgreSQL,DynamoDB" \
#     "Which database for the work ledger?"
#
# EXIT STATE:
#   When this function is called by an agent, the agent should exit cleanly
#   after calling it. The escalation record is preserved in coordinator-state
#   for coordinator/god-delegate/human to resolve.
#
# IMPORTANT: This file is both a standalone script AND a sourceable library.
#   Source it to get ax_escalate() and escalate_to_coordinator() as functions.
#   Run it directly for standalone invocation.

set -o pipefail 2>/dev/null || true

NAMESPACE="${NAMESPACE:-agentex}"
AGENT_NAME="${AGENT_NAME:-unknown}"
TASK_CR_NAME="${TASK_CR_NAME:-}"

# ── kubectl_with_timeout ──────────────────────────────────────────────────────
# Defined here to avoid depending on helpers.sh being sourced.
if ! type kubectl_with_timeout >/dev/null 2>&1; then
  kubectl_with_timeout() {
    local timeout_secs="${1:-10}"
    shift
    timeout "${timeout_secs}s" kubectl "$@" 2>/dev/null
  }
fi

# ── log ───────────────────────────────────────────────────────────────────────
_esc_log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] [ESCALATION] $*" >&2
}

# ── SEVERITY → TIER MAPPING ──────────────────────────────────────────────────
# Maps category to default tier and auto-recovery behavior.
# Used by ax_escalate() to determine routing.
_escalation_tier_for_category() {
  local category="$1"
  case "$category" in
    retry)       echo "0" ;;   # Tier 0: self-recovery
    blocked)     echo "1" ;;   # Tier 1: coordinator
    conflict)    echo "1" ;;   # Tier 1: coordinator
    failed)      echo "1" ;;   # Tier 1: coordinator → Tier 2 if unresolved
    decision)    echo "2" ;;   # Tier 2: god-delegate
    security)    echo "3" ;;   # Tier 3: human (CRITICAL)
    proliferation) echo "3" ;; # Tier 3: kill switch / human
    *)           echo "1" ;;   # Default: coordinator
  esac
}

# ── SEVERITY → PRIORITY MAPPING ──────────────────────────────────────────────
_escalation_priority_for_severity() {
  local severity="$1"
  case "$severity" in
    low)      echo "P3" ;;
    medium)   echo "P2" ;;
    high)     echo "P1" ;;
    critical) echo "P0" ;;
    *)        echo "P2" ;;  # default medium
  esac
}

# ── write_escalation_record ───────────────────────────────────────────────────
# Write a structured escalation record to coordinator-state.escalationQueue.
# Format: semicolon-separated JSON-ish entries:
#   "severity:category:agent:issue:timestamp:description"
# Full JSON is written to S3 for coordinator processing.
_write_escalation_record() {
  local severity="$1"
  local category="$2"
  local issue="${3:-}"
  local description="$4"
  local options="${5:-}"
  local tier
  tier=$(_escalation_tier_for_category "$category")
  local priority
  priority=$(_escalation_priority_for_severity "$severity")
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local escalation_id
  escalation_id="esc-${AGENT_NAME}-$(date +%s)"

  # Write compact coordinator-state entry for fast coordinator scanning
  local entry="${escalation_id}:${severity}:${category}:${AGENT_NAME}:${issue}:${timestamp}"
  local current_queue
  current_queue=$(kubectl_with_timeout 10 get configmap coordinator-state \
    -n "$NAMESPACE" -o jsonpath='{.data.escalationQueue}' 2>/dev/null || echo "")

  local new_queue
  if [ -z "$current_queue" ]; then
    new_queue="$entry"
  else
    new_queue="${current_queue};${entry}"
  fi

  kubectl_with_timeout 10 patch configmap coordinator-state \
    -n "$NAMESPACE" --type=merge \
    -p "{\"data\":{\"escalationQueue\":\"${new_queue}\"}}" 2>/dev/null || \
    _esc_log "WARNING: Failed to write escalation to coordinator-state (non-fatal)"

  # Write full JSON to S3 for coordinator/god-delegate processing
  local s3_bucket="${S3_BUCKET:-agentex-thoughts}"
  local s3_path="s3://${s3_bucket}/escalations/${escalation_id}.json"

  # Escape for JSON
  local safe_desc
  safe_desc=$(echo "$description" | jq -Rs '.')
  local safe_options
  safe_options=$(echo "$options" | jq -Rs '.')

  local esc_json
  esc_json=$(cat <<EOF
{
  "id": "${escalation_id}",
  "severity": "${severity}",
  "category": "${category}",
  "tier": ${tier},
  "priority": "${priority}",
  "agent": "${AGENT_NAME}",
  "task": "${TASK_CR_NAME:-}",
  "issue": "${issue}",
  "description": ${safe_desc},
  "options": ${safe_options},
  "status": "open",
  "createdAt": "${timestamp}",
  "autoRecovery": $([ "$tier" = "0" ] && echo "true" || echo "false")
}
EOF
)

  if echo "$esc_json" | aws s3 cp - "$s3_path" --content-type application/json >/dev/null 2>&1; then
    _esc_log "Escalation record written to S3: ${s3_path}"
  else
    _esc_log "WARNING: Failed to write escalation to S3 (non-fatal — coordinator-state entry still written)"
  fi

  echo "$escalation_id"
}

# ── _post_escalation_thought ──────────────────────────────────────────────────
# Post a Thought CR for in-cluster visibility of the escalation.
_post_escalation_thought() {
  local escalation_id="$1"
  local severity="$2"
  local category="$3"
  local issue="$4"
  local description="$5"
  local tier
  tier=$(_escalation_tier_for_category "$category")
  local priority
  priority=$(_escalation_priority_for_severity "$severity")
  local thought_type="blocker"

  # CRITICAL escalations get highest confidence blocker thoughts
  local confidence=8
  [ "$severity" = "critical" ] && confidence=10

  local content="ESCALATION [${priority}] ${severity^^} — ${category^^}

Agent: ${AGENT_NAME}
Task: ${TASK_CR_NAME:-unknown}
Issue: ${issue:-none}
Tier: ${tier} ($([ "$tier" = "0" ] && echo "self-recovery" || [ "$tier" = "1" ] && echo "coordinator" || [ "$tier" = "2" ] && echo "god-delegate" || echo "human"))

Description: ${description}

Escalation ID: ${escalation_id}
Auto-recovery: $([ "$tier" = "0" ] && echo "yes (will retry)" || echo "no (human/coordinator decision needed)")"

  kubectl_with_timeout 10 apply -f - <<EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-${escalation_id}
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  taskRef: "${TASK_CR_NAME:-}"
  thoughtType: ${thought_type}
  confidence: ${confidence}
  topic: "escalation"
  content: |
$(echo "$content" | sed 's/^/    /')
EOF
  _esc_log "Posted escalation thought CR: thought-${escalation_id}"
}

# ── _handle_tier3_escalation ──────────────────────────────────────────────────
# For CRITICAL/Tier-3 escalations: check if kill switch should be activated,
# and optionally file a GitHub issue labeled "needs-human".
_handle_tier3_escalation() {
  local severity="$1"
  local category="$2"
  local description="$3"
  local issue_ref="$4"
  local escalation_id="$5"

  _esc_log "Tier 3 escalation detected (severity=${severity} category=${category})"

  # For proliferation: recommend kill switch activation
  if [ "$category" = "proliferation" ]; then
    _esc_log "PROLIFERATION escalation — kill switch activation recommended"
    kubectl_with_timeout 10 apply -f - <<EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-esc-proliferation-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  taskRef: "${TASK_CR_NAME:-}"
  thoughtType: blocker
  confidence: 10
  topic: "escalation"
  content: |
    CRITICAL PROLIFERATION ESCALATION — Kill switch activation may be needed.
    
    Agent: ${AGENT_NAME}
    Description: ${description}
    Escalation ID: ${escalation_id}
    
    To activate kill switch:
      kubectl patch configmap agentex-killswitch -n agentex \\
        --type=merge -p '{"data":{"enabled":"true","reason":"${description}"}}'
EOF
  fi

  # File a GitHub issue labeled needs-human for Tier-3 escalations
  local repo="${REPO:-pnz1990/agentex}"
  if command -v gh >/dev/null 2>&1; then
    local gh_issue_number
    gh_issue_number=$(gh issue create \
      --repo "$repo" \
      --title "[ESCALATION] ${severity^^} ${category}: ${description:0:80}" \
      --body "## Escalation: ${escalation_id}

**Severity:** ${severity} (${_escalation_priority_for_severity "$severity"})
**Category:** ${category}
**Agent:** ${AGENT_NAME}
**Task:** ${TASK_CR_NAME:-unknown}
**Related Issue:** ${issue_ref:-none}

## Description

${description}

## Required Action

This escalation requires human review.
- For \`security\`: Review the security concern immediately
- For \`proliferation\`: Check kill switch status and agent count
- For \`decision\`: Make the requested architectural decision

## Escalation Record

Stored at: s3://agentex-thoughts/escalations/${escalation_id}.json

_Auto-filed by structured escalation protocol (issue #1839)_" \
      --label "needs-human" 2>/dev/null || echo "")

    if [ -n "$gh_issue_number" ]; then
      _esc_log "Filed Tier-3 GitHub issue: ${gh_issue_number}"
    else
      _esc_log "WARNING: Failed to file GitHub issue for Tier-3 escalation (non-fatal)"
    fi
  fi
}

# ── ax_escalate ───────────────────────────────────────────────────────────────
# Main escalation function — the agent's primary interface to the escalation protocol.
# Agents call this instead of crashing when they encounter a recoverable or
# decision-requiring situation.
#
# Usage:
#   ax_escalate --severity <low|medium|high|critical> \
#               --type <retry|blocked|conflict|decision|failed|security|proliferation> \
#               [--issue <github_issue_number>] \
#               [--options "<comma,separated,choices>"] \
#               "<description>"
#
# Examples:
#   ax_escalate --severity medium --type blocked --issue 789 \
#     "Merge conflict in coordinator.go — 3 files conflict with main"
#
#   ax_escalate --severity high --type decision --issue 789 \
#     --options "SQLite,PostgreSQL,DynamoDB" \
#     "Which database for the work ledger?"
#
#   ax_escalate --severity critical --type security \
#     "Found exposed AWS credentials in PR #1830"
#
# Returns: escalation_id (written to stdout)
# Side effects:
#   - Writes to coordinator-state.escalationQueue
#   - Writes JSON record to S3 escalations/
#   - Posts Thought CR (blocker type)
#   - For Tier-3: files GitHub issue with needs-human label
ax_escalate() {
  local severity="medium"
  local category="blocked"
  local issue=""
  local options=""
  local description=""

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --severity|-s) severity="$2"; shift 2 ;;
      --type|-t)     category="$2"; shift 2 ;;
      --issue|-i)    issue="$2"; shift 2 ;;
      --options|-o)  options="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: ax_escalate --severity <low|medium|high|critical> --type <category> [--issue N] [--options csv] <description>"
        return 0 ;;
      -*)  shift ;;  # unknown flag
      *)   description="$1"; shift ;;
    esac
  done

  if [ -z "$description" ]; then
    _esc_log "ERROR: ax_escalate requires a description argument"
    return 1
  fi

  # Validate severity
  case "$severity" in
    low|medium|high|critical) ;;
    *) _esc_log "WARNING: Unknown severity '${severity}', defaulting to medium"; severity="medium" ;;
  esac

  # Validate category
  case "$category" in
    retry|blocked|conflict|failed|decision|security|proliferation) ;;
    *) _esc_log "WARNING: Unknown category '${category}', defaulting to blocked"; category="blocked" ;;
  esac

  local tier
  tier=$(_escalation_tier_for_category "$category")
  local priority
  priority=$(_escalation_priority_for_severity "$severity")

  _esc_log "Escalating: severity=${severity} category=${category} tier=${tier} priority=${priority} issue=${issue:-none}"
  _esc_log "Description: ${description}"

  # Write escalation record and get ID
  local escalation_id
  escalation_id=$(_write_escalation_record "$severity" "$category" "$issue" "$description" "$options")

  # Post in-cluster Thought CR for peer visibility
  _post_escalation_thought "$escalation_id" "$severity" "$category" "$issue" "$description"

  # Handle Tier-3 escalations specially (security/proliferation)
  if [ "$tier" = "3" ]; then
    _handle_tier3_escalation "$severity" "$category" "$description" "$issue" "$escalation_id"
  fi

  _esc_log "Escalation complete: ${escalation_id} (tier=${tier} priority=${priority})"
  echo "$escalation_id"
}

# ── escalate_to_coordinator ───────────────────────────────────────────────────
# Convenience wrapper: signal to coordinator that you are blocked and cannot proceed.
# This is the canonical "I need help" signal for Tier-1 coordinator escalations.
# Equivalent to: ax_escalate --severity medium --type blocked ...
#
# Usage: escalate_to_coordinator <issue_number> <description>
escalate_to_coordinator() {
  local issue="${1:-}"
  local description="${2:-}"
  ax_escalate --severity medium --type blocked --issue "$issue" "$description"
}

# ── query_escalations ─────────────────────────────────────────────────────────
# Query current escalation queue from coordinator-state.
# Usage: query_escalations [--open] [--severity <level>] [--agent <name>]
query_escalations() {
  local filter_open=false
  local filter_severity=""
  local filter_agent=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --open)      filter_open=true; shift ;;
      --severity)  filter_severity="$2"; shift 2 ;;
      --agent)     filter_agent="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local queue
  queue=$(kubectl_with_timeout 10 get configmap coordinator-state \
    -n "$NAMESPACE" -o jsonpath='{.data.escalationQueue}' 2>/dev/null || echo "")

  if [ -z "$queue" ]; then
    echo "No escalations in queue"
    return 0
  fi

  echo "=== Current Escalation Queue ==="
  echo "$queue" | tr ';' '\n' | while IFS=: read -r esc_id sev cat agent issue ts; do
    [ -z "$esc_id" ] && continue
    [ -n "$filter_severity" ] && [ "$sev" != "$filter_severity" ] && continue
    [ -n "$filter_agent" ] && [ "$agent" != "$filter_agent" ] && continue
    local tier
    tier=$(_escalation_tier_for_category "$cat")
    echo "  ${esc_id}: [${sev^^}/Tier${tier}] ${cat} | agent=${agent} issue=${issue:-none} ts=${ts}"
  done
}

# ── resolve_escalation ────────────────────────────────────────────────────────
# Mark an escalation as resolved (coordinator/god-delegate calls this).
# Usage: resolve_escalation <escalation_id> <resolution>
resolve_escalation() {
  local esc_id="$1"
  local resolution="${2:-resolved}"

  if [ -z "$esc_id" ]; then
    _esc_log "ERROR: resolve_escalation requires escalation_id"
    return 1
  fi

  # Remove from coordinator-state.escalationQueue
  local queue
  queue=$(kubectl_with_timeout 10 get configmap coordinator-state \
    -n "$NAMESPACE" -o jsonpath='{.data.escalationQueue}' 2>/dev/null || echo "")

  if [ -n "$queue" ]; then
    local updated_queue
    updated_queue=$(echo "$queue" | tr ';' '\n' | grep -v "^${esc_id}:" | tr '\n' ';' | sed 's/;$//')
    kubectl_with_timeout 10 patch configmap coordinator-state \
      -n "$NAMESPACE" --type=merge \
      -p "{\"data\":{\"escalationQueue\":\"${updated_queue}\"}}" 2>/dev/null || true
  fi

  # Update S3 record status
  local s3_bucket="${S3_BUCKET:-agentex-thoughts}"
  local s3_path="s3://${s3_bucket}/escalations/${esc_id}.json"
  if aws s3 ls "$s3_path" >/dev/null 2>&1; then
    local existing
    existing=$(aws s3 cp "$s3_path" - 2>/dev/null || echo "{}")
    local updated
    updated=$(echo "$existing" | jq \
      --arg resolution "$resolution" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg by "${AGENT_NAME:-coordinator}" \
      '.status = "resolved" | .resolution = $resolution | .resolvedAt = $ts | .resolvedBy = $by' \
      2>/dev/null || echo "$existing")
    echo "$updated" | aws s3 cp - "$s3_path" --content-type application/json >/dev/null 2>&1 || true
  fi

  _esc_log "Resolved escalation: ${esc_id} (${resolution})"
}

# ── MAIN (standalone invocation) ─────────────────────────────────────────────
# When run directly (not sourced), execute ax_escalate with the provided args.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ax_escalate "$@"
fi
