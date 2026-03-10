#!/usr/bin/env bash
# escalate.sh — Structured escalation protocol for agentex agents
#
# Part of v1.0 Roadmap (#1821) — Phase 3: Recovery without god
# Implements: issue #1839 — Structured escalation protocol
#
# USAGE (from inside an agent session):
#   source /agent/helpers.sh  # for post_thought
#   source /workspace/repo/manifests/system/escalate.sh
#
#   # Or run directly:
#   ./manifests/system/escalate.sh --severity medium --type blocked \
#     --issue 789 "Merge conflict in coordinator.go"
#
#   ./manifests/system/escalate.sh --severity high --type decision \
#     --issue 789 --options "SQLite,PostgreSQL,DynamoDB" \
#     "Which database for the work ledger?"
#
#   ./manifests/system/escalate.sh --severity critical --type security \
#     "Found exposed AWS credentials in PR #1830"
#
# EXIT CODES:
#   0 — escalation recorded successfully
#   1 — usage error (bad args)
#   2 — escalation storage failed (non-fatal)
#
# ESCALATION TIERS:
#   LOW      → Tier 0: self-recovery (retry)
#   MEDIUM   → Tier 1: coordinator escalation (reassign/fresh worker)
#   HIGH     → Tier 2: god-delegate escalation (decision needed)
#   CRITICAL → Tier 3: immediate human attention
#
# ESCALATION TYPES:
#   retry        — transient failure, try again
#   blocked      — dependency not met
#   conflict     — merge/code conflict
#   decision     — multiple valid paths, need choice
#   failed       — unrecoverable error
#   security     — security issue found
#   proliferation — too many agents spawning

set -euo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
AGENT_NAME="${AGENT_NAME:-$(hostname)}"
TASK_CR_NAME="${TASK_CR_NAME:-}"

# Read S3 bucket from environment or constitution
S3_BUCKET="${S3_BUCKET:-}"
if [ -z "$S3_BUCKET" ]; then
  S3_BUCKET=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
    -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")
fi
S3_BUCKET="${S3_BUCKET:-agentex-thoughts}"

# Read GitHub repo
REPO="${REPO:-}"
if [ -z "$REPO" ]; then
  REPO=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
    -o jsonpath='{.data.githubRepo}' 2>/dev/null || echo "pnz1990/agentex")
fi
REPO="${REPO:-pnz1990/agentex}"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [escalate] $*" >&2; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat >&2 <<'EOF'
USAGE:
  escalate.sh [OPTIONS] "description of the problem"

OPTIONS:
  --severity  low|medium|high|critical     (default: medium)
  --type      retry|blocked|conflict|decision|failed|security|proliferation
              (default: blocked)
  --issue     <github-issue-number>        (optional: issue being worked on)
  --options   "opt1,opt2,opt3"             (for --type decision: choices)
  --agent     <agent-name>                 (default: $AGENT_NAME)
  --task      <task-cr-name>               (default: $TASK_CR_NAME)
  --dry-run                                (print what would happen, no action)
  --list                                   (list recent escalations)
  --help                                   (show this help)

EXAMPLES:
  escalate.sh --severity medium --type blocked --issue 789 \
    "Merge conflict in coordinator.go — 3 files conflict with main"

  escalate.sh --severity high --type decision --issue 789 \
    --options "SQLite,PostgreSQL,DynamoDB" \
    "Which database for the work ledger?"

  escalate.sh --severity critical --type security \
    "Found exposed AWS credentials in PR #1830"

  escalate.sh --severity low --type retry --issue 456 \
    "GitHub API rate limit hit, retrying in 5 minutes"

ESCALATION TIERS:
  LOW      (P3) → Tier 0: self-recovery — log and continue
  MEDIUM   (P2) → Tier 1: coordinator — reassign task or spawn fresh worker
  HIGH     (P1) → Tier 2: god-delegate — evaluates and adjusts priority
  CRITICAL (P0) → Tier 3: human — dashboard alert + GitHub issue labeled needs-human

ESCALATION TYPES:
  retry        — transient failure, will auto-retry (Tier 0)
  blocked      — dependency not met, needs coordinator (Tier 1)
  conflict     — merge conflict, spawn fresh worker (Tier 1)
  decision     — ambiguous spec, need choice between options (Tier 2)
  failed       — unrecoverable error (Tier 1→2)
  security     — security issue found (Tier 3)
  proliferation — too many agents spawning (Tier 3 / kill switch)
EOF
  exit 1
}

# ── Parse arguments ───────────────────────────────────────────────────────────
SEVERITY="medium"
TYPE="blocked"
ISSUE=""
OPTIONS=""
DESCRIPTION=""
DRY_RUN=false
LIST_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --severity)   SEVERITY="$2"; shift 2 ;;
    --type)       TYPE="$2"; shift 2 ;;
    --issue)      ISSUE="$2"; shift 2 ;;
    --options)    OPTIONS="$2"; shift 2 ;;
    --agent)      AGENT_NAME="$2"; shift 2 ;;
    --task)       TASK_CR_NAME="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --list)       LIST_MODE=true; shift ;;
    --help|-h)    usage ;;
    -*)           echo "Unknown option: $1" >&2; usage ;;
    *)            DESCRIPTION="$1"; shift ;;
  esac
done

# ── List mode ─────────────────────────────────────────────────────────────────
list_escalations() {
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║          RECENT ESCALATIONS (last 24h)                  ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Read from coordinator-state escalation field if it exists
  local esc_data
  esc_data=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
    -o jsonpath='{.data.escalations}' 2>/dev/null || echo "")

  if [ -n "$esc_data" ]; then
    echo -e "${BOLD}From coordinator-state:${NC}"
    # Parse pipe-separated escalations: severity:type:agent:issue:ts:desc
    IFS='|' read -ra ESC_ENTRIES <<< "$esc_data"
    local count=0
    for entry in "${ESC_ENTRIES[@]}"; do
      [ -z "$entry" ] && continue
      IFS=':' read -r sev typ agt iss ts desc_encoded <<< "$entry"
      desc=$(echo "$desc_encoded" | sed 's/%3A/:/g; s/%7C/|/g')
      local color="$NC"
      case "$sev" in
        critical) color="$RED" ;;
        high)     color="$YELLOW" ;;
        medium)   color="$CYAN" ;;
        low)      color="$GREEN" ;;
      esac
      local issue_str=""
      [ -n "$iss" ] && [ "$iss" != "none" ] && issue_str=" #${iss}"
      echo -e "  ${color}[${sev^^}]${NC} [${typ}]${issue_str} ${agt} @ ${ts}"
      echo "         ${desc}"
      count=$((count + 1))
    done
    [ "$count" -eq 0 ] && echo "  (no escalations recorded)"
  fi

  echo ""
  # Also show recent blocker thoughts from cluster
  echo -e "${BOLD}Recent blocker thoughts:${NC}"
  kubectl get configmaps -n "$NAMESPACE" -l agentex/thought -o json 2>/dev/null | \
    jq -r '.items | sort_by(.metadata.creationTimestamp) | reverse | .[0:20] |
      .[] | select(.data.thoughtType=="blocker") |
      "  [\(.metadata.creationTimestamp | split("T")[1] | split("Z")[0])] \(.data.agentRef): \(.data.content | split("\n")[0])"' \
    2>/dev/null | head -10 || echo "  (none)"
  echo ""

  # Show GitHub issues labeled needs-human
  echo -e "${BOLD}Issues flagged for human attention:${NC}"
  gh issue list --repo "$REPO" --label "needs-human" --state open --limit 5 \
    --json number,title,createdAt \
    --jq '.[] | "  #\(.number) \(.title)"' 2>/dev/null || echo "  (none)"
  echo ""
}

if [ "$LIST_MODE" = true ]; then
  list_escalations
  exit 0
fi

# ── Validate inputs ───────────────────────────────────────────────────────────
if [ -z "$DESCRIPTION" ]; then
  echo -e "${RED}ERROR: description is required${NC}" >&2
  usage
fi

# Validate severity
case "$SEVERITY" in
  low|medium|high|critical) ;;
  *) echo -e "${RED}ERROR: invalid severity '$SEVERITY'. Use: low|medium|high|critical${NC}" >&2; exit 1 ;;
esac

# Validate type
case "$TYPE" in
  retry|blocked|conflict|decision|failed|security|proliferation) ;;
  *) echo -e "${RED}ERROR: invalid type '$TYPE'. Use: retry|blocked|conflict|decision|failed|security|proliferation${NC}" >&2; exit 1 ;;
esac

# Decision type requires options
if [ "$TYPE" = "decision" ] && [ -z "$OPTIONS" ]; then
  log "WARNING: decision type without --options. Use --options 'opt1,opt2,opt3' to list choices."
fi

# ── Determine tier and action ─────────────────────────────────────────────────
determine_tier() {
  # Security and proliferation always go to Tier 3 regardless of severity
  if [ "$TYPE" = "security" ] || [ "$TYPE" = "proliferation" ]; then
    echo "3"
    return
  fi

  case "$SEVERITY" in
    low)      echo "0" ;;
    medium)   echo "1" ;;
    high)     echo "2" ;;
    critical) echo "3" ;;
  esac
}

TIER=$(determine_tier)

determine_auto_action() {
  case "$TYPE" in
    retry)        echo "re-queue after 5min delay" ;;
    blocked)      echo "check if dependency resolved, re-queue" ;;
    conflict)     echo "spawn fresh worker on current main" ;;
    decision)     echo "route to god-delegate or dashboard for choice" ;;
    failed)       echo "escalate to coordinator, then god-delegate if unresolved" ;;
    security)     echo "label issue needs-human, post CRITICAL thought, flag dashboard" ;;
    proliferation) echo "activate kill switch immediately" ;;
  esac
}

AUTO_ACTION=$(determine_auto_action)

# ── Display escalation banner ─────────────────────────────────────────────────
display_banner() {
  echo ""
  local color tier_label
  case "$SEVERITY" in
    critical) color="$RED" ;;
    high)     color="$YELLOW" ;;
    medium)   color="$CYAN" ;;
    low)      color="$GREEN" ;;
  esac

  case "$TIER" in
    0) tier_label="Tier 0 — Self Recovery" ;;
    1) tier_label="Tier 1 — Coordinator Escalation" ;;
    2) tier_label="Tier 2 — God-Delegate Escalation" ;;
    3) tier_label="Tier 3 — Human Escalation (IMMEDIATE)" ;;
  esac

  echo -e "${color}${BOLD}╔══════════════════════════════════════════════════════════╗"
  printf "║  ESCALATION: %-10s / %-12s / %s\n" "${SEVERITY^^}" "${TYPE}" "${tier_label}"
  echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Agent:${NC}       $AGENT_NAME"
  [ -n "$ISSUE" ] && echo -e "  ${BOLD}Issue:${NC}       #$ISSUE"
  echo -e "  ${BOLD}Problem:${NC}     $DESCRIPTION"
  [ -n "$OPTIONS" ] && echo -e "  ${BOLD}Options:${NC}     $OPTIONS"
  echo -e "  ${BOLD}Auto-action:${NC} $AUTO_ACTION"
  echo ""
}

display_banner

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}DRY RUN — no actions taken${NC}"
  exit 0
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ESCALATION_ID="esc-$(date +%s)-${SEVERITY:0:3}"

# ── Tier 0: Self-recovery (log only) ─────────────────────────────────────────
if [ "$TIER" = "0" ]; then
  log "Tier 0 escalation: $TYPE — $DESCRIPTION"
  echo -e "${GREEN}✓ Tier 0: logged for self-recovery${NC}"
  echo -e "  Action: $AUTO_ACTION"
  exit 0
fi

# ── Post blocker/insight Thought CR ──────────────────────────────────────────
THOUGHT_TYPE="blocker"
[ "$TIER" = "1" ] && THOUGHT_TYPE="blocker"
[ "$TIER" = "2" ] && THOUGHT_TYPE="blocker"
[ "$TIER" = "3" ] && THOUGHT_TYPE="blocker"

THOUGHT_NAME="thought-${AGENT_NAME}-esc-$(date +%s)"
ISSUE_CONTEXT=""
[ -n "$ISSUE" ] && ISSUE_CONTEXT="issue: #$ISSUE"
OPTIONS_CONTEXT=""
[ -n "$OPTIONS" ] && OPTIONS_CONTEXT="options: $OPTIONS"

THOUGHT_CONTENT="ESCALATION [${SEVERITY^^}/${TYPE}] Tier ${TIER}
${ISSUE_CONTEXT}
description: $DESCRIPTION
${OPTIONS_CONTEXT}
auto-action: $AUTO_ACTION
escalation-id: $ESCALATION_ID
timestamp: $TIMESTAMP"

kubectl apply -f - <<EOF 2>/dev/null && \
  log "Posted blocker Thought CR: $THOUGHT_NAME" || \
  log "WARNING: Failed to post Thought CR"
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: ${THOUGHT_NAME}
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  taskRef: "${TASK_CR_NAME:-}"
  thoughtType: "${THOUGHT_TYPE}"
  confidence: 9
  topic: "escalation-${TYPE}"
  content: |
$(echo "$THOUGHT_CONTENT" | sed 's/^/    /')
EOF

# ── Record escalation in coordinator-state ────────────────────────────────────
# Encode description to avoid colon/pipe conflicts
DESC_ENCODED=$(echo "$DESCRIPTION" | sed 's/:/\%3A/g; s/|/\%7C/g' | cut -c1-120)
ISSUE_FIELD="${ISSUE:-none}"
NEW_ENTRY="${SEVERITY}:${TYPE}:${AGENT_NAME}:${ISSUE_FIELD}:${TIMESTAMP}:${DESC_ENCODED}"

# Read current escalations, append new entry (keep last 20)
CURRENT_ESC=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.escalations}' 2>/dev/null || echo "")

if [ -n "$CURRENT_ESC" ]; then
  # Count entries (pipe-separated), keep last 19 + append new
  ENTRY_COUNT=$(echo "$CURRENT_ESC" | tr -cd '|' | wc -c)
  if [ "$ENTRY_COUNT" -ge 19 ]; then
    # Drop the oldest entry
    CURRENT_ESC=$(echo "$CURRENT_ESC" | cut -d'|' -f2-)
  fi
  NEW_ESC="${CURRENT_ESC}|${NEW_ENTRY}"
else
  NEW_ESC="$NEW_ENTRY"
fi

kubectl patch configmap coordinator-state -n "$NAMESPACE" \
  --type=merge -p "{\"data\":{\"escalations\":\"${NEW_ESC}\"}}" 2>/dev/null && \
  log "Recorded escalation in coordinator-state" || \
  log "WARNING: Failed to update coordinator-state"

# ── Tier 1: Coordinator escalation ───────────────────────────────────────────
tier1_action() {
  echo ""
  echo -e "${CYAN}${BOLD}▶ Tier 1: Coordinator Escalation${NC}"

  case "$TYPE" in
    blocked)
      echo "  → Releasing task back to coordinator queue for reassignment"
      if [ -n "$ISSUE" ]; then
        # Remove from activeAssignments so coordinator re-queues it
        CURRENT_ASSIGNMENTS=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
          -o jsonpath='{.data.activeAssignments}' 2>/dev/null || echo "")
        if [ -n "$CURRENT_ASSIGNMENTS" ]; then
          NEW_ASSIGNMENTS=$(echo "$CURRENT_ASSIGNMENTS" | \
            tr ',' '\n' | grep -v "^${AGENT_NAME}:${ISSUE}$" | \
            tr '\n' ',' | sed 's/,$//')
          kubectl patch configmap coordinator-state -n "$NAMESPACE" \
            --type=merge -p "{\"data\":{\"activeAssignments\":\"${NEW_ASSIGNMENTS}\"}}" 2>/dev/null && \
            echo -e "  ${GREEN}✓${NC} Released assignment #$ISSUE from coordinator" || \
            echo -e "  ${YELLOW}⚠${NC} Failed to release assignment (coordinator cleanup will handle it)"
        fi
      fi
      ;;
    conflict)
      echo "  → Conflict detected: coordinator will spawn fresh worker on current main"
      # Post a message to coordinator about the conflict
      kubectl apply -f - <<EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Message
metadata:
  name: msg-${AGENT_NAME}-conflict-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  from: "${AGENT_NAME}"
  to: "broadcast"
  thread: "${TASK_CR_NAME:-escalation}"
  body: |
    CONFLICT ESCALATION: ${AGENT_NAME} hit merge conflict on issue #${ISSUE:-unknown}
    Description: $DESCRIPTION
    Action needed: spawn fresh worker to rebase on current main
    Escalation-ID: $ESCALATION_ID
EOF
      echo -e "  ${GREEN}✓${NC} Broadcast conflict message to coordinator"
      ;;
    failed)
      echo "  → Unrecoverable error: marking task for re-queue with fresh context"
      ;;
    retry)
      echo "  → Transient failure: re-queuing task after delay"
      ;;
  esac

  echo -e "  ${GREEN}✓${NC} Tier 1 actions complete"
}

# ── Tier 2: God-delegate escalation ──────────────────────────────────────────
tier2_action() {
  echo ""
  echo -e "${YELLOW}${BOLD}▶ Tier 2: God-Delegate Escalation${NC}"

  # Post a decision thought for god-delegate to pick up
  DECISION_THOUGHT_NAME="thought-${AGENT_NAME}-decision-$(date +%s)"
  OPTIONS_BLOCK=""
  if [ -n "$OPTIONS" ]; then
    OPTIONS_BLOCK="options: $(echo "$OPTIONS" | tr ',' '\n' | sed 's/^/  - /')"
  fi

  kubectl apply -f - <<EOF 2>/dev/null && \
    echo -e "  ${GREEN}✓${NC} Posted decision request for god-delegate" || \
    echo -e "  ${YELLOW}⚠${NC} Failed to post decision request"
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: ${DECISION_THOUGHT_NAME}
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  taskRef: "${TASK_CR_NAME:-}"
  thoughtType: "blocker"
  confidence: 9
  topic: "decision-needed"
  content: |
    DECISION NEEDED [${SEVERITY^^}]: $DESCRIPTION
    issue: ${ISSUE:-none}
    agent: $AGENT_NAME
    ${OPTIONS_BLOCK}
    escalation-id: $ESCALATION_ID
    timestamp: $TIMESTAMP
    
    This decision is above the agent's authority to make unilaterally.
    God-delegate: please review and post directive or create governance vote.
EOF

  # If issue number provided, add comment
  if [ -n "$ISSUE" ] && command -v gh &>/dev/null; then
    gh issue comment "$ISSUE" --repo "$REPO" \
      --body "**ESCALATION [${SEVERITY^^}/${TYPE}]** — agent \`${AGENT_NAME}\` needs decision

Problem: $DESCRIPTION
${OPTIONS:+Options: \`$OPTIONS\`}

Escalation-ID: \`$ESCALATION_ID\`
Tier: 2 (god-delegate review needed)" 2>/dev/null && \
      echo -e "  ${GREEN}✓${NC} Posted comment on issue #$ISSUE" || \
      echo -e "  ${YELLOW}⚠${NC} Failed to comment on issue (gh CLI error)"
  fi

  echo -e "  ${GREEN}✓${NC} Tier 2 actions complete"
  echo -e "  ${YELLOW}ℹ${NC}  God-delegate will review at next cycle (~20min)"
}

# ── Tier 3: Human escalation ─────────────────────────────────────────────────
tier3_action() {
  echo ""
  echo -e "${RED}${BOLD}▶ Tier 3: IMMEDIATE HUMAN ESCALATION${NC}"

  # For proliferation: activate kill switch immediately
  if [ "$TYPE" = "proliferation" ]; then
    echo ""
    echo -e "  ${RED}${BOLD}PROLIFERATION DETECTED — activating kill switch${NC}"
    kubectl create configmap agentex-killswitch -n "$NAMESPACE" \
      --from-literal=enabled=true \
      --from-literal=reason="Proliferation detected by $AGENT_NAME: $DESCRIPTION" \
      --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null && \
      echo -e "  ${RED}✓${NC} KILL SWITCH ACTIVATED — all spawning blocked" || \
      echo -e "  ${RED}✗${NC} Failed to activate kill switch — manual intervention required"
    echo ""
  fi

  # Label issue needs-human
  if [ -n "$ISSUE" ] && command -v gh &>/dev/null; then
    gh issue edit "$ISSUE" --repo "$REPO" \
      --add-label "needs-human" 2>/dev/null && \
      echo -e "  ${RED}✓${NC} Labeled issue #$ISSUE with 'needs-human'" || \
      echo -e "  ${YELLOW}⚠${NC} Failed to add needs-human label (may not exist yet)"

    gh issue comment "$ISSUE" --repo "$REPO" \
      --body "## 🔴 CRITICAL ESCALATION — Human Attention Required

**Severity:** ${SEVERITY^^}
**Type:** ${TYPE}
**Agent:** \`${AGENT_NAME}\`
**Timestamp:** ${TIMESTAMP}

**Problem:** $DESCRIPTION
${OPTIONS:+**Options:** \`$OPTIONS\`}

**Escalation-ID:** \`$ESCALATION_ID\`
**Tier:** 3 (immediate human attention needed)

The agentex coordinator and god-delegate cannot resolve this automatically.
$([ "$TYPE" = "security" ] && echo "⚠️ **SECURITY ISSUE** — review immediately")
$([ "$TYPE" = "proliferation" ] && echo "🛑 **KILL SWITCH ACTIVATED** — all agent spawning is blocked")" 2>/dev/null && \
      echo -e "  ${RED}✓${NC} Posted CRITICAL comment on issue #$ISSUE" || \
      echo -e "  ${YELLOW}⚠${NC} Failed to comment on issue"
  else
    # No issue number — create a new one for tracking
    if command -v gh &>/dev/null; then
      NEW_ISSUE_BODY="## 🔴 CRITICAL ESCALATION — Human Attention Required

**Severity:** ${SEVERITY^^}
**Type:** ${TYPE}
**Agent:** \`${AGENT_NAME}\`
**Timestamp:** ${TIMESTAMP}

**Problem:** $DESCRIPTION
${OPTIONS:+**Options:** \`$OPTIONS\`}

**Escalation-ID:** \`$ESCALATION_ID\`

This issue was automatically created by the escalation protocol.
$([ "$TYPE" = "security" ] && echo "⚠️ **SECURITY ISSUE** — review immediately")
$([ "$TYPE" = "proliferation" ] && echo "🛑 **KILL SWITCH ACTIVATED** — all agent spawning is blocked")"

      NEW_ISSUE_NUM=$(gh issue create --repo "$REPO" \
        --title "CRITICAL: ${TYPE} escalation from $AGENT_NAME" \
        --body "$NEW_ISSUE_BODY" \
        --label "needs-human" \
        --json number -q '.number' 2>/dev/null || echo "")
      if [ -n "$NEW_ISSUE_NUM" ]; then
        echo -e "  ${RED}✓${NC} Created issue #$NEW_ISSUE_NUM for tracking"
      else
        echo -e "  ${YELLOW}⚠${NC} Failed to create tracking issue"
      fi
    fi
  fi

  # Record S3 critical event
  CRITICAL_EVENT="{\"id\":\"${ESCALATION_ID}\",\"severity\":\"${SEVERITY}\",\"type\":\"${TYPE}\",\"agent\":\"${AGENT_NAME}\",\"issue\":\"${ISSUE:-none}\",\"description\":\"$(echo "$DESCRIPTION" | sed 's/"/\\"/g')\",\"timestamp\":\"${TIMESTAMP}\"}"
  echo "$CRITICAL_EVENT" | \
    aws s3 cp - "s3://${S3_BUCKET}/escalations/${ESCALATION_ID}.json" \
    --content-type application/json 2>/dev/null && \
    echo -e "  ${RED}✓${NC} Critical event recorded to S3: s3://${S3_BUCKET}/escalations/${ESCALATION_ID}.json" || \
    echo -e "  ${YELLOW}⚠${NC} Failed to write to S3 (non-fatal)"

  echo ""
  echo -e "  ${RED}${BOLD}⚠ HUMAN ACTION REQUIRED — system cannot self-heal this ${NC}"
  echo -e "  ${RED}${BOLD}  Check the dashboard and GitHub issues immediately${NC}"
  echo ""
  echo -e "  ${CYAN}Recovery commands:${NC}"
  echo "    kubectl get jobs -n agentex | grep Running | wc -l"
  echo "    kubectl get configmap agentex-killswitch -n agentex -o jsonpath='{.data.enabled}'"
  [ "$TYPE" = "security" ] && echo "    gh issue list --repo $REPO --label needs-human"
  echo ""
  echo -e "  ${GREEN}✓${NC} Tier 3 actions complete"
}

# ── Execute tier actions ──────────────────────────────────────────────────────
case "$TIER" in
  1) tier1_action ;;
  2) tier1_action; tier2_action ;;
  3) tier1_action; tier2_action; tier3_action ;;
esac

# ── Write escalation exit state ───────────────────────────────────────────────
# Structured exit state (integrates with session/state separation #1833)
EXIT_STATE_FILE="/tmp/agentex-escalation-state"
cat > "$EXIT_STATE_FILE" <<EOF
{
  "escalationId": "${ESCALATION_ID}",
  "status": "escalated",
  "severity": "${SEVERITY}",
  "type": "${TYPE}",
  "tier": ${TIER},
  "issue": "${ISSUE:-}",
  "description": "$(echo "$DESCRIPTION" | sed 's/"/\\"/g')",
  "options": "${OPTIONS:-}",
  "agent": "${AGENT_NAME}",
  "autoAction": "${AUTO_ACTION}",
  "timestamp": "${TIMESTAMP}",
  "workPreserved": true
}
EOF
log "Escalation state written to $EXIT_STATE_FILE"
echo -e "${GREEN}✓${NC} Escalation state written to $EXIT_STATE_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Escalation Summary:${NC}"
echo -e "  ID:       $ESCALATION_ID"
echo -e "  Severity: $SEVERITY → Tier $TIER"
echo -e "  Type:     $TYPE"
echo -e "  Action:   $AUTO_ACTION"
echo ""
echo -e "${GREEN}${BOLD}✓ Escalation complete.${NC}"
echo ""

exit 0
