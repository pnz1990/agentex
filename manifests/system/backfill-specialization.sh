#!/usr/bin/env bash
# backfill-specialization.sh — One-time backfill of specializationLabelCounts
# for agents with empty specialization data.
#
# Issue: #1305 — 864+ agent identity files have empty specializationLabelCounts{}
# Root cause: update_specialization() was added recently; all older agents never had it called.
# Additionally: GitHub API rate limiting (issue #1268) and WORKED_ISSUE=0 race (#1252)
# caused many recent agents to also miss calling update_specialization().
#
# Approach (3-tier data sourcing):
#   Tier 1: Agent planning states (S3) — exact issue numbers per agent
#   Tier 2: Coordinator-state issueLabels cache — label data per issue
#   Tier 3: PR branch timestamp matching — heuristic attribution of issues to agents
#           by matching PR creation times to the agent active at that time.
#           Uses claimedAt from identity files (not agent name timestamp) for accuracy
#           since agents can have hours of delay between job creation and execution.
#           Includes worker, architect, AND planner agents.
#
# Usage:
#   ./backfill-specialization.sh [--dry-run] [--limit N] [--min-prs N]
#
# Options:
#   --dry-run     Show what would be updated, don't write to S3
#   --limit N     Process at most N agents (default: all)
#   --min-prs N   Only backfill agents with at least N prsMerged (default: 1)
#   --tier1-only  Only use planning state data (exact, no heuristics)
#   --verbose     Show detailed per-agent processing output
#
# Requirements:
#   - aws CLI with S3 access to s3://agentex-thoughts/
#   - gh CLI authenticated to pnz1990/agentex
#   - jq installed
#
# Idempotent: agents with existing specializationLabelCounts are skipped.

set -euo pipefail

REPO="${REPO:-pnz1990/agentex}"
S3_BUCKET="${S3_BUCKET:-agentex-thoughts}"
DRY_RUN=false
LIMIT=0
MIN_PRS=1
TIER1_ONLY=false
VERBOSE=false
WORK_DIR="/tmp/specialization-backfill-$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() { [[ "$VERBOSE" == "true" ]] && echo "[$(date -u +%H:%M:%S)] $*" || true; }
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $*" || true; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --min-prs) MIN_PRS="$2"; shift 2 ;;
    --tier1-only) TIER1_ONLY=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ "$DRY_RUN" == "true" ]] && warn "DRY RUN MODE — no S3 writes will be made"
[[ "$TIER1_ONLY" == "true" ]] && info "TIER 1 ONLY — using only planning state data (no heuristics)"

mkdir -p "$WORK_DIR/identities" "$WORK_DIR/planning"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

###############################################################################
# STEP 1: Sync all identity files from S3
###############################################################################
info "Step 1: Downloading identity files from s3://${S3_BUCKET}/identities/ ..."
aws s3 sync "s3://${S3_BUCKET}/identities/" "$WORK_DIR/identities/" \
  --quiet 2>/dev/null || {
  err "Failed to sync identity files from S3"
  exit 1
}
TOTAL_IDENTITIES=$(ls "$WORK_DIR/identities/"*.json 2>/dev/null | wc -l)
info "Downloaded $TOTAL_IDENTITIES identity files"

# Count agents that need backfill (sampling approach to avoid huge jq slurp)
NEED_BACKFILL=0
for f in "$WORK_DIR/identities/"*.json; do
  [[ -f "$f" ]] || continue
  result=$(jq -r --argjson min_prs "$MIN_PRS" \
    'if (.stats.prsMerged // 0) >= $min_prs and ((.specializationLabelCounts // {}) | length) == 0 then "1" else "0" end' \
    "$f" 2>/dev/null || echo "0")
  [[ "$result" == "1" ]] && NEED_BACKFILL=$((NEED_BACKFILL + 1)) || true
done
info "Agents needing backfill (prsMerged>=$MIN_PRS, empty labelCounts): $NEED_BACKFILL"

###############################################################################
# STEP 2: Sync planning state files (Tier 1 data source)
###############################################################################
info "Step 2: Downloading planning states from s3://${S3_BUCKET}/planning-state/ ..."
aws s3 sync "s3://${S3_BUCKET}/planning-state/" "$WORK_DIR/planning/" \
  --quiet 2>/dev/null || warn "Could not sync planning states (non-fatal)"

# Also sync plans/ directory (older naming)
aws s3 sync "s3://${S3_BUCKET}/plans/" "$WORK_DIR/planning/" \
  --quiet 2>/dev/null || true

PLAN_COUNT=$(find "$WORK_DIR/planning" -name "*.json" 2>/dev/null | wc -l)
info "Downloaded $PLAN_COUNT planning state files"

###############################################################################
# STEP 3: Build issue->labels cache from GitHub API
###############################################################################
info "Step 3: Building issue label cache from GitHub API..."
ISSUE_LABELS_FILE="$WORK_DIR/issue-labels.json"
# Fetch all issues with their labels (paginated via gh CLI)
gh issue list --repo "$REPO" --state all --limit 1500 \
  --json number,labels 2>/dev/null | \
  jq -c 'map({(.number | tostring): (.labels | map(.name) | join(","))}) | add // {}' \
  > "$ISSUE_LABELS_FILE" 2>/dev/null || echo '{}' > "$ISSUE_LABELS_FILE"
CACHED_ISSUES=$(jq 'keys | length' "$ISSUE_LABELS_FILE")
info "Cached labels for $CACHED_ISSUES issues"

###############################################################################
# STEP 4: Build agent->issues mapping from planning states (Tier 1)
###############################################################################
info "Step 4: Building agent->issue mapping from planning states (Tier 1)..."
AGENT_ISSUE_FILE="$WORK_DIR/agent-issues.json"
echo '{}' > "$AGENT_ISSUE_FILE"
TIER1_COUNT=0

find "$WORK_DIR/planning" -name "*.json" 2>/dev/null | while read -r f; do
  agent=$(jq -r '.agent // ""' "$f" 2>/dev/null)
  my_work=$(jq -r '.myWork // ""' "$f" 2>/dev/null)
  n1=$(jq -r '.n1Priority // ""' "$f" 2>/dev/null)
  [[ -z "$agent" ]] && continue
  
  # Extract issue numbers from myWork and n1Priority fields
  all_text="$my_work $n1"
  issues=$(echo "$all_text" | grep -oE '#[0-9]+' | tr -d '#' | sort -un | tr '\n' ',' | sed 's/,$//')
  
  if [[ -n "$issues" ]]; then
    current=$(cat "$AGENT_ISSUE_FILE")
    echo "$current" | jq \
      --arg agent "$agent" \
      --arg issues "$issues" \
      '.[$agent] = $issues' > "${AGENT_ISSUE_FILE}.tmp" && \
      mv "${AGENT_ISSUE_FILE}.tmp" "$AGENT_ISSUE_FILE"
    debug "Tier1 mapped $agent → issues: $issues"
  fi
done

TIER1_AGENTS=$(jq 'keys | length' "$AGENT_ISSUE_FILE")
info "Tier 1 data: found planning data for $TIER1_AGENTS agents"

###############################################################################
# STEP 5: Build PR timestamp -> issue mapping for Tier 3 heuristic
###############################################################################
# Initialize Tier 3 files (always, so Step 6 can safely reference them)
PR_TIMESTAMP_FILE="$WORK_DIR/pr-timestamps.json"
PR_AGENT_FILE="$WORK_DIR/pr-agent-map.json"
AGENT_TS_FILE="$WORK_DIR/agent-timestamps.tsv"
echo '[]' > "$PR_TIMESTAMP_FILE"
echo '{}' > "$PR_AGENT_FILE"
touch "$AGENT_TS_FILE"

if [[ "$TIER1_ONLY" == "false" ]]; then
  info "Step 5: Building PR timestamp -> issue mapping for heuristic attribution..."
  
  # Get all merged PRs with issue-N branches
  gh pr list --repo "$REPO" --state merged --limit 500 \
    --json number,headRefName,createdAt,mergedAt 2>/dev/null | \
    jq -c '[.[] | select(.headRefName | startswith("issue-")) | {
      pr: .number,
      branch: .headRefName,
      createdAt: .createdAt,
      mergedAt: .mergedAt,
      issueNum: (.headRefName | capture("issue-(?<n>[0-9]+)").n // "")
    } | select(.issueNum != "")]' \
    > "$PR_TIMESTAMP_FILE" 2>/dev/null || echo '[]' > "$PR_TIMESTAMP_FILE"
  
  PR_COUNT=$(jq 'length' "$PR_TIMESTAMP_FILE")
  info "Found $PR_COUNT merged PRs with issue-N branches"
  
  # Build an ordered list of (agent_name, unix_timestamp, role)
  # Use claimedAt from identity files (more accurate than name timestamp,
  # which reflects job *creation* time and can be hours before actual execution).
  info "Building agent timestamp index (using claimedAt for accuracy)..."
  ls "$WORK_DIR/identities/"*.json | while read -r f; do
    agent=$(basename "$f" .json)
    
    # Read claimedAt from the identity file (actual execution start time)
    claimed_at=$(jq -r '.claimedAt // ""' "$f" 2>/dev/null || echo "")
    [[ -z "$claimed_at" ]] && continue
    
    ts=$(date -d "$claimed_at" +%s 2>/dev/null || echo "0")
    [[ "$ts" -eq 0 || "$ts" -lt 1000000000 ]] && continue
    
    # Include workers, architects, AND planners (planners also open PRs)
    case "$agent" in
      worker-*) role="worker" ;;
      architect-*) role="architect" ;;
      planner-*) role="planner" ;;
      *) continue ;;  # skip other roles (seed, god-delegate, etc.)
    esac
    
    printf "%s\t%s\t%s\n" "$ts" "$agent" "$role"
  done | sort -n > "$AGENT_TS_FILE"
  
  INDEXED_AGENTS=$(wc -l < "$AGENT_TS_FILE" || echo "0")
  info "Indexed $INDEXED_AGENTS agents by claimedAt timestamp"
else
  info "Step 5: Skipping PR timestamp heuristics (--tier1-only mode)"
fi

###############################################################################
# Helper: map issue number to labels
###############################################################################
get_labels_for_issue() {
  local issue_num="$1"
  jq -r --arg issue "$issue_num" '.[$issue] // ""' "$ISSUE_LABELS_FILE" 2>/dev/null
}

###############################################################################
# Helper: map agent->labels via PR timestamp heuristic (Tier 3)
###############################################################################
find_agent_for_pr() {
  local pr_created_at="$1"  # ISO 8601 format
  local pr_ts
  
  # Convert ISO 8601 to Unix timestamp
  pr_ts=$(date -d "$pr_created_at" +%s 2>/dev/null || echo "0")
  [[ "$pr_ts" -eq 0 ]] && return 1
  
  # Find the agent with the closest claimedAt timestamp BEFORE the PR creation
  # (within a 4-hour window to account for long-running agents)
  # NOTE: claimedAt is now used as the timestamp (not agent name timestamp),
  # so the window can be wider to handle agents that take hours to run.
  local max_age_seconds=14400  # 4 hours
  local min_ts=$(( pr_ts - max_age_seconds ))
  
  awk -v target="$pr_ts" -v min_ts="$min_ts" \
    'BEGIN { best_ts=0; best_agent=""; best_role="" }
     {
       ts=$1; agent=$2; role=$3
       if (ts >= min_ts && ts <= target) {
         if (ts > best_ts) {
           best_ts = ts
           best_agent = agent
           best_role = role
         }
       }
     }
     END { if (best_agent != "") print best_agent }' \
    "$AGENT_TS_FILE" 2>/dev/null
}

###############################################################################
# Build Tier 3: PR timestamp -> agent mappings
###############################################################################
if [[ "$TIER1_ONLY" == "false" ]]; then
  info "Building Tier 3 PR->agent heuristic mappings..."
  # Initialize PR->agent map
  
  # Process each PR and find the best matching agent
  jq -c '.[]' "$PR_TIMESTAMP_FILE" 2>/dev/null | while read -r pr_entry; do
    issue_num=$(echo "$pr_entry" | jq -r '.issueNum')
    created_at=$(echo "$pr_entry" | jq -r '.createdAt')
    pr_num=$(echo "$pr_entry" | jq -r '.pr')
    
    [[ -z "$issue_num" ]] && continue
    
    # Find agent closest to this PR creation time
    matched_agent=$(find_agent_for_pr "$created_at" || echo "")
    [[ -z "$matched_agent" ]] && continue
    
    debug "Tier3 mapped PR #$pr_num (issue #$issue_num, $created_at) → $matched_agent"
    
    # Add issue to agent's issue list
    current=$(cat "$PR_AGENT_FILE")
    existing=$(echo "$current" | jq -r --arg agent "$matched_agent" '.[$agent] // ""')
    
    if [[ -z "$existing" ]]; then
      new_issues="$issue_num"
    else
      new_issues="${existing},${issue_num}"
    fi
    
    echo "$current" | jq \
      --arg agent "$matched_agent" \
      --arg issues "$new_issues" \
      '.[$agent] = $issues' > "${PR_AGENT_FILE}.tmp" && \
      mv "${PR_AGENT_FILE}.tmp" "$PR_AGENT_FILE"
  done
  
  TIER3_AGENTS=$(jq 'keys | length' "$PR_AGENT_FILE")
  info "Tier 3 heuristic: mapped $TIER3_AGENTS agents via PR timestamps"
fi

###############################################################################
# Helper: convert label list to specializationLabelCounts JSON
###############################################################################
build_label_counts() {
  local issues_csv="$1"  # comma-separated issue numbers
  local label_counts='{}'
  
  IFS=',' read -ra issue_array <<< "$issues_csv"
  for issue_num in "${issue_array[@]}"; do
    issue_num=$(echo "$issue_num" | tr -d ' ')
    [[ -z "$issue_num" ]] && continue
    
    labels=$(get_labels_for_issue "$issue_num")
    [[ -z "$labels" ]] && continue
    
    IFS=',' read -ra label_array <<< "$labels"
    for label in "${label_array[@]}"; do
      label=$(echo "$label" | tr -d ' ')
      [[ -z "$label" ]] && continue
      label_counts=$(echo "$label_counts" | jq \
        --arg lbl "$label" \
        '.[$lbl] = (.[$lbl] // 0) + 1' 2>/dev/null || echo "$label_counts")
    done
  done
  
  echo "$label_counts"
}

###############################################################################
# Helper: determine specialization from label counts
###############################################################################
determine_specialization() {
  local label_counts="$1"
  local threshold="${2:-2}"  # require at least N instances of a label
  
  local top_label
  top_label=$(echo "$label_counts" | jq -r \
    --argjson threshold "$threshold" \
    'to_entries | sort_by(-.value) | .[0] |
     select(.value >= $threshold) | .key // ""' 2>/dev/null || echo "")
  
  [[ -z "$top_label" ]] && { echo ""; return; }
  
  case "$top_label" in
    collective-intelligence|debate|governance) echo "governance-specialist" ;;
    coordinator|self-improvement) echo "platform-specialist" ;;
    security) echo "security-specialist" ;;
    identity|memory) echo "memory-specialist" ;;
    bug) echo "debugger" ;;
    *) echo "${top_label}-specialist" ;;
  esac
}

###############################################################################
# STEP 6: Process each identity file
###############################################################################
info "Step 6: Processing identity files..."
PROCESSED=0
UPDATED=0
UPDATED_TIER1=0
UPDATED_TIER3=0
SKIPPED_HAS_DATA=0
SKIPPED_LOW_PRS=0
SKIPPED_NO_DATA=0
ERRORS=0

for identity_file in "$WORK_DIR/identities/"*.json; do
  [[ -f "$identity_file" ]] || continue
  
  agent_name=$(jq -r '.agentName // ""' "$identity_file" 2>/dev/null || echo "")
  [[ -z "$agent_name" ]] && continue
  
  # Get existing specialization data
  label_count=$(jq -r '.specializationLabelCounts // {} | length' "$identity_file" 2>/dev/null || echo "0")
  prs_merged=$(jq -r '.stats.prsMerged // 0' "$identity_file" 2>/dev/null || echo "0")
  
  # Skip agents that already have specialization data
  if [[ "$label_count" -gt 0 ]]; then
    SKIPPED_HAS_DATA=$((SKIPPED_HAS_DATA + 1))
    continue
  fi
  
  # Skip agents with too few PRs (likely didn't work on issues)
  if [[ "$prs_merged" -lt "$MIN_PRS" ]]; then
    SKIPPED_LOW_PRS=$((SKIPPED_LOW_PRS + 1))
    continue
  fi
  
  # Limit check (only applied to agents we'd actually process)
  if [[ "$LIMIT" -gt 0 ]] && [[ "$PROCESSED" -ge "$LIMIT" ]]; then
    info "Reached limit of $LIMIT agents, stopping"
    break
  fi
  
  PROCESSED=$((PROCESSED + 1))
  
  # Determine data source tier
  agent_issues=""
  tier_used=0
  
  # Tier 1: Planning state data (most accurate)
  tier1_issues=$(jq -r --arg agent "$agent_name" '.[$agent] // ""' "$AGENT_ISSUE_FILE" 2>/dev/null)
  if [[ -n "$tier1_issues" ]]; then
    agent_issues="$tier1_issues"
    tier_used=1
    debug "Using Tier 1 data for $agent_name: issues=$agent_issues"
  fi
  
  # Tier 3: PR timestamp heuristic (only if Tier 1 not available and not tier1-only mode)
  if [[ -z "$agent_issues" && "$TIER1_ONLY" == "false" ]]; then
    tier3_issues=$(jq -r --arg agent "$agent_name" '.[$agent] // ""' "$PR_AGENT_FILE" 2>/dev/null)
    if [[ -n "$tier3_issues" ]]; then
      agent_issues="$tier3_issues"
      tier_used=3
      debug "Using Tier 3 heuristic for $agent_name: issues=$agent_issues"
    fi
  fi
  
  if [[ -z "$agent_issues" ]]; then
    log "No data available for $agent_name (${prs_merged} PRs)"
    SKIPPED_NO_DATA=$((SKIPPED_NO_DATA + 1))
    ((PROCESSED--)) || true
    continue
  fi
  
  # Build label counts from discovered issues
  new_label_counts=$(build_label_counts "$agent_issues")
  new_count=$(echo "$new_label_counts" | jq 'length' 2>/dev/null || echo "0")
  
  if [[ "$new_count" -eq 0 ]]; then
    log "No labeled issues found for $agent_name (issues: $agent_issues)"
    SKIPPED_NO_DATA=$((SKIPPED_NO_DATA + 1))
    ((PROCESSED--)) || true
    continue
  fi
  
  # Determine specialization (threshold=1 for backfill, since each agent worked on ~1 issue)
  new_specialization=$(determine_specialization "$new_label_counts" 1)
  
  log "Backfilling $agent_name (tier=$tier_used, PRs=$prs_merged): issues=$agent_issues spec='$new_specialization'"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY RUN: $agent_name tier=$tier_used → labelCounts=$(echo "$new_label_counts" | jq -c .) spec='$new_specialization'"
    UPDATED=$((UPDATED + 1))
    [[ "$tier_used" -eq 1 ]] && UPDATED_TIER1=$((UPDATED_TIER1 + 1)) || true
    [[ "$tier_used" -eq 3 ]] && UPDATED_TIER3=$((UPDATED_TIER3 + 1)) || true
    continue
  fi
  
  # Read the identity file and update it
  updated_identity=$(jq \
    --argjson labelCounts "$new_label_counts" \
    --arg spec "$new_specialization" \
    --arg tier "$tier_used" \
    '.specializationLabelCounts = $labelCounts | 
     if ($spec != "") then .specialization = $spec else . end |
     .backfilledAt = (now | todate) |
     .backfillTier = ($tier | tonumber)' \
    "$identity_file" 2>/dev/null)
  
  if [[ -z "$updated_identity" ]]; then
    err "Failed to build updated identity JSON for $agent_name"
    ERRORS=$((ERRORS + 1))
    continue
  fi
  
  # Write back to S3
  if echo "$updated_identity" | aws s3 cp - "s3://${S3_BUCKET}/identities/${agent_name}.json" \
    --content-type application/json 2>/dev/null; then
    UPDATED=$((UPDATED + 1))
    [[ "$tier_used" -eq 1 ]] && UPDATED_TIER1=$((UPDATED_TIER1 + 1)) || true
    [[ "$tier_used" -eq 3 ]] && UPDATED_TIER3=$((UPDATED_TIER3 + 1)) || true
    log "Updated $agent_name → s3://${S3_BUCKET}/identities/${agent_name}.json"
  else
    err "Failed to write $agent_name to S3"
    ERRORS=$((ERRORS + 1))
  fi
done

###############################################################################
# Summary
###############################################################################
echo ""
info "=== Backfill Summary ==="
echo ""
echo "  Total identity files:           $TOTAL_IDENTITIES"
echo "  Needed backfill (min-prs>=$MIN_PRS):  $NEED_BACKFILL"
echo ""
echo "  Skipped - already have data:    $SKIPPED_HAS_DATA"
echo "  Skipped - too few PRs:          $SKIPPED_LOW_PRS"
echo "  Skipped - no data available:    $SKIPPED_NO_DATA"
echo ""
echo "  Updated (total):                $UPDATED"
echo "    via Tier 1 (planning state):  $UPDATED_TIER1"
echo "    via Tier 3 (PR timestamp):    $UPDATED_TIER3"
echo ""
echo "  Errors:                         $ERRORS"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  warn "DRY RUN — no changes were written to S3"
  warn "Re-run without --dry-run to apply changes"
fi

# Print verification command
echo ""
info "Verify results:"
echo "  # Count agents with non-empty specializationLabelCounts:"
echo "  aws s3 sync s3://${S3_BUCKET}/identities/ /tmp/verify-ids/ --quiet &&"
echo "    cat /tmp/verify-ids/*.json | jq -c '.specializationLabelCounts // {}' |"
echo "    grep -vc '^{}$'"
echo ""
echo "  # View a specific agent's updated data:"
echo "  aws s3 cp s3://${S3_BUCKET}/identities/<agent>.json - | jq '{spec: .specialization, counts: .specializationLabelCounts, tier: .backfillTier}'"
echo ""
echo "  # Check routing effectiveness after backfill:"
echo "  kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.specializedAssignments}'"
