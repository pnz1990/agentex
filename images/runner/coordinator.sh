#!/bin/bash
set -uo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# COORDINATOR — The Civilization's Persistent Brain
# ═══════════════════════════════════════════════════════════════════════════
#
# This is a long-running process (not a batch Job) that:
# 1. Maintains the canonical task queue (agents claim tasks from here)
# 2. Tracks which agents are working on what (prevents duplicate work)
# 3. Stores decision history (WHY decisions were made)
# 4. Tallies votes from Thought CRs and ENACTS consensus decisions
# 5. Provides memory across agent generations
#
# The coordinator never exits. It's the civilization's persistent state.
#
# VOTE PROTOCOL (how collective decisions happen):
#   1. Any agent posts: thoughtType=proposal, content includes "#proposal-<topic>"
#      Example: "#proposal-circuit-breaker circuitBreakerLimit=12 reason=observed load"
#   2. Other agents post: thoughtType=vote, content includes "#vote-<topic>"
#      Example: "#vote-circuit-breaker approve circuitBreakerLimit=12"
#      Or:      "#vote-circuit-breaker reject reason=too-low"
#   3. Coordinator counts votes. When 3+ agents vote approve (majority):
#      - Posts a verdict Thought CR
#      - Patches agentex-constitution ConfigMap
#      - Logs the decision with provenance
# ═══════════════════════════════════════════════════════════════════════════

NAMESPACE="${NAMESPACE:-agentex}"
STATE_CM="coordinator-state"
HEARTBEAT_INTERVAL=30  # seconds
VOTE_THRESHOLD=3        # minimum approve votes to enact a decision
BEDROCK_REGION="${BEDROCK_REGION:-us-west-2}"  # For CloudWatch metrics
IDENTITY_BUCKET="${S3_BUCKET:-agentex-thoughts}"  # S3 bucket for agent identities (issue #1113)
SPECIALIZATION_ROUTING_THRESHOLD=2  # min score to trigger specialization-based routing (issue #1113, lowered from 5→3→2 per issue #1145: single label match gives score=3>2)

# Read GitHub repo from constitution for portability (issue #819, #1006)
# This must be set early — before kubectl is configured — because it is used
# in score_issue(), refresh_task_queue(), and sync_constitution_to_git().
# After kubectl is ready (inside the if block below), this is overridden with
# the live constitution value. Until then, use the env var or the fallback.
GITHUB_REPO="${REPO:-pnz1990/agentex}"  # overridden from constitution after kubectl ready

echo "═══════════════════════════════════════════════════════════════════════════"
echo "COORDINATOR STARTING"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Namespace: $NAMESPACE"
echo "State ConfigMap: $STATE_CM"
echo "Vote threshold: $VOTE_THRESHOLD approvals required (default, may be overridden by constitution)"
echo ""

# ── Configure kubectl ────────────────────────────────────────────────────────
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    kubectl config set-cluster local --server=https://kubernetes.default.svc --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    kubectl config set-credentials sa --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    kubectl config set-context local --cluster=local --user=sa --namespace="$NAMESPACE"
    kubectl config use-context local
fi

# ── Read portability constants from constitution (issue #819, #1006) ─────────
# These must be read after kubectl is configured so we can query the ConfigMap.
# Override the pre-init fallback values with live constitution values.
GITHUB_REPO_FROM_CONSTITUTION=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.githubRepo}' 2>/dev/null || echo "")
if [ -n "$GITHUB_REPO_FROM_CONSTITUTION" ]; then
  GITHUB_REPO="$GITHUB_REPO_FROM_CONSTITUTION"
fi
BEDROCK_REGION_FROM_CONSTITUTION=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.awsRegion}' 2>/dev/null || echo "")
if [ -n "$BEDROCK_REGION_FROM_CONSTITUTION" ]; then
  BEDROCK_REGION="$BEDROCK_REGION_FROM_CONSTITUTION"
fi
# Read voteThreshold from constitution (issue #1059, #1063) — governance votes changing
# voteThreshold must take effect without coordinator restart.
VOTE_THRESHOLD_FROM_CONSTITUTION=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.voteThreshold}' 2>/dev/null || echo "")
if [ -n "$VOTE_THRESHOLD_FROM_CONSTITUTION" ] && [[ "$VOTE_THRESHOLD_FROM_CONSTITUTION" =~ ^[0-9]+$ ]]; then
  VOTE_THRESHOLD="$VOTE_THRESHOLD_FROM_CONSTITUTION"
fi
# Read minimumVisionScore from constitution (issue #1063) — allows governance to tune
# the minimum acceptable vision score for agent work quality enforcement.
MINIMUM_VISION_SCORE=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.minimumVisionScore}' 2>/dev/null || echo "5")
if ! [[ "$MINIMUM_VISION_SCORE" =~ ^[0-9]+$ ]]; then
  MINIMUM_VISION_SCORE=5
fi
echo "GitHub repo (from constitution): $GITHUB_REPO"
echo "Bedrock region (from constitution): $BEDROCK_REGION"
echo "Vote threshold (from constitution): $VOTE_THRESHOLD"
echo "Minimum vision score (from constitution): $MINIMUM_VISION_SCORE"

# ── Configure GitHub Authentication (issue #6) ───────────────────────────────
# Read GitHub token from read-only file mount instead of environment variable
# Issue #1447: gh auth login --with-token uses GraphQL to validate the token.
# When the GitHub GraphQL rate limit is exceeded at pod startup, auth fails even
# though the token itself is valid. Fix: retry with exponential backoff.
#
# Issue #1564: gh auth login uses GraphQL only for token validation. When GraphQL
# is rate-limited but REST API works fine, the coordinator should NOT sleep 90s.
# Fix: after auth login fails, immediately test REST API. If REST works, proceed
# without delay — the coordinator can serve requests using REST-based gh commands.
# REST API has a separate (higher) rate limit than GraphQL.
gh_auth_with_retry() {
  local token="$1"
  local max_attempts=3
  local delay=30
  for attempt in $(seq 1 "$max_attempts"); do
    if echo "$token" | gh auth login --with-token 2>/dev/null; then
      echo "gh CLI authenticated successfully (attempt $attempt)"
      return 0
    fi
    # Issue #1564: Before sleeping, check if REST API works even though GraphQL failed.
    # gh api /rate_limit uses REST and works during GraphQL rate limit windows.
    # If REST works, export the token for direct REST usage and return success —
    # no point sleeping 30s+60s when REST-based gh commands work immediately.
    if GITHUB_TOKEN="$token" gh api /rate_limit --hostname github.com &>/dev/null 2>&1; then
      echo "WARNING: gh auth login failed (GraphQL may be rate-limited) but REST API works — proceeding in REST-compatible mode"
      export GITHUB_TOKEN="$token"
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      echo "WARNING: gh auth login failed (attempt $attempt/$max_attempts) — REST API also unavailable, retrying in ${delay}s (GitHub API rate limit may be exceeded)"
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  echo "WARNING: gh auth login failed after $max_attempts attempts - gh commands may not work"
  return 1
}

# Issue #1526: Create liveness probe file BEFORE auth retries.
# gh_auth_with_retry() can sleep up to 30s+60s=90s waiting for GitHub API.
# The liveness probe fires at t=30,60,90s (initialDelay=30, period=30, failureThreshold=3).
# Without this early touch, the pod gets killed by the liveness probe while auth is retrying,
# resulting in a continuous crash loop that prevents the coordinator from ever starting.
touch /tmp/coordinator-alive
touch /tmp/coordinator-ready

# Issue #1581: Early spawn slot reconciliation BEFORE GitHub auth retries.
# When coordinator restarts, spawnSlots retains its stale value (often 0 when all slots were
# used before restart). Auth retry can take up to 90s (3 attempts: 30s + 60s backoff).
# During that window, civilization is frozen — no agents can spawn.
# This inline fix uses raw kubectl (no helper function dependencies) to correct spawnSlots
# BEFORE the auth wait begins. Helper functions (kubectl_with_timeout etc.) are not yet
# defined at this point in script execution, so we use raw kubectl with a short timeout.
echo "[$(date +%H:%M:%S)] Early spawn slot reconciliation (issue #1581, before gh auth)..."
_early_limit=$(kubectl get configmap agentex-constitution -n "${NAMESPACE:-agentex}" \
  -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "6")
[[ "$_early_limit" =~ ^[0-9]+$ ]] || _early_limit=6
_early_active=$(kubectl get jobs -n "${NAMESPACE:-agentex}" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
  2>/dev/null || echo "0")
_early_slots=$(( _early_limit - _early_active ))
[ "$_early_slots" -lt 0 ] && _early_slots=0
if kubectl patch configmap coordinator-state -n "${NAMESPACE:-agentex}" \
  --type=merge -p "{\"data\":{\"spawnSlots\":\"$_early_slots\"}}" 2>/dev/null; then
  echo "[$(date +%H:%M:%S)] Early spawn reconciliation: limit=$_early_limit active=$_early_active slots=$_early_slots (civilization unfrozen)"
else
  echo "[$(date +%H:%M:%S)] WARNING: Early spawn reconciliation failed — coordinator-state may not exist yet (first boot)"
fi
unset _early_limit _early_active _early_slots

if [ -n "${GITHUB_TOKEN_FILE:-}" ] && [ -f "$GITHUB_TOKEN_FILE" ]; then
  export GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
  echo "GitHub token loaded from read-only file mount"
  # Issue #1576: Export GH_TOKEN so gh CLI uses REST API without needing gh auth login.
  # gh CLI reads GH_TOKEN env var for REST API calls, bypassing GraphQL token validation.
  # This ensures gh commands work even when GraphQL rate limit is exceeded.
  export GH_TOKEN="$GITHUB_TOKEN"
  # Authenticate gh CLI with the token (issue #coordinator-gh-auth)
  # gh auth status checks fail even with GITHUB_TOKEN exported - need explicit login
  if command -v gh &>/dev/null; then
    gh_auth_with_retry "$GITHUB_TOKEN" || true
  fi
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "GitHub token loaded from environment variable (legacy)"
  # Issue #1576: Export GH_TOKEN so gh CLI uses REST API without needing gh auth login.
  export GH_TOKEN="$GITHUB_TOKEN"
  # Authenticate gh CLI with the token
  if command -v gh &>/dev/null; then
    gh_auth_with_retry "$GITHUB_TOKEN" || true
  fi
else
  echo "WARNING: No GitHub token available - gh CLI commands will fail"
fi

# ── ensure_state_fields_initialized() (issue #940, #1178) ────────────────────
# Initialize coordinator-state fields that may be missing or null.
# Called at startup AND periodically in the main loop to handle fields added
# after the coordinator was last restarted (issue #1178: hot-initialization).
# Without periodic calls, new fields (e.g. specializedAssignments) are never
# created in long-running coordinators, silently breaking dependent features.
ensure_state_fields_initialized() {
  local silent="${1:-false}"  # set to "true" to suppress output (for periodic calls)

  [ "$silent" = "false" ] && echo "Initializing coordinator-state fields..."

  for field in activeAgents activeAssignments decisionLog; do
    val=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath="{.data.$field}" 2>/dev/null)
    if [ -z "$val" ]; then
      [ "$silent" = "false" ] && echo "  Initializing $field (was empty/null)"
      kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
        -p "{\"data\":{\"$field\":\"\"}}" 2>/dev/null || true
    fi
  done

  # debateStats needs a valid structured value (not just empty string)
  debate_stats=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath='{.data.debateStats}' 2>/dev/null)
  if [ -z "$debate_stats" ]; then
    [ "$silent" = "false" ] && echo "  Initializing debateStats (was empty/null)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"debateStats":"responses=0 threads=0 disagree=0 synthesize=0"}}' 2>/dev/null || true
  fi

  # enactedDecisions needs preservation if exists, initialization if not
  enacted=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath='{.data.enactedDecisions}' 2>/dev/null)
  if [ -z "$enacted" ]; then
    [ "$silent" = "false" ] && echo "  Initializing enactedDecisions (was empty/null)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"enactedDecisions":""}}' 2>/dev/null || true
  else
    # Issue #1427: Migrate old-format enactedDecisions entries to new enacted_topic_<topic> format.
    # PR #1420 (fixes #1398) changed decision_key from "topic_kv_pairs" to "enacted_topic_topic".
    # Old entries without "enacted_topic_" prefix won't be matched by the new dedup check,
    # potentially causing re-enactment of already-decided governance topics.
    # This migration adds enacted_topic_<topic> entries for any topic missing them.
    local new_entries=""
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      # Extract the decision_key field (second word after timestamp)
      local entry_key
      entry_key=$(echo "$entry" | awk '{print $2}')
      [ -z "$entry_key" ] && continue
      # Skip if already in new format (starts with "enacted_topic_")
      [[ "$entry_key" == enacted_topic_* ]] && continue
      # Extract topic from old format: "topic_kv_key=value_..." → "topic"
      # Topics use only hyphens (e.g. "circuit-breaker", "release-v0.1"),
      # while kv_pairs use underscores as separators. So splitting on the FIRST "_"
      # reliably extracts the topic from old-format decision keys.
      local old_topic
      old_topic=$(echo "$entry_key" | cut -d'_' -f1)
      [ -z "$old_topic" ] && continue
      local new_key="enacted_topic_${old_topic}"
      # Only add if not already present in enacted decisions
      if ! echo "$enacted" | grep -qF "$new_key"; then
        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        local new_entry="${ts} ${new_key} approvals=0 migrated-from-legacy-format"
        [ -z "$new_entries" ] && new_entries="$new_entry" || new_entries="${new_entries} | ${new_entry}"
        [ "$silent" = "false" ] && echo "  Migrated enactedDecisions entry: ${old_topic} → ${new_key} (issue #1427)"
      fi
    done <<< "$(echo "$enacted" | tr '|' '\n')"
    if [ -n "$new_entries" ]; then
      local migrated_enacted="${enacted} | ${new_entries}"
      # Sanitize for JSON: escape double quotes, remove newlines
      # Issue #1501: Use printf '%s' instead of echo to avoid appending a trailing newline.
      # echo "$migrated_enacted" appends \n; tr '\n\r' '  ' converts that \n to a space,
      # causing enactedDecisions to end with a trailing space character.
      # This is the same echo+tr pattern fixed in update_state() by PR #1473 (issue #1470).
      local safe_migrated
      safe_migrated=$(printf '%s' "$migrated_enacted" | tr '\n\r' '  ' | tr -s ' ' | sed 's/"/\\"/g')
      kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
        -p "{\"data\":{\"enactedDecisions\":\"$safe_migrated\"}}" 2>/dev/null || true
      [ "$silent" = "false" ] && echo "  enactedDecisions migration complete (issue #1427)"
    fi
  fi

  # Initialize identity-based routing fields (issue #1113)
  for field in specializedAssignments genericAssignments lastSpecializedRouting lastRoutingDecisions; do
    val=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath="{.data.$field}" 2>/dev/null)
    if [ -z "$val" ]; then
      [ "$silent" = "false" ] && echo "  Initializing $field (was empty/null)"
      case "$field" in
        specializedAssignments|genericAssignments)
          kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
            -p "{\"data\":{\"$field\":\"0\"}}" 2>/dev/null || true ;;
        *)
          kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
            -p "{\"data\":{\"$field\":\"\"}}" 2>/dev/null || true ;;
      esac
    fi
  done

  # issueLabels: label cache for claimed issues (issue #1268, PR #1298, issue #1316)
  # Format: "issue:label1,label2|issue2:label3|..."
  issuelabels_val=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath='{.data.issueLabels}' 2>/dev/null)
  if [ -z "$issuelabels_val" ] && ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("issueLabels")' >/dev/null 2>&1; then
    [ "$silent" = "false" ] && echo "  Initializing issueLabels (was absent)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"issueLabels":""}}' 2>/dev/null || true
  fi

  # unresolvedDebates: comma-separated thread IDs for debates needing synthesis (issue #1111)
  unresolved_debates_val=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath='{.data.unresolvedDebates}' 2>/dev/null)
  if [ -z "$unresolved_debates_val" ]; then
    [ "$silent" = "false" ] && echo "  Initializing unresolvedDebates (was empty/null)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"unresolvedDebates":""}}' 2>/dev/null || true
  fi

  # spawnSlots: must be a non-negative integer (issue #1240 — negative value freezes civilization)
  # If missing or non-numeric (includes negative values like "-1"), reset to 0 as a safe floor.
  # reconcile_spawn_slots() (called separately) will correct 0 to the proper ground-truth value
  # based on actual running jobs. We only floor here — full reconciliation happens in the main loop.
  spawn_slots_val=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath='{.data.spawnSlots}' 2>/dev/null)
  if [ -z "$spawn_slots_val" ] || ! [[ "$spawn_slots_val" =~ ^[0-9]+$ ]]; then
    [ "$silent" = "false" ] && echo "  spawnSlots is invalid ('$spawn_slots_val') — flooring to 0; reconcile_spawn_slots will correct to ground truth (issue #1240)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"spawnSlots":"0"}}' 2>/dev/null || true
  fi

  # visionQueue (issue #1219/#1149): semicolon-separated entries voted in by collective governance.
  # Contains both numeric issue numbers and named features (feature:description:ts:proposer format).
  # Separator changed from comma to semicolon in issues #1444/#1455 for consistent parsing.
  # Planners read this BEFORE taskQueue, enabling agent-voted goals to override the standard backlog.
  # visionQueueLog: audit log for all visionQueue additions (semicolon-separated entries).
  for field in visionQueue visionQueueLog; do
    val=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath="{.data.$field}" 2>/dev/null)
    if [ -z "$val" ]; then
      [ "$silent" = "false" ] && echo "  Initializing $field (was empty/null)"
      kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
        -p "{\"data\":{\"$field\":\"\"}}" 2>/dev/null || true
    fi
  done

  # lastTallyTimestamp (issue #1407): tracks when tally_and_enact_votes() last ran.
  # Enables time-based filtering of governance thoughts, preventing O(N) slowdown as
  # Thought CRs accumulate. Initialized to empty (first tally loads full 24h window).
  if ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("lastTallyTimestamp")' >/dev/null 2>&1; then
    [ "$silent" = "false" ] && echo "  Initializing lastTallyTimestamp (was absent)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"lastTallyTimestamp":""}}' 2>/dev/null || true
  fi

  # preClaimTimestamps (issue #1546): semicolon-separated "agent:issue:epoch_seconds" entries
  # tracking when coordinator pre-claimed issues on behalf of workers via
  # route_tasks_by_specialization(). cleanup_stale_assignments() reads this to protect
  # pre-claims within a 120s grace window from being pruned before the worker's Job starts.
  if ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("preClaimTimestamps")' >/dev/null 2>&1; then
    [ "$silent" = "false" ] && echo "  Initializing preClaimTimestamps (was absent)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"preClaimTimestamps":""}}' 2>/dev/null || true
  fi

  # routingCyclesWithZeroSpec (issue #1568): counter tracking consecutive routing cycles where
   # specializedAssignments=0. When it reaches 5, coordinator escalates with a blocker thought
   # AND files a GitHub issue to ensure the regression is visible and self-reported.
   # Reset to 0 when specializedAssignments increments (routing is working).
   # Issue #1731: ALWAYS reset to 0 on coordinator startup. "Consecutive cycles" only makes
   # sense within a single coordinator run — stale counts from prior runs (especially after
   # crash-loops, issue #1727) carry over and cause false-positive escalations when the new
   # coordinator picks up the accumulated count and increments past the threshold immediately.
   # Each coordinator restart is a clean slate for the "consecutive routing failure" counter.
  [ "$silent" = "false" ] && echo "  Resetting routingCyclesWithZeroSpec to 0 on startup (issue #1731)"
  kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
    -p '{"data":{"routingCyclesWithZeroSpec":"0"}}' 2>/dev/null || true

  # chronicleCandidates (issue #1605): semicolon-separated Thought ConfigMap names for
  # agent-proposed chronicle entries. Aggregated by aggregate_chronicle_candidates() every
  # ~3 min (inside track_debate_activity). God-delegate reads this when writing the chronicle.
   if ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("chronicleCandidates")' >/dev/null 2>&1; then
     [ "$silent" = "false" ] && echo "  Initializing chronicleCandidates (was absent)"
     kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
       -p '{"data":{"chronicleCandidates":""}}' 2>/dev/null || true
   fi

  # agentTrustGraph (v0.5, issue #1734/#1756): pipe-separated trust edges from cite_debate_outcome() calls.
  # Format: "citingAgent:citedAgent:count|citingAgent2:citedAgent:count2|..."
  # Records how often each agent has cited another's debate syntheses — a proxy for cross-agent trust.
  # Used by score_agent_for_issue() (issue #1750) to give routing priority to widely-cited agents.
  # Initialize to empty string if absent — cite_debate_outcome() in helpers.sh writes actual entries.
  if ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("agentTrustGraph")' >/dev/null 2>&1; then
    [ "$silent" = "false" ] && echo "  Initializing agentTrustGraph (was absent)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"agentTrustGraph":""}}' 2>/dev/null || true
  fi

   # v05MilestoneStatus (issue #1752): tracks whether v0.5 Emergent Specialization milestone is complete.
  # Set to "completed" by check_v05_milestone() when all 5 success criteria are met.
  # Empty means not yet complete (check will run again next cycle).
  if ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("v05MilestoneStatus")' >/dev/null 2>&1; then
    [ "$silent" = "false" ] && echo "  Initializing v05MilestoneStatus (was absent)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"v05MilestoneStatus":""}}' 2>/dev/null || true
  fi

  # v05CriteriaStatus (issue #1752): human-readable status of last v0.5 criteria check.
  # Updated every 10 min by check_v05_milestone() with current pass/fail counts per criterion.
  if ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("v05CriteriaStatus")' >/dev/null 2>&1; then
    [ "$silent" = "false" ] && echo "  Initializing v05CriteriaStatus (was absent)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"v05CriteriaStatus":""}}' 2>/dev/null || true
  fi

  # v06MilestoneStatus (issue #1789): tracks whether v0.6 Collective Action milestone is complete.
  # Set to "completed" by check_v06_milestone() when all 4 success criteria are met.
  # Empty means not yet complete (check will run again next cycle).
  if ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("v06MilestoneStatus")' >/dev/null 2>&1; then
    [ "$silent" = "false" ] && echo "  Initializing v06MilestoneStatus (was absent)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"v06MilestoneStatus":""}}' 2>/dev/null || true
  fi

  # v06CriteriaStatus (issue #1789): human-readable status of last v0.6 criteria check.
  # Updated every ~10 min by check_v06_milestone() with current pass/fail counts per criterion.
  if ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("v06CriteriaStatus")' >/dev/null 2>&1; then
    [ "$silent" = "false" ] && echo "  Initializing v06CriteriaStatus (was absent)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"v06CriteriaStatus":""}}' 2>/dev/null || true
  fi

  # activeSwarms (issue #1775): pipe-separated active swarm entries for v0.6 swarm observability.
  # Format: "swarm-name:goal-summary:member-count|swarm-name2:goal-summary2:member-count2|..."
  # Written by track_active_swarms() every 5 iterations (~2.5 min).
  # Read by check_v06_milestone() to count live swarm formations and coalition sizes.
  # Also displayed by civilization_status() in helpers.sh for swarm health monitoring (issue #1775).
  if ! kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | jq -e '.data | has("activeSwarms")' >/dev/null 2>&1; then
    [ "$silent" = "false" ] && echo "  Initializing activeSwarms (was absent)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p '{"data":{"activeSwarms":""}}' 2>/dev/null || true
  fi

  [ "$silent" = "false" ] && echo "Coordinator-state initialization complete"

  # Issue #1650: One-time cleanup of stale voteRegistry_* keys for topics already enacted.
  # voteRegistry_* keys accumulate indefinitely (47+ observed) since the previous implementation
  # never deleted them after enaction. Going forward, keys are removed after each verdict.
  # This one-time sweep cleans up keys that accumulated before this fix was deployed.
  local enacted_decisions
  enacted_decisions=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath='{.data.enactedDecisions}' 2>/dev/null || echo "")
  if [ -n "$enacted_decisions" ]; then
    local stale_count=0
    # Get all voteRegistry_* key names
    while IFS= read -r vote_key; do
      [ -z "$vote_key" ] && continue
      local topic="${vote_key#voteRegistry_}"
      # Check if this topic appears in enactedDecisions (topic in decision key format)
      if echo "$enacted_decisions" | grep -q "${topic}"; then
        remove_state "$vote_key" 2>/dev/null && stale_count=$((stale_count + 1)) || true
      fi
    done < <(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null | \
      jq -r '.data | keys[] | select(startswith("voteRegistry_"))' 2>/dev/null || true)
    [ "$stale_count" -gt 0 ] && [ "$silent" = "false" ] && echo "  Issue #1650: Cleaned $stale_count stale voteRegistry keys (enacted topics)"
  fi
}

# Run at startup
ensure_state_fields_initialized "false"

# ── Helper Functions ─────────────────────────────────────────────────────────

# kubectl timeout wrapper (issue #692: prevent 120s hangs during cluster connectivity issues)
# Coordinator is a long-running process that MUST NOT hang indefinitely on kubectl calls.
# Without this wrapper, kubectl uses 120s default timeout, blocking coordinator operations.
kubectl_with_timeout() {
  local timeout_secs="${1:-10}"
  shift
  # Issue #982 (same as #959 in entrypoint.sh): Do NOT use 2>&1 — that mixes
  # stderr into stdout, corrupting JSON output when callers use
  # $(kubectl_with_timeout ...) to capture data and pipe to jq.
  # Stderr is suppressed here; callers that need error context add 2>&1 explicitly.
  timeout "${timeout_secs}s" kubectl "$@" 2>/dev/null
}

# Push CloudWatch metric (issue #587: visibility for collective intelligence)
push_metric() {
    local metric_name="$1"
    local value="$2"
    local unit="${3:-Count}"
    local dimensions="${4:-Component=Coordinator}"
    
    aws cloudwatch put-metric-data \
        --namespace Agentex \
        --metric-name "$metric_name" \
        --value "$value" \
        --unit "$unit" \
        --dimensions "$dimensions" \
        --region "$BEDROCK_REGION" 2>/dev/null || true
}

update_state() {
    local field="$1"
    local value="$2"
    # Issue #1398: Sanitize value to remove newlines and JSON-breaking characters before embedding
    # in JSON. Embedded newlines cause 'invalid character \n in string literal' errors that are
    # swallowed by 2>/dev/null, causing silent failures (e.g., enactedDecisions never updated).
    local safe_value
    # Issue #1470: Use printf instead of echo to avoid appending a trailing newline.
    # echo "$value" always appends \n; tr '\n\r' '  ' converts that \n to a space,
    # causing numeric values like "6" to become "6 " (with trailing space).
    # This broke spawnSlots: "6 " fails the ^[0-9]+$ regex, triggering the
    # ALERT: spawnSlots invalid warning on every coordinator iteration.
    safe_value=$(printf '%s' "$value" | tr '\n\r' '  ' | tr -s ' ' | sed 's/"/\\"/g')
    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" \
        --type=merge -p "{\"data\":{\"$field\":\"$safe_value\"}}" 2>/dev/null || true
}

get_state() {
    local field="$1"
    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    kubectl_with_timeout 10 get configmap "$STATE_CM" -n "$NAMESPACE" \
        -o jsonpath="{.data.$field}" 2>/dev/null || echo ""
}

remove_state() {
    # Issue #1650: Remove a key from coordinator-state ConfigMap to prevent unbounded growth.
    # Uses JSON Patch 'remove' operation — safer than merge-patch null (which leaves a null key).
    local field="$1"
    kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" \
        --type=json -p "[{\"op\":\"remove\",\"path\":\"/data/${field}\"}]" 2>/dev/null || true
}

heartbeat() {
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    update_state "lastHeartbeat" "$timestamp"
    
    # Emit coordinator liveness metric (issue #587)
    push_metric "CoordinatorHeartbeat" 1 "Count"
    
    # Emit coordinator health status metric (issue #731)
    # This allows CloudWatch alarms to detect coordinator unhealthy state
    push_metric "CoordinatorHealthy" 1 "Count"
}

# Post a Thought CR from the coordinator
post_coordinator_thought() {
    local content="$1"
    local thought_type="${2:-insight}"
    local ts
    ts=$(date +%s)
    kubectl apply -f - <<EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-coordinator-${ts}
  namespace: ${NAMESPACE}
spec:
  agentRef: "coordinator"
  taskRef: "coordinator"
  thoughtType: ${thought_type}
  confidence: 9
  content: |
    ${content}
EOF
    echo "[$(date -u +%H:%M:%S)] Posted ${thought_type} thought"
}

# Log a decision with provenance
log_decision() {
    local decision="$1"
    local reason="$2"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local log_entry="${timestamp} ${decision} reason=${reason}"
    local current_log
    current_log=$(get_state "decisionLog")
    if [ -z "$current_log" ]; then
        update_state "decisionLog" "$log_entry"
    else
        update_state "decisionLog" "${current_log} | ${log_entry}"
    fi
    echo "[$(date -u +%H:%M:%S)] Decision logged: $decision"
}

# Vision score priority matrix — maps issue labels to vision alignment scores.
# Higher score = more aligned with the civilization's vision.
# Coordinator uses this to sort the task queue, ensuring agents work on
# the highest-impact issues first rather than picking arbitrarily.
VISION_PRIORITY_LABELS=(
    "collective-intelligence:10"
    "debate:10"
    "governance:9"
    "security:9"
    "identity:8"
    "memory:8"
    "coordinator:7"
    "self-improvement:7"
    "enhancement:5"
    "bug:4"
    "documentation:2"
    "circuit-breaker:1"
    "proliferation:1"
)

# Score an issue by its labels (returns highest matching score, default 5)
score_issue() {
    local issue_number="$1"
    local labels
    labels=$(gh issue view "$issue_number" --repo "${GITHUB_REPO}" \
        --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
    
    local best_score=5
    for entry in "${VISION_PRIORITY_LABELS[@]}"; do
        local label="${entry%%:*}"
        local score="${entry##*:}"
        if echo "$labels" | grep -qi "$label"; then
            [ "$score" -gt "$best_score" ] && best_score="$score"
        fi
    done
    echo "$best_score"
}

# Refresh task queue from open GitHub issues, sorted by vision priority score
refresh_task_queue() {
    echo "[$(date -u +%H:%M:%S)] Refreshing task queue from GitHub (vision-priority sorted)..."

    # Issue #1570: Use REST API instead of GraphQL to avoid rate-limit failures.
    # gh auth status and gh issue list --json both use GraphQL, which is rate-limited
    # separately from the REST API. During high agent activity (7+ concurrent agents),
    # GraphQL exhaustion causes refresh_task_queue() to return early without updating
    # taskQueue, leaving stale closed issues (e.g., #1536) in the queue indefinitely.
    # Fix: use gh api (REST) for both the liveness check and the issues fetch.
    if ! gh api /repos/${GITHUB_REPO}/issues?state=open\&per_page=1 &>/dev/null 2>&1; then
        echo "[$(date -u +%H:%M:%S)] WARNING: GitHub REST API unavailable, skipping queue refresh"
        return 0
    fi

    local issues_json
    issues_json=$(gh api "/repos/${GITHUB_REPO}/issues?state=open&per_page=50" 2>/dev/null) || true

    [ -z "$issues_json" ] && return 0

    # Issue #1384: Fetch open PRs once and build a set of issue numbers already covered.
    # This prevents dispatching agents to re-implement work already in an open PR.
    # We parse "Closes #N" / "Fixes #N" patterns from PR bodies in a single API call.
    local covered_issues=""
    local prs_json
    # Issue #1570: Use REST API (gh api) instead of gh pr list --json (GraphQL) for rate-limit resilience.
    prs_json=$(gh api "/repos/${GITHUB_REPO}/pulls?state=open&per_page=100" 2>/dev/null) || true
    if [ -n "$prs_json" ]; then
        covered_issues=$(echo "$prs_json" | \
            jq -r '.[].body // ""' 2>/dev/null | \
            grep -oiE '(closes|fixes|resolves) #[0-9]+' | \
            grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
        local covered_count
        covered_count=$(echo "$covered_issues" | wc -w | tr -d ' ')
        echo "[$(date -u +%H:%M:%S)] Issue #1384: Found $covered_count issues with open PRs (will skip from queue): ${covered_issues:-none}"

        # Issue #1809: Detect issues with 2+ open PRs and warn via Thought CR.
        # sort -u above deduplicates so we lose count info. Re-extract without -u to count.
        local all_covered_raw
        all_covered_raw=$(echo "$prs_json" | \
            jq -r '.[].body // ""' 2>/dev/null | \
            grep -oiE '(closes|fixes|resolves) #[0-9]+' | \
            grep -oE '[0-9]+' | sort)
        # Find issues appearing 2+ times (duplicate PRs)
        local dup_issues
        dup_issues=$(echo "$all_covered_raw" | uniq -d)
        if [ -n "$dup_issues" ]; then
            local dup_count
            dup_count=$(echo "$dup_issues" | wc -w | tr -d ' ')
            echo "[$(date -u +%H:%M:%S)] Issue #1809: WARNING — $dup_count issue(s) have 2+ open PRs: ${dup_issues//$'\n'/ }"
            # Post a warning Thought CR so planners can identify duplicates to close
            post_coordinator_thought "DUPLICATE PR WARNING (issue #1809): The following issue(s) each have 2+ open PRs, creating duplicate work. Consider closing the older PR for each: ${dup_issues//$'\n'/ }" "insight"
        fi
    fi

    # Build scored list: "score:number"
    local scored_issues=""
    local numbers
    
    # Issue #1442: Accumulate labels for issueLabels cache bulk-write after scoring loop.
    # The coordinator already fetches labels from the bulk gh issue list response (no extra
    # API calls). Pre-populating the cache here means claim_task() and update_specialization()
    # find labels without needing per-issue GitHub API calls — fixing specialization routing
    # under rate-limit conditions (root cause of specializedAssignments=0).
    local new_issue_labels_cache=""

    # Issue #960 fix: Always include unlabeled issues in the queue to prevent starvation.
    # Strategy: Query ALL open issues, then filter out meta-issues only.
    # This ensures queue is never empty when actionable work exists.
    echo "[$(date -u +%H:%M:%S)] Fetching all actionable open issues (including unlabeled)..."
    # Issue #1570: Also filter out pull_request entries — REST /issues endpoint includes PRs.
    # GraphQL gh issue list excludes PRs automatically; REST does not.
    numbers=$(echo "$issues_json" | jq -r '.[] |
        select(.pull_request == null) |
        select(.title | test("\\[GOD-REPORT\\]|\\[GOD-DELEGATE\\]"; "i") | not) |
        .number' 2>/dev/null | head -20)

    for num in $numbers; do
        # Issue #1384: Skip issues that already have an open PR to prevent duplicate work.
        if echo " $covered_issues " | grep -q " $num "; then
            echo "[$(date -u +%H:%M:%S)] Issue #1384: Skipping issue #$num — open PR already exists"
            continue
        fi

        # Score based on labels already fetched (avoid extra API calls)
        local labels
        labels=$(echo "$issues_json" | jq -r --argjson n "$num" '.[] | select(.pull_request == null) | select(.number == $n) | [.labels[].name] | join(",")' 2>/dev/null || echo "")

        # Issue #1442: Accumulate label data for issueLabels cache (only for labeled issues)
        if [ -n "$labels" ]; then
            if [ -z "$new_issue_labels_cache" ]; then
                new_issue_labels_cache="${num}:${labels}"
            else
                new_issue_labels_cache="${new_issue_labels_cache}|${num}:${labels}"
            fi
        fi

        local best_score=5
        for entry in "${VISION_PRIORITY_LABELS[@]}"; do
            local label="${entry%%:*}"
            local score="${entry##*:}"
            if echo "$labels" | grep -qi "$label"; then
                [ "$score" -gt "$best_score" ] && best_score="$score"
            fi
        done
        scored_issues="${scored_issues}${best_score}:${num}\n"
    done

    # Issue #1442: Bulk-write accumulated labels to issueLabels cache.
    # Merge with existing cache: fresh entries overwrite stale ones for the same issue;
    # entries for issues not in current scan (e.g. claimed/active) are preserved.
    # No extra GitHub API calls — labels come from the bulk gh issue list already fetched above.
    if [ -n "$new_issue_labels_cache" ]; then
        local existing_cache
        existing_cache=$(get_state "issueLabels" 2>/dev/null || echo "")
        local merged_cache="$new_issue_labels_cache"
        if [ -n "$existing_cache" ]; then
            # Append existing entries for issue numbers NOT already in the fresh cache
            # (preserves labels for claimed/active issues not in current queue scan)
            local fresh_issue_nums
            fresh_issue_nums=$(echo "$new_issue_labels_cache" | tr '|' '\n' | cut -d: -f1 | sort)
            local preserved_entries=""
            while IFS='|' read -ra existing_entries; do
                for entry in "${existing_entries[@]}"; do
                    [ -z "$entry" ] && continue
                    local entry_issue="${entry%%:*}"
                    if ! echo "$fresh_issue_nums" | grep -qx "$entry_issue"; then
                        if [ -z "$preserved_entries" ]; then
                            preserved_entries="$entry"
                        else
                            preserved_entries="${preserved_entries}|${entry}"
                        fi
                    fi
                done
            done <<< "$existing_cache"
            if [ -n "$preserved_entries" ]; then
                merged_cache="${merged_cache}|${preserved_entries}"
            fi
        fi
        # Limit cache size to avoid ConfigMap bloat (keep most recent 100 entries)
        merged_cache=$(echo "$merged_cache" | tr '|' '\n' | head -100 | tr '\n' '|' | sed 's/|$//')
        update_state "issueLabels" "$merged_cache"
        local cached_count
        cached_count=$(echo "$new_issue_labels_cache" | tr '|' '\n' | wc -l | tr -d ' ')
        echo "[$(date -u +%H:%M:%S)] Issue #1442: Pre-populated issueLabels cache for $cached_count labeled issues"
    fi

    if [ -n "$scored_issues" ]; then
        # Sort by score descending, extract issue numbers
        local sorted_issues
        sorted_issues=$(printf "%b" "$scored_issues" | sort -t: -k1 -rn | cut -d: -f2 | tr '\n' ',' | sed 's/,$//')

        # Issue #1124: Deduplicate task queue to prevent agents wasting effort on duplicate entries.
        # Without deduplication, issues can appear multiple times when GitHub is re-scanned,
        # causing agents to query the same issue repeatedly even though claim_task prevents actual
        # duplicate work. Deduplication improves coordinator efficiency and reduces queue bloat.
        sorted_issues=$(echo "$sorted_issues" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

        # Issue #1149: Prepend visionQueue items BEFORE taskQueue so agent-voted issues get priority
        # visionQueue contains issues that 3+ agents voted to prioritize via governance
        # Issue #1444: visionQueue uses semicolon separator; extract only numeric issue numbers
        # Issue #1525: Prune visionQueue of closed issues before prepending to taskQueue.
        #   refresh_task_queue() already removes closed issues from taskQueue — visionQueue
        #   needs the same treatment. Without pruning, closed issues accumulate permanently
        #   and planners waste time trying to work on resolved work.
        local vision_queue
        vision_queue=$(get_state "visionQueue")
        if [ -n "$vision_queue" ]; then
            # Issue #1525: Prune closed issues from visionQueue.
            # Only check numeric entries (non-numeric feature entries are kept unconditionally).
            local pruned_vq=""
            local vq_pruned_count=0
            while IFS=';' read -ra VQ_ENTRIES; do
                for vq_entry in "${VQ_ENTRIES[@]}"; do
                    [ -z "$vq_entry" ] && continue
                    # Only numeric entries map to GitHub issues; non-numeric feature entries are kept
                    if [[ "$vq_entry" =~ ^[0-9]+$ ]]; then
                        local vq_issue_state
                        # Issue #1578: Use REST API to avoid GraphQL rate-limit failures.
                        # Fallback to OPEN (keep the entry) if the API call fails.
                        # ascii_upcase normalizes REST ("open"/"closed") to match comparison values.
                        vq_issue_state=$(gh api "repos/${GITHUB_REPO}/issues/${vq_entry}" \
                            --jq '.state | ascii_upcase' 2>/dev/null || echo "OPEN")
                        if [ "$vq_issue_state" = "CLOSED" ]; then
                            echo "[$(date -u +%H:%M:%S)] visionQueue: pruning closed issue #$vq_entry"
                            vq_pruned_count=$((vq_pruned_count + 1))
                            continue  # Skip closed issue — do not add to pruned_vq
                        fi
                    fi
                    [ -n "$pruned_vq" ] \
                        && pruned_vq="${pruned_vq};${vq_entry}" \
                        || pruned_vq="${vq_entry}"
                done
            done <<< "$vision_queue"
             if [ "$vq_pruned_count" -gt 0 ]; then
                 update_state "visionQueue" "$pruned_vq"
                 echo "[$(date -u +%H:%M:%S)] visionQueue: pruned $vq_pruned_count closed issue(s) (was: $vision_queue, now: $pruned_vq)"
                 vision_queue="$pruned_vq"

                 # Issue #1583: v0.4 milestone detection — when visionQueue transitions to empty
                 # (all agent-voted goals completed), announce milestone and invite next proposals.
                 # This is the foundation of civilization self-direction: agents notice when their
                 # collectively-chosen work is done and propose the next generation of goals.
                 if [ -z "$pruned_vq" ]; then
                     local vq_log
                     vq_log=$(get_state "visionQueueLog" 2>/dev/null || echo "")
                     if [ -n "$vq_log" ]; then
                         echo "[$(date -u +%H:%M:%S)] V0.4 MILESTONE: visionQueue emptied — all agent-voted goals completed! Civilization ready for next goal-setting cycle."
                         push_metric "VisionQueueCompleted" 1 "Count" "Component=Coordinator"
                         post_coordinator_thought \
"V0.4 CIVILIZATION MILESTONE: visionQueue has emptied — all collective goals are complete.

The civilization successfully self-directed through its voted goals.
Completed goals (from visionQueueLog): $(echo "$vq_log" | tr ';' '\n' | tail -5 | tr '\n' ' ')

NEXT STEP: Any agent can now propose new civilization goals via:
  #proposal-vision-feature addIssue=<N> reason=<why this matters for the civilization>

When 3+ agents vote to approve with deliberation, the new goal enters the visionQueue
and becomes the civilization's next priority — above the regular task queue.

This is v0.4 collective self-direction: the civilization sets its own agenda." \
"insight"
                     fi
                 fi
             fi

            # Extract numeric issue numbers from semicolon-separated entries
            local vision_issues
            vision_issues=$(echo "$vision_queue" | tr ';' '\n' | grep -E '^[0-9]+$' | tr '\n' ',' | sed 's/,$//')
            if [ -n "$vision_issues" ]; then
                # Prepend vision issues, then deduplicate (vision issues appear first)
                sorted_issues="${vision_issues},${sorted_issues}"
                # Deduplicate while preserving first occurrence (vision items stay at front)
                sorted_issues=$(echo "$sorted_issues" | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')
                echo "[$(date -u +%H:%M:%S)] VISION QUEUE: Prepended vision-voted issues: $vision_issues"
            fi
        fi

        # Issue #977: Replace queue with fresh open issues from GitHub.
        # Old merge strategy (sorted_issues + current_queue) caused closed issues
        # to persist in the queue indefinitely. Since the queue is driven entirely
        # by GitHub open issues, we simply replace with the latest sorted list.
        update_state "taskQueue" "$sorted_issues"
        echo "[$(date -u +%H:%M:%S)] Task queue (priority-sorted, vision-prepended, deduplicated): $sorted_issues"
    fi
}

# Check for stale assignments and remove them (do NOT re-queue)
# Issue #982 fix: Previously this returned stale issue numbers to the queue, causing
# closed issues to re-accumulate even after refresh_task_queue() replaced the queue.
# The fix: simply remove stale assignments. refresh_task_queue() (every 5 iterations)
# will re-add any issues that are still open on GitHub.
# Issue #1094 fix: Also remove assignments for CLOSED GitHub issues even when the
# agent job is still running. Agents working on closed issues are wasting cycles —
# they should be freed to pick different work.
cleanup_stale_assignments() {
    local assignments
    assignments=$(get_state "activeAssignments")
    [ -z "$assignments" ] && return 0

    local cleaned_assignments=""
    local stale_count=0

    # Issue #1561: Per-run issue-state cache to deduplicate gh issue view API calls.
    # cleanup_stale_assignments() runs every coordinator iteration (~30s) and calls
    # `gh issue view` for EACH assignment — both active (closed-issue check, #1094) and
    # inactive (open-issue check, #1556). With N assignments that's up to 2N API calls
    # per 30s cycle. This cache ensures each issue number is looked up at most once per run.
    # Format: space-separated "ISSUE=STATE" pairs (no associative arrays for bash 3 compat).
    local issue_state_cache=""

    # Helper: look up issue state from cache, or fetch and cache.
    # Usage: _get_issue_state <issue_number>
    # Prints: OPEN | CLOSED | UNKNOWN
    _get_issue_state() {
        local iss="$1"
        # Search cache for existing entry
        local cached
        cached=$(echo "$issue_state_cache" | tr ' ' '\n' | grep "^${iss}=" | cut -d= -f2 | head -1)
        if [ -n "$cached" ]; then
            echo "$cached"
            return 0
        fi
        # Not cached — fetch from GitHub API (REST, not GraphQL, to avoid rate limit failures)
        # Issue #1578: gh issue view --json uses GraphQL; gh api uses REST which is rate-limited
        # separately and more resilient. UNKNOWN fallback keeps the assignment so agents don't
        # lose work — better to keep a stale assignment than to silently drop active work.
        local fetched
        fetched=$(gh api "repos/${GITHUB_REPO}/issues/${iss}" --jq '.state | ascii_upcase' 2>/dev/null || echo "UNKNOWN")
        # Add to cache
        issue_state_cache="${issue_state_cache} ${iss}=${fetched}"
        echo "$fetched"
    }

    # Issue #1474/#1546: Load pre-claim timestamps to protect coordinator-created pre-claims
    # from being pruned before the worker's Job starts. Format: "agent:issue:ts;..."
    # route_tasks_by_specialization() writes here when pre-claiming on an agent's behalf.
    local pre_claim_timestamps
    pre_claim_timestamps=$(get_state "preClaimTimestamps" 2>/dev/null || echo "")
    local now_epoch
    now_epoch=$(date +%s)
    # Grace window: 120 seconds — worker spawn latency can exceed 60s (kro + EKS node scaling).
    local PRE_CLAIM_GRACE_WINDOW=120
    # Extended TTL: drop any pre-claim timestamp entries older than 300s (5 min)
    # to prevent stale entries from accumulating forever.
    if [ -n "$pre_claim_timestamps" ]; then
        local cleaned_ts=""
        while IFS= read -r ts_entry; do
            [ -z "$ts_entry" ] && continue
            local ts_val
            ts_val=$(echo "$ts_entry" | cut -d: -f3)
            if [[ "$ts_val" =~ ^[0-9]+$ ]]; then
                local age=$(( now_epoch - ts_val ))
                if [ "$age" -lt 300 ]; then
                    cleaned_ts="${cleaned_ts:+$cleaned_ts;}${ts_entry}"
                fi
            fi
        done < <(echo "$pre_claim_timestamps" | tr ';' '\n')
        if [ "$cleaned_ts" != "$pre_claim_timestamps" ]; then
            update_state "preClaimTimestamps" "$cleaned_ts"
            pre_claim_timestamps="$cleaned_ts"
        fi
    fi

    IFS=',' read -ra PAIRS <<< "$assignments"
    for pair in "${PAIRS[@]}"; do
        [ -z "$pair" ] && continue
        local agent_name="${pair%%:*}"
        # Issue #1504: Strip trailing whitespace from issue number.
        # Legacy coordinator writes (before PR #1473 fixed update_state()) stored issue
        # numbers with trailing spaces (e.g., "1483 "). This caused two failures:
        # 1. [[ "$issue" =~ ^[0-9]+$ ]] → FALSE, skipping the closed-issue check.
        # 2. claim_task()'s grep regex didn't match "1483 " when checking for "1483",
        #    allowing duplicate claims of the same issue by different agents.
        local issue
        issue=$(echo "${pair##*:}" | tr -d '[:space:]')

        # Issue #1669: Immediately release any assignment made by a planner.
        # Planners spawn workers for issues — they should never hold implementation claims.
        # Ghost planner assignments block workers from claiming the same issues.
        # Detect planner agents by name prefix (planner-* naming convention).
        if echo "$agent_name" | grep -q "^planner"; then
            echo "[$(date -u +%H:%M:%S)] Ghost planner: $agent_name → issue #$issue claimed by planner, releasing immediately (planners should spawn workers, not claim)"
            stale_count=$((stale_count + 1))
            continue
        fi

        local job_active
        # Issue #1170: Suppress jq parse errors from kubectl non-JSON output.
        # Issue #1260: Root cause fix — capture kubectl output first, use empty-object fallback.
        # When kubectl cannot find a job, some cluster configurations output "Error from server
        # (NotFound)..." to STDOUT. Capturing output first and using {} fallback prevents
        # jq "Invalid numeric literal at line 1, column 6" parse errors in coordinator logs.
        local raw_job_json
        raw_job_json=$(kubectl_with_timeout 10 get job "$agent_name" -n "$NAMESPACE" -o json 2>/dev/null || echo "")
        job_active=$(echo "${raw_job_json:-{\}}" | jq -r 'if (.status.completionTime == null and (.status.active // 0) > 0) then "true" else "false" end' 2>/dev/null || echo "false")

        if [ "$job_active" = "true" ]; then
            # Issue #1094: Even if agent job is running, check if the GitHub issue is still open.
            # If the issue was closed (by a merged PR or god), remove the assignment so the
            # task slot is freed for other work. Skip numeric check to handle non-issue refs.
            if [[ "$issue" =~ ^[0-9]+$ ]]; then
                local issue_state
                # Issue #1561: use cache to avoid duplicate gh issue view calls
                issue_state=$(_get_issue_state "$issue")
                if [ "$issue_state" = "CLOSED" ]; then
                    echo "[$(date -u +%H:%M:%S)] Closed issue: $agent_name → issue #$issue is CLOSED, releasing assignment (agent may continue but task slot freed)"
                    stale_count=$((stale_count + 1))
                    continue
                fi
            fi
            # Issue #1504: Reconstruct the pair from sanitized agent_name + issue (no trailing spaces).
            # Using ${pair} would preserve the original trailing space and corrupt future reads.
            local clean_pair="${agent_name}:${issue}"
            [ -n "$cleaned_assignments" ] \
                && cleaned_assignments="${cleaned_assignments},${clean_pair}" \
                || cleaned_assignments="${clean_pair}"
        else
            # Issue #1546: Before dropping this assignment, check if coordinator pre-claimed
            # it on behalf of this agent via route_tasks_by_specialization(). The worker's Job
            # may not have started yet (spawn latency can exceed 60s). If a recent pre-claim
            # timestamp exists for this agent:issue pair, preserve the assignment.
            local pre_claim_entry="${agent_name}:${issue}"
            local pre_claim_ts=""
            if [ -n "$pre_claim_timestamps" ]; then
                # Format: "agent:issue:epoch_seconds;agent2:issue2:epoch_seconds;..."
                pre_claim_ts=$(echo "$pre_claim_timestamps" | tr ';' '\n' | \
                    grep "^${pre_claim_entry}:" | tail -1 | cut -d: -f3 || echo "")
            fi

            if [ -n "$pre_claim_ts" ] && [[ "$pre_claim_ts" =~ ^[0-9]+$ ]]; then
                local age=$(( now_epoch - pre_claim_ts ))
                if [ "$age" -lt "$PRE_CLAIM_GRACE_WINDOW" ]; then
                    # Pre-claim is recent — preserve the assignment; worker hasn't started yet
                    echo "[$(date -u +%H:%M:%S)] Pre-claim: $agent_name → issue #$issue (age=${age}s < ${PRE_CLAIM_GRACE_WINDOW}s grace window) — keeping assignment"
                    local clean_pair="${agent_name}:${issue}"
                    [ -n "$cleaned_assignments" ] \
                        && cleaned_assignments="${cleaned_assignments},${clean_pair}" \
                        || cleaned_assignments="${clean_pair}"
                    continue
                else
                    echo "[$(date -u +%H:%M:%S)] Pre-claim expired: $agent_name → issue #$issue (age=${age}s >= ${PRE_CLAIM_GRACE_WINDOW}s) — releasing"
                    # Remove expired pre-claim timestamp
                    local updated_ts
                    updated_ts=$(echo "$pre_claim_timestamps" | tr ';' '\n' | \
                        grep -v "^${pre_claim_entry}:" | tr '\n' ';' | sed 's/;$//')
                    update_state "preClaimTimestamps" "$updated_ts"
                    pre_claim_timestamps="$updated_ts"
                fi
            fi

            # Issue #1638: Job not found — release ghost assignment immediately.
            # When raw_job_json is empty, the Job resource doesn't exist (was deleted or
            # never created). job_completion_epoch would be 0, bypassing the TTL check below
            # and keeping the assignment as "Pending: PR likely pending" forever.
            # Root cause: the TTL check requires job_completion_epoch > 0, which is only true
            # for jobs that were found but have already completed. For missing jobs, we must
            # explicitly detect the empty-json case and release right away.
            if [ -z "$raw_job_json" ] || ! echo "$raw_job_json" | jq -e '.metadata.name' >/dev/null 2>&1; then
                echo "[$(date -u +%H:%M:%S)] Not found: $agent_name → job missing (deleted or never created), releasing ghost assignment for issue #$issue"
                stale_count=$((stale_count + 1))
                continue
            fi

            # Issue #1556: Job completed, but check if issue is closed before releasing claim.
            # Race condition: Worker opens PR → Job completes → Coordinator releases claim
            # → Second worker claims same issue → duplicate PR.
            # Fix: Keep assignment if issue still OPEN (PR pending merge). Only release when CLOSED.
            # Issue #1610: Add job-completion TTL — if job completed > 4 hours ago and issue
            # is still OPEN, the agent likely did NOT open a PR (failed, skipped, or timed out).
            # Release the assignment so other agents can pick up the work.
            local STALE_PR_WAIT_TTL=14400  # 4 hours in seconds
            local job_completion_time
            job_completion_time=$(echo "${raw_job_json:-{\}}" | jq -r '.status.completionTime // ""' 2>/dev/null || echo "")
            local job_completion_epoch=0
            if [ -n "$job_completion_time" ]; then
                job_completion_epoch=$(date -d "$job_completion_time" +%s 2>/dev/null || echo "0")
            fi
            local job_age=$(( now_epoch - job_completion_epoch ))

            if [[ "$issue" =~ ^[0-9]+$ ]]; then
                local issue_state
                # Issue #1561: use cache to avoid duplicate gh issue view calls
                issue_state=$(_get_issue_state "$issue")
                if [ "$issue_state" = "CLOSED" ]; then
                    echo "[$(date -u +%H:%M:%S)] Complete: $agent_name → issue #$issue CLOSED, releasing assignment"
                    stale_count=$((stale_count + 1))
                elif [ "$issue_state" = "OPEN" ]; then
                    # Issue #1610: Job done + issue still open. Check TTL to detect abandoned claims.
                    if [ "$job_completion_epoch" -gt 0 ] && [ "$job_age" -gt "$STALE_PR_WAIT_TTL" ]; then
                        # Job completed > 4 hours ago and issue still open → agent did NOT open PR.
                        # Release the lock so other agents can work on this issue.
                        echo "[$(date -u +%H:%M:%S)] Abandoned: $agent_name → issue #$issue still OPEN but job completed ${job_age}s ago (>${STALE_PR_WAIT_TTL}s TTL), releasing stale lock"
                        stale_count=$((stale_count + 1))
                    else
                        # Job done but issue still open - likely PR pending merge. Keep assignment.
                        echo "[$(date -u +%H:%M:%S)] Pending: $agent_name → issue #$issue still OPEN (PR likely pending, job_age=${job_age}s < ${STALE_PR_WAIT_TTL}s), keeping assignment"
                        local clean_pair="${agent_name}:${issue}"
                        [ -n "$cleaned_assignments" ] \
                            && cleaned_assignments="${cleaned_assignments},${clean_pair}" \
                            || cleaned_assignments="${clean_pair}"
                    fi
                else
                    # UNKNOWN state (API error or non-issue task) - release to be safe
                    echo "[$(date -u +%H:%M:%S)] Stale: $agent_name → issue #$issue state UNKNOWN, releasing assignment"
                    stale_count=$((stale_count + 1))
                fi
            else
                # Non-numeric issue ref (e.g., vision queue feature) - release when job done
                echo "[$(date -u +%H:%M:%S)] Stale: $agent_name → task $issue (non-issue), releasing assignment"
                stale_count=$((stale_count + 1))
            fi
        fi
    done

    update_state "activeAssignments" "$cleaned_assignments"
    [ $stale_count -gt 0 ] && echo "[$(date -u +%H:%M:%S)] Cleaned $stale_count stale assignments"
    # Clean up local helper function to avoid name pollution
    unset -f _get_issue_state 2>/dev/null || true
}

# Cleanup activeAgents list - remove agents whose Jobs have completed (issue #676)
# Agents register themselves on startup but never deregister on exit.
# This causes activeAgents to accumulate stale entries over time.
# This function removes agents whose Jobs are completed or missing.
cleanup_active_agents() {
    local current_agents
    current_agents=$(get_state "activeAgents")
    [ -z "$current_agents" ] && return

    local cleaned_agents=""
    local removed_count=0

    IFS=',' read -ra agent_pairs <<< "$current_agents"
    for pair in "${agent_pairs[@]}"; do
        [ -z "$pair" ] && continue
        local agent_name="${pair%%:*}"
        
        # Check if Job still active (exists and no completionTime)
        local job_active
        # Issue #1170: Suppress jq parse errors from kubectl non-JSON output.
        # Issue #1260: Root cause fix — capture kubectl output first, use empty-object fallback.
        # When kubectl cannot find a job, some cluster configurations output "Error from server
        # (NotFound)..." to STDOUT. Capturing output first and using {} fallback prevents
        # jq "Invalid numeric literal at line 1, column 6" parse errors in coordinator logs.
        local raw_job_json
        raw_job_json=$(kubectl_with_timeout 10 get job "$agent_name" -n "$NAMESPACE" -o json 2>/dev/null || echo "")
        job_active=$(echo "${raw_job_json:-{\}}" | jq -r 'if (.status.completionTime == null and (.status.active // 0) > 0) then "true" else "false" end' 2>/dev/null || echo "false")
        
        if [ "$job_active" = "true" ]; then
            [ -n "$cleaned_agents" ] \
                && cleaned_agents="${cleaned_agents},${pair}" \
                || cleaned_agents="$pair"
        else
            removed_count=$((removed_count + 1))
        fi
    done

    if [ $removed_count -gt 0 ]; then
        update_state "activeAgents" "$cleaned_agents"
        echo "[$(date -u +%H:%M:%S)] Cleaned $removed_count stale agents from activeAgents list"
    fi
}

# Cleanup orphaned pods — delete Failed/Succeeded pods with no ownerReferences (issue #1416)
# When Jobs are deleted (manually or by cleanup), Kubernetes normally cascade-deletes owned pods.
# However, historical pods from before TTL governance vote were created differently, resulting in
# orphaned pods that accumulate and pollute kubectl output / consume cluster resources.
# Runs every 10 iterations (~5 min) to keep the namespace clean.
cleanup_orphaned_pods() {
    # Find pods with no ownerReferences that are in terminal phases (Failed or Succeeded)
    local orphaned_pods
    orphaned_pods=$(kubectl_with_timeout 15 get pods -n "$NAMESPACE" -o json 2>/dev/null | \
        jq -r '.items[] | select(
            (.metadata.ownerReferences == null or .metadata.ownerReferences == []) and
            (.status.phase == "Failed" or .status.phase == "Succeeded")
        ) | .metadata.name' 2>/dev/null || true)

    [ -z "$orphaned_pods" ] && return 0

    local orphaned_count
    orphaned_count=$(echo "$orphaned_pods" | grep -c . || echo "0")

    echo "[$(date -u +%H:%M:%S)] Cleaning $orphaned_count orphaned terminal pods (no ownerReferences)..."
    push_metric "OrphanedPodsFound" "$orphaned_count" "Count" "Component=Coordinator"

    local deleted_count=0
    while IFS= read -r pod_name; do
        [ -z "$pod_name" ] && continue
        if kubectl_with_timeout 10 delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null; then
            deleted_count=$((deleted_count + 1))
        fi
    done <<< "$orphaned_pods"

    echo "[$(date -u +%H:%M:%S)] Deleted $deleted_count orphaned pods"
    push_metric "OrphanedPodsDeleted" "$deleted_count" "Count" "Component=Coordinator"
}

# check_swarm_dissolution — Coordinator-driven swarm lifecycle management (issue #1787)
# The entrypoint.sh dissolution check only runs when an agent exits with SWARM_REF set.
# This leaves swarms stuck in Forming/Active after all their tasks complete, if no agent
# with SWARM_REF is still running. This function fixes that by running in the coordinator loop.
#
# Logic:
#   For each non-Disbanded swarm state ConfigMap:
#     1. Count total tasks vs done tasks (via agentex/swarm=<name> label on task ConfigMaps)
#     2. Check if lastActivityTimestamp > 300s ago (idle condition)
#     3. If all tasks done AND idle > 300s: patch phase to Disbanded and broadcast message
#
# Runs every 10 iterations (~5 min) to match the idle threshold check cadence.
check_swarm_dissolution() {
    # Find swarm state ConfigMaps: labeled kro.run/instance-kind=Swarm (from swarm-graph RGD)
    # These are the state CMs created by kro for each Swarm CR (named <swarm>-state).
    # Unlike task CMs (kro.run/instance-kind=Task), these hold phase/lastActivityTimestamp.
    local swarm_states
    swarm_states=$(kubectl_with_timeout 15 get configmaps -n "$NAMESPACE" \
        -l "kro.run/instance-kind=Swarm" \
        -o json 2>/dev/null || echo '{"items":[]}')

    local swarm_count
    swarm_count=$(echo "$swarm_states" | jq '.items | length' 2>/dev/null || echo "0")
    [ "$swarm_count" -eq 0 ] && return 0

    local disbanded=0
    local checked=0

    # Process each swarm state CM
    while IFS=$'\t' read -r swarm_name phase last_ts member_agents total_tasks swarm_goal swarm_goal_origin; do
        [ -z "$swarm_name" ] && continue
        [ "$phase" = "Disbanded" ] && continue

        checked=$((checked + 1))

        # The swarm name is the CM name without the -state suffix
        local swarm_ref="${swarm_name%-state}"

        # Count task ConfigMaps for this swarm: label agentex/swarm=<swarm_ref>
        local swarm_task_cms
        swarm_task_cms=$(kubectl_with_timeout 15 get configmaps -n "$NAMESPACE" \
            -l "agentex/swarm=${swarm_ref},kro.run/instance-kind=Task" \
            -o json 2>/dev/null || echo '{"items":[]}')

        local total done pending
        total=$(echo "$swarm_task_cms" | jq '.items | length' 2>/dev/null || echo "0")
        done=$(echo "$swarm_task_cms" | jq '[.items[] | select(.data.phase == "Done")] | length' 2>/dev/null || echo "0")
        pending=$((total - done))

        # Only consider dissolution if there are tasks and all are done
        if [ "$total" -eq 0 ] || [ "$pending" -gt 0 ]; then
            continue
        fi

        # Check idle condition: lastActivityTimestamp > 300s ago
        if [ -z "$last_ts" ]; then
            # No timestamp set — cannot compute idle time, skip
            continue
        fi

        local last_epoch now_epoch idle_seconds
        last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo "0")
        now_epoch=$(date +%s)
        idle_seconds=$((now_epoch - last_epoch))

        if [ "$idle_seconds" -lt 300 ]; then
            echo "[$(date -u +%H:%M:%S)] Swarm $swarm_ref: all $total tasks done but only ${idle_seconds}s idle (need 300s)"
            continue
        fi

        # DISSOLUTION: all tasks done, idle > 300s, not yet Disbanded
        echo "[$(date -u +%H:%M:%S)] SWARM DISSOLUTION: $swarm_ref completed all $total tasks, idle ${idle_seconds}s — disbanding"

        # CRITICAL (issue #1790): Write swarm memory to S3 before disbanding
        # The entrypoint.sh path calls write_swarm_memory() from helpers.sh when an agent
        # with SWARM_REF exits. The coordinator path must also persist swarm memory so that
        # coordinator-driven dissolutions (the common path) don't silently lose institutional knowledge.
        #
        # Inline implementation (coordinator.sh doesn't source helpers.sh):
        local s3_bucket="${S3_BUCKET:-agentex-thoughts}"
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        
        # Build members JSON array from member_agents (already CSV format from CM data)
        local members_json
        members_json=$(echo "$member_agents" | tr ',' '\n' | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo "[]")
        
        # Escape strings for JSON
        local safe_goal
        safe_goal=$(echo "$swarm_goal" | sed 's/"/\\"/g' | tr '\n' ' ')
        # Use goalOrigin from swarm state — needed for check_v06_milestone Criterion 3 (issue #1799)
        local safe_goal_origin
        safe_goal_origin=$(echo "${swarm_goal_origin:-coordinator}" | sed 's/"/\\"/g' | tr '\n' ' ')

        # Key decisions: extract from coordinator thought history or swarm state if available
        local key_decisions="Coordinator-driven dissolution: all tasks completed, idle threshold met"

        local memory_json
        memory_json=$(printf '{"swarmName":"%s","goal":"%s","goalOrigin":"%s","members":%s,"tasksCompleted":%s,"keyDecisions":"%s","dissolvedAt":"%s","recordedBy":"coordinator"}\n' \
          "$swarm_ref" \
          "$safe_goal" \
          "$safe_goal_origin" \
          "$members_json" \
          "$total" \
          "$key_decisions" \
          "$timestamp")
        
        local s3_path="s3://${s3_bucket}/swarm-memories/${swarm_ref}.json"
        
        if echo "$memory_json" | aws s3 cp - "$s3_path" --content-type application/json >/dev/null 2>&1; then
          echo "[$(date -u +%H:%M:%S)] Swarm memory persisted to ${s3_path}"
        else
          echo "[$(date -u +%H:%M:%S)] WARNING: Failed to persist swarm memory to S3 (non-fatal)"
        fi

        # Patch phase to Disbanded
        kubectl_with_timeout 10 patch configmap "${swarm_name}" -n "$NAMESPACE" \
            --type=merge -p '{"data":{"phase":"Disbanded"}}' 2>/dev/null || true

        # Post coordinator thought
        post_coordinator_thought "Swarm $swarm_ref dissolved by coordinator. Goal achieved. All $total tasks completed. Members: $member_agents. Idle: ${idle_seconds}s. Memory persisted to S3 (issue #1790)." "insight"

        push_metric "SwarmDisbanded" 1 "Count" "Component=Coordinator"
        disbanded=$((disbanded + 1))

    done < <(echo "$swarm_states" | jq -r \
        '.items[] | [
            .metadata.name,
            (.data.phase // "Forming"),
            (.data.lastActivityTimestamp // ""),
            (.data.memberAgents // ""),
            (.data.tasksCompleted // "0"),
            (.data.goal // "completed platform improvement"),
            (.data.goalOrigin // "coordinator")
        ] | @tsv' 2>/dev/null)

    if [ "$checked" -gt 0 ]; then
        echo "[$(date -u +%H:%M:%S)] Swarm dissolution check: $checked active swarms, $disbanded disbanded"
    fi
}

# track_active_swarms — Update coordinator-state.activeSwarms with live swarm summary (issue #1775)
# v0.6 Swarm Intelligence observability: count non-Disbanded swarm state ConfigMaps and record
# per-swarm summaries (name:goal:member-count) so check_v06_milestone() and civilization_status()
# can show real-time swarm health without listing cluster resources directly.
#
# Format: "swarm-name:goal-text:N|swarm-name2:goal-text2:M|..."
#   - swarm-name: the swarm CR name (CM name without -state suffix)
#   - goal-text: .data.goal from the swarm state CM, truncated to 40 chars, colons replaced
#   - N: member agent count from .data.memberAgents (comma-separated list)
#
# Called every 5 iterations (~2.5 min) in the main loop AND at end of check_swarm_dissolution().
# On dissolution, the disbanded swarm is removed from the field so it reflects only live swarms.
track_active_swarms() {
    # Find all swarm state ConfigMaps (labeled by kro from swarm-graph RGD)
    local swarm_states
    swarm_states=$(kubectl_with_timeout 15 get configmaps -n "$NAMESPACE" \
        -l "kro.run/instance-kind=Swarm" \
        -o json 2>/dev/null || echo '{"items":[]}')

    local swarm_count
    swarm_count=$(echo "$swarm_states" | jq '.items | length' 2>/dev/null || echo "0")

    if [ "$swarm_count" -eq 0 ]; then
        # No swarms at all — clear the field
        local current
        current=$(get_state "activeSwarms" 2>/dev/null || echo "")
        [ -n "$current" ] && update_state "activeSwarms" ""
        return 0
    fi

    # Build pipe-separated summary of non-Disbanded swarms
    local active_entries=""
    local active_count=0

    while IFS=$'\t' read -r swarm_name phase goal member_agents; do
        [ -z "$swarm_name" ] && continue
        [ "$phase" = "Disbanded" ] && continue

        local swarm_ref="${swarm_name%-state}"

        # Count members from comma-separated memberAgents field
        local member_count=0
        if [ -n "$member_agents" ]; then
            member_count=$(echo "$member_agents" | tr ',' '\n' | grep -c '.' 2>/dev/null || echo "0")
        fi

        # Truncate goal to 40 chars and replace colons/pipes (field separators) with hyphens
        local safe_goal
        safe_goal=$(echo "${goal:-no-goal-set}" | cut -c1-40 | tr ':|' '--')

        local entry="${swarm_ref}:${safe_goal}:${member_count}"
        if [ -z "$active_entries" ]; then
            active_entries="$entry"
        else
            active_entries="${active_entries}|${entry}"
        fi
        active_count=$((active_count + 1))
    done < <(echo "$swarm_states" | jq -r \
        '.items[] | [
            .metadata.name,
            (.data.phase // "Forming"),
            (.data.goal // ""),
            (.data.memberAgents // "")
        ] | @tsv' 2>/dev/null)

    # Update coordinator-state.activeSwarms
    local current
    current=$(get_state "activeSwarms" 2>/dev/null || echo "")
    if [ "$current" != "$active_entries" ]; then
        update_state "activeSwarms" "$active_entries"
        echo "[$(date -u +%H:%M:%S)] activeSwarms updated: ${active_count} active swarm(s)"
        push_metric "ActiveSwarms" "$active_count" "Count" "Component=Coordinator"
    fi
}

# cleanup_old_cluster_resources — Periodically delete stale Thought and Message CRs (issue #1617)
# The cluster accumulates 4000+ Thought ConfigMaps and 1600+ Report CRs when planner cleanup
# doesn't run frequently enough. The coordinator runs continuously every ~30s and is better
# positioned for periodic cleanup to supplement planner-initiated cleanup.
#
# TTLs match helpers.sh cleanup_old_thoughts / cleanup_old_messages:
#   Thought low-signal (blocker, observation, decision, plan, planning): 2h TTL
#   Thought high-signal (insight, debate, proposal, vote): 24h TTL
# Issue #1662: align with PR #1627 fix — decision/plan/planning now use 2h TTL (was 24h)
#   Messages (read): 24h TTL
#   Messages (unread): 48h TTL
#   Reports: 48h TTL
#
# Runs every 60 iterations (~30 min) to bound coordinator blocking time.
cleanup_old_cluster_resources() {
    local cutoff_2h cutoff_24h cutoff_48h
    cutoff_2h=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    cutoff_24h=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    cutoff_48h=$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

    if [ -z "$cutoff_24h" ] || [ -z "$cutoff_2h" ] || [ -z "$cutoff_48h" ]; then
        echo "[$(date -u +%H:%M:%S)] WARNING: Cannot calculate cleanup cutoffs — skipping (date command issue)"
        return 0
    fi

    local total_deleted=0

    # --- Thought ConfigMap cleanup ---
    # Use 60s timeout: 4000+ CRs takes 10-15s to list
    local all_thoughts_json
    all_thoughts_json=$(kubectl_with_timeout 60 get thoughts.kro.run -n "$NAMESPACE" -o json 2>/dev/null || true)
    if [ -n "$all_thoughts_json" ] && [ "$all_thoughts_json" != "null" ]; then
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
        if [ -n "$old_thoughts" ]; then
            local thought_count
            thought_count=$(echo "$old_thoughts" | wc -w)
            echo "[$(date -u +%H:%M:%S)] Coordinator cleanup: deleting $thought_count old thoughts..."
            echo "$old_thoughts" | xargs -n 50 kubectl delete thoughts.kro.run -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true
            total_deleted=$((total_deleted + thought_count))
        fi
    fi

    # --- Message CR cleanup ---
    local all_messages_json
    all_messages_json=$(kubectl_with_timeout 30 get messages -n "$NAMESPACE" -o json 2>/dev/null || true)
    if [ -n "$all_messages_json" ] && [ "$all_messages_json" != "null" ]; then
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
        if [ -n "$old_messages" ]; then
            local msg_count
            msg_count=$(echo "$old_messages" | wc -w)
            echo "[$(date -u +%H:%M:%S)] Coordinator cleanup: deleting $msg_count old messages..."
            echo "$old_messages" | xargs -n 50 kubectl delete messages -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true
            total_deleted=$((total_deleted + msg_count))
        fi
    fi

    # --- Report CR cleanup (48h TTL) ---
    local all_reports_json
    all_reports_json=$(kubectl_with_timeout 60 get reports -n "$NAMESPACE" -o json 2>/dev/null || true)
    if [ -n "$all_reports_json" ] && [ "$all_reports_json" != "null" ]; then
        local old_reports
        old_reports=$(echo "$all_reports_json" | jq -r \
            --arg cutoff_48h "$cutoff_48h" \
            '.items[] | select(.metadata.creationTimestamp < $cutoff_48h) | .metadata.name' 2>/dev/null || true)
        if [ -n "$old_reports" ]; then
            local report_count
            report_count=$(echo "$old_reports" | wc -w)
            echo "[$(date -u +%H:%M:%S)] Coordinator cleanup: deleting $report_count old reports (48h TTL)..."
            echo "$old_reports" | xargs -n 50 kubectl delete reports -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true
            total_deleted=$((total_deleted + report_count))
        fi
    fi

    if [ "$total_deleted" -gt 0 ]; then
        echo "[$(date -u +%H:%M:%S)] Coordinator cleanup: removed $total_deleted stale CRs (thoughts+messages+reports)"
        push_metric "ClusterResourcesDeleted" "$total_deleted" "Count" "Component=Coordinator"
    fi

    # Issue #1667: Prune orphaned entries from unresolvedDebates (parent CM was deleted)
    prune_orphaned_unresolved_debates
}

# prune_orphaned_unresolved_debates — remove entries from unresolvedDebates that reference
# deleted thought ConfigMaps (issue #1667). Called from cleanup_old_cluster_resources() every 30 min.
#
# When cleanup_old_thoughts() deletes old thought CMs, any debate thread ID stored in
# unresolvedDebates whose parent CM is now gone becomes orphaned. This function filters them out.
prune_orphaned_unresolved_debates() {
    local current_unresolved
    current_unresolved=$(kubectl_with_timeout 10 get configmap "$STATE_CM" -n "$NAMESPACE" \
        -o jsonpath='{.data.unresolvedDebates}' 2>/dev/null || true)
    [ -z "$current_unresolved" ] && return 0

    # Issue #1667: Pre-fetch all existing thought CM names in one batch query to avoid
    # N individual kubectl get calls (one per unresolved entry). With 98+ entries this
    # is a significant performance improvement over the per-entry approach.
    local existing_thought_names
    existing_thought_names=$(kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" \
        -l agentex/thought -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    local pruned_count=0
    local valid_entries=""
    while IFS= read -r thread_id; do
        [ -z "$thread_id" ] && continue
        if echo " $existing_thought_names " | grep -qF " $thread_id "; then
            [ -n "$valid_entries" ] \
                && valid_entries="${valid_entries},${thread_id}" \
                || valid_entries="$thread_id"
        else
            echo "[$(date -u +%H:%M:%S)] Pruning orphaned unresolvedDebate entry: $thread_id"
            pruned_count=$((pruned_count + 1))
        fi
    done < <(echo "$current_unresolved" | tr ',' '\n')

    if [ "$pruned_count" -gt 0 ]; then
        update_state "unresolvedDebates" "$valid_entries"
        echo "[$(date -u +%H:%M:%S)] Pruned $pruned_count orphaned entries from unresolvedDebates"
        push_metric "OrphanedDebatesPruned" "$pruned_count" "Count" "Component=Coordinator"
    fi
}

# Reconcile spawnSlots against actual running job count (leak recovery)
# If agents crash before releasing slots, spawnSlots drifts low.
# This function resets spawnSlots = max(0, circuitBreakerLimit - activeJobs).
reconcile_spawn_slots() {
    local limit
    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    # Issue #1001: Fallback to 6 (current constitution value), NOT 12.
    # Using 12 as fallback would double the circuit-breaker limit when the constitution ConfigMap
    # is temporarily unavailable (e.g. coordinator restart), potentially causing proliferation.
    limit=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "6")
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then limit=6; fi

    local active_jobs
    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    active_jobs=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
        2>/dev/null || echo "0")

    local correct_slots=$(( limit - active_jobs ))
    if [ "$correct_slots" -lt 0 ]; then correct_slots=0; fi

    local current_slots
    current_slots=$(get_state "spawnSlots")
    # Handle empty, non-numeric, OR NEGATIVE values (issue #1240)
    # Negative spawnSlots blocks ALL agent spawning until reconciled.
    # The ^[0-9]+$ regex correctly rejects negative values (which contain '-'),
    # but we add an explicit integer check too for clarity.
    if [ -z "$current_slots" ] || ! [[ "$current_slots" =~ ^-?[0-9]+$ ]]; then
        current_slots=0
    elif [ "$current_slots" -lt 0 ]; then
        echo "[$(date -u +%H:%M:%S)] WARNING: spawnSlots is negative ($current_slots) — civilization frozen! Forcing reconciliation."
        current_slots=0
    fi

    echo "[$(date -u +%H:%M:%S)] Spawn slot reconciliation: limit=$limit activeJobs=$active_jobs currentSlots=$current_slots → correctSlots=$correct_slots"
    push_metric "ActiveJobs" "$active_jobs" "Count" "Component=Coordinator"
    push_metric "SpawnSlots" "$correct_slots" "Count" "Component=Coordinator"

    if [ "$current_slots" != "$correct_slots" ]; then
        update_state "spawnSlots" "$correct_slots"
        echo "[$(date -u +%H:%M:%S)] Reconciled spawnSlots: $current_slots → $correct_slots"
    fi
}

# Sync constitution.yaml in git after governance enactment (issue #893)
# When the coordinator patches the live ConfigMap, this function opens a PR
# to update the source file so git repo stays in sync with cluster state.
sync_constitution_to_git() {
    local kv_pairs="$1"
    local topic="$2"
    local approve_votes="$3"
    
    echo "[$(date -u +%H:%M:%S)] Syncing constitution.yaml to git after governance enactment..."
    
    # Create temp workspace
    local workspace
    workspace=$(mktemp -d /tmp/constitution-sync-XXXXXX)
    trap "rm -rf '$workspace'" RETURN
    
    cd "$workspace" || return 1
    
    # Clone repo with GITHUB_TOKEN for authenticated push (issue #1282)
    # Without token, git push fails even for public repos
    local clone_url
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        clone_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}"
    else
        clone_url="https://github.com/${GITHUB_REPO}"
        echo "[$(date -u +%H:%M:%S)] WARNING: GITHUB_TOKEN not set, git push may fail"
    fi
    if ! git clone "$clone_url" repo 2>/dev/null; then
        echo "[$(date -u +%H:%M:%S)] ERROR: Failed to clone ${GITHUB_REPO}"
        return 1
    fi
    
    cd repo || return 1
    
    # Configure git user
    git config user.email "coordinator@agentex.io"
    git config user.name "Agentex Coordinator"
    
    # Create branch
    local branch_name="governance-enacted-${topic}-$(date +%s)"
    git checkout -b "$branch_name" 2>/dev/null || return 1
    
    # Verify cluster is reachable (connectivity check before git operations)
    if ! kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" -o name 2>/dev/null | grep -q constitution; then
        echo "[$(date -u +%H:%M:%S)] ERROR: Could not verify agentex-constitution ConfigMap"
        return 1
    fi
    
    # Update constitution.yaml AND chart/values.yaml — surgically update only the changed
    # keys (issue #1317). Strategy: parse kv_pairs to find which keys changed, then use
    # sed to update ONLY those keys in each file. This preserves all comments, annotations,
    # and documentation. Both files use "  key: "value"" (2-space indent) for governance keys.
    # chart/values.yaml must also be updated so fresh helm installs reflect governance
    # decisions (issue #1408).
    local constitution_file="manifests/system/constitution.yaml"
    local values_file="chart/values.yaml"
    
    # Parse kv_pairs (format: "key1=value1 key2=value2") and update each changed key.
    # Skip meta-keys that are not real constitution fields (reason=, proposalRef=).
    local meta_keys="reason proposalRef"
    local updated_any=false
    while IFS= read -r pair || [ -n "$pair" ]; do
        [ -z "$pair" ] && continue
        [[ "$pair" != *"="* ]] && continue
        local key="${pair%%=*}"
        local value="${pair#*=}"
        # Skip meta-keys
        local is_meta=false
        for mk in $meta_keys; do
            [ "$key" = "$mk" ] && is_meta=true && break
        done
        "$is_meta" && continue
        # Escape any forward slashes in value for sed
        local escaped_value
        escaped_value=$(echo "$value" | sed 's/[\/&]/\\&/g')
        # Surgically update the key in constitution.yaml using sed
        # Pattern: "  key: ..." (exactly 2-space indent, matches data section keys)
        # The sed replacement preserves the line format with quoted value
        if grep -q "^  ${key}: " "$constitution_file" 2>/dev/null; then
            sed -i "s/^  ${key}: .*$/  ${key}: \"${escaped_value}\"/" "$constitution_file"
            echo "[$(date -u +%H:%M:%S)] ✓ Updated constitution.yaml: ${key}=${value}"
            updated_any=true
        else
            echo "[$(date -u +%H:%M:%S)] WARNING: key '${key}' not found in constitution.yaml — skipping"
        fi
        # Also update chart/values.yaml with the same surgical sed pattern (issue #1408)
        # Both files use "  key: "value"" (2-space indent) for governance-affected keys.
        # This ensures fresh helm installs reflect enacted governance decisions.
        if grep -q "^  ${key}: " "$values_file" 2>/dev/null; then
            sed -i "s/^  ${key}: .*$/  ${key}: \"${escaped_value}\"/" "$values_file"
            echo "[$(date -u +%H:%M:%S)] ✓ Updated chart/values.yaml: ${key}=${value}"
        else
            echo "[$(date -u +%H:%M:%S)] INFO: key '${key}' not in chart/values.yaml — skipping (constitution-only key)"
        fi
    done <<< "$(echo "$kv_pairs" | tr ' ' '\n')"
    
    # Check if there are changes (either file)
    if ! git diff --quiet "$constitution_file" || ! git diff --quiet "$values_file"; then
        git add "$constitution_file" "$values_file"
        
        # Build commit message
        local commit_msg="chore: sync constitution.yaml with enacted governance decision

Governance topic: ${topic}
Enacted changes: ${kv_pairs}
Vote count: ${approve_votes} approvals (threshold: ${VOTE_THRESHOLD})

This commit syncs the git repo with the cluster ConfigMap after
governance enactment. Without this sync, fresh installs would revert
the civilization's collective decisions.

Both manifests/system/constitution.yaml and chart/values.yaml are updated
so that both kubectl-apply and helm-install installations stay in sync.

Fixes #893
Fixes #1408"
        
        git commit -m "$commit_msg" 2>/dev/null || return 1
        
        # Push to remote
        if git push -u origin "$branch_name" 2>/dev/null; then
            echo "[$(date -u +%H:%M:%S)] ✓ Pushed branch $branch_name"
            
            # Create PR using gh CLI
            if command -v gh &>/dev/null && [ -n "${GITHUB_TOKEN:-}" ]; then
                # Check if PR already exists for this topic (open or merged) to avoid duplicates (#1333, #1398)
                local pr_title="chore: sync constitution.yaml with enacted governance ($topic)"
                local existing_open_pr
                existing_open_pr=$(gh pr list --repo "${GITHUB_REPO}" --state open \
                    --search "sync constitution.yaml with enacted governance ($topic)" \
                    --json number --jq '.[0].number' 2>/dev/null)
                if [ -n "$existing_open_pr" ]; then
                    echo "[$(date -u +%H:%M:%S)] ✓ Open PR #${existing_open_pr} already exists for topic ${topic} — skipping duplicate creation"
                    push_metric "ConstitutionSyncDuplicatePrevented" 1 "Count" "Topic=${topic}"
                    return 0
                fi
                # Also check if a merged PR already exists — if so, no new PR needed
                local existing_merged_pr
                existing_merged_pr=$(gh pr list --repo "${GITHUB_REPO}" --state merged \
                    --search "sync constitution.yaml with enacted governance ($topic)" \
                    --json number --jq '.[0].number' 2>/dev/null)
                if [ -n "$existing_merged_pr" ]; then
                    echo "[$(date -u +%H:%M:%S)] ✓ Merged PR #${existing_merged_pr} already exists for topic ${topic} — constitution already synced"
                    push_metric "ConstitutionSyncAlreadyMerged" 1 "Count" "Topic=${topic}"
                    return 0
                fi
                gh pr create \
                    --repo "${GITHUB_REPO}" \
                    --title "${pr_title}" \
                    --body "## Governance Enactment Sync

This PR syncs \`manifests/system/constitution.yaml\` and \`chart/values.yaml\` with the live \`agentex-constitution\` ConfigMap after governance enactment.

**Enacted changes:**
\`\`\`
${kv_pairs}
\`\`\`

**Governance details:**
- Topic: \`${topic}\`
- Vote count: ${approve_votes} approvals (threshold: ${VOTE_THRESHOLD})
- Enactment timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)

**Why this matters:**
Without this sync, the git repo drifts from cluster state. Fresh installs using \`kubectl apply -f manifests/system/constitution.yaml\` would revert collective decisions made by the civilization. Fresh Helm installs (\`helm install agentex ./chart\`) would also use stale defaults from \`chart/values.yaml\` without this fix.

**Related:** Issue #893, Issue #891 (constitution drift detection), Issue #1408 (values.yaml drift)

**Auto-merge eligible:** This is a data sync PR (not protected file) reflecting already-enacted governance. Safe to merge immediately." \
                    --head "$branch_name" \
                    --base main 2>/dev/null
                
                if [ $? -eq 0 ]; then
                    echo "[$(date -u +%H:%M:%S)] ✓ PR created for constitution sync"
                    push_metric "ConstitutionSyncSuccess" 1 "Count" "Topic=${topic}"
                else
                    echo "[$(date -u +%H:%M:%S)] WARNING: PR creation failed (gh CLI error)"
                fi
            else
                echo "[$(date -u +%H:%M:%S)] WARNING: gh CLI not available, PR not created"
            fi
        else
            echo "[$(date -u +%H:%M:%S)] ERROR: Failed to push branch $branch_name"
            return 1
        fi
    else
        echo "[$(date -u +%H:%M:%S)] No changes detected in constitution.yaml or chart/values.yaml (already synced)"
    fi
    
    cd / && rm -rf "$workspace"
    return 0
}

# cleanup_zombie_vote_registry_keys: Remove voteRegistry_* entries for proposals whose
# Thought CRs have been deleted by the 24h TTL cleanup. Called on every tally cycle,
# including when the main tally exits early (no new thoughts or no active proposals).
#
# Issue #1719: The original zombie cleanup was inside tally_and_enact_votes() but ran
# AFTER two early-return guards (thought_count==0 and topics==empty). This meant zombie
# entries accumulated indefinitely whenever the system was quiescent or all proposals
# had expired — the exact conditions most likely to have zombie keys.
#
# Fix: Extract into a standalone function that always runs, independent of thoughts_file.
cleanup_zombie_vote_registry_keys() {
    local enacted_decisions
    enacted_decisions=$(get_state "enactedDecisions" 2>/dev/null || echo "")

    local all_vote_keys
    all_vote_keys=$(kubectl_with_timeout 10 get configmap "$STATE_CM" -n "$NAMESPACE" -o json 2>/dev/null \
        | jq -r '.data | keys[] | select(startswith("voteRegistry_"))' 2>/dev/null || true)

    [ -z "$all_vote_keys" ] && return 0

    # Get all active proposal topics from current in-cluster Thought CRs
    local active_proposal_topics
    active_proposal_topics=$(kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" \
        -l agentex/thought -o json 2>/dev/null \
        | jq -r '[.items[] | select(.data.thoughtType == "proposal") | .data.content] | .[] ' \
        | grep -oE '#proposal-[a-zA-Z0-9_-]+' | sed 's/#proposal-//' | sort -u 2>/dev/null || true)

    local zombie_count=0
    while IFS= read -r vote_key; do
        [ -z "$vote_key" ] && continue
        local vote_topic="${vote_key#voteRegistry_}"
        # Skip vision-feature/vision-queue keys (per-issue suffix keys handled separately)
        if [[ "$vote_topic" == *"vision-feature"* || "$vote_topic" == *"vision-queue"* ]]; then
            continue
        fi
        # If no active proposal Thought CR exists for this topic, it's a zombie
        if ! echo "$active_proposal_topics" | grep -qxF "$vote_topic"; then
            # Check if it's already enacted — enacted topics were cleaned up on enaction.
            # A zombie is an entry with no active proposal AND not enacted.
            if ! echo "$enacted_decisions" | grep -qF "enacted_topic_${vote_topic}"; then
                remove_state "$vote_key" 2>/dev/null && zombie_count=$((zombie_count + 1)) || true
                echo "[$(date -u +%H:%M:%S)] GOVERNANCE: Removed zombie voteRegistry_${vote_topic} (no active proposal Thought CR found)"
            fi
        fi
    done <<< "$all_vote_keys"
    [ "$zombie_count" -gt 0 ] && echo "[$(date -u +%H:%M:%S)] GOVERNANCE: Cleaned $zombie_count zombie voteRegistry keys (issue #1719)"
}

# Tally votes from Thought CRs and ENACT consensus when threshold reached
# GENERIC GOVERNANCE ENGINE (issue #630) — handles ANY proposal topic
tally_and_enact_votes() {
    echo "[$(date -u +%H:%M:%S)] Tallying votes from Thought CRs (generic governance engine)..."

    # Re-read voteThreshold from constitution on every tally cycle (issue #1063).
    # This ensures that when governance enacts a voteThreshold change, the coordinator
    # picks it up without requiring a restart. circuitBreakerLimit is re-read similarly
    # in the main loop — same pattern applied here for consistency.
    local current_vote_threshold
    current_vote_threshold=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.voteThreshold}' 2>/dev/null || echo "")
    if [ -n "$current_vote_threshold" ] && [[ "$current_vote_threshold" =~ ^[0-9]+$ ]]; then
        if [ "$current_vote_threshold" != "$VOTE_THRESHOLD" ]; then
            echo "[$(date -u +%H:%M:%S)] voteThreshold updated from constitution: $VOTE_THRESHOLD → $current_vote_threshold"
            VOTE_THRESHOLD="$current_vote_threshold"
        fi
    fi

    # Write thoughts to temp file. Read from ConfigMap .data fields — this is where
    # agent-created thoughts live (kro syncs Thought CRs → ConfigMaps with -thought suffix).
    # Do NOT use gsub or encoding transforms — raw .data.content is correct as-is.
    # Do NOT use thoughts.kro.run — that group only has ~4 god-created CRs, not agent thoughts.
    local thoughts_file
    thoughts_file=$(mktemp /tmp/agentex-thoughts-XXXXXX.json)
    trap "rm -f '$thoughts_file'" RETURN

     # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
     # Issue #1011: Use label selector -l agentex/thought to avoid fetching all 9000+ configmaps
     # (causes OOM kill — coordinator only has 512Mi limit)
     # Issue #1056: Filter to ONLY proposal/vote thoughts — no need to load 1800+ insight/planning/
     # observation thoughts that are irrelevant to governance tallying. This reduces memory by ~97%.
     # Issue #1248: Also include debate thoughts for vision-feature deliberation threshold check.
     # Issue #1407: Time-based filter — only load thoughts newer than lastTallyTimestamp to prevent
     # O(N) growth as Thought CRs accumulate. voteRegistry_* fields already cache running totals,
     # but we must reload ALL thoughts at least once to rebuild accurate totals after restart.
     # Use 24h window as a floor to ensure vote counts remain accurate after coordinator restarts.
     local last_tally_ts
     last_tally_ts=$(get_state "lastTallyTimestamp" 2>/dev/null || echo "")
     local tally_cutoff_ts
     # Default: load thoughts from the last 24 hours. This catches any newly-posted votes
     # and ensures vote totals are complete even after coordinator restart (voteRegistry reset).
     local cutoff_24h
     cutoff_24h=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
      if [ -n "$last_tally_ts" ] && [ -n "$cutoff_24h" ]; then
        # Use the EARLIER of (lastTallyTimestamp - 5min buffer) and (now - 24h).
        # "Earlier" means FURTHER BACK IN TIME (the timestamp that is LESS THAN the other).
        # We want the BROADER window so old proposals still get tallied correctly.
        # The 5-min buffer handles clock skew and thoughts created just before last tally.
        # The 24h floor ensures proposals never stay in the tally window past their Thought CR TTL.
        local last_tally_minus5m
        last_tally_minus5m=$(date -u -d "${last_tally_ts} -5 minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$cutoff_24h")
        # Issue #1712: Use the EARLIER (less restrictive, further back in time) of the two cutoffs.
        # If last_tally_minus5m < cutoff_24h, last_tally_minus5m is further back — use it.
        # Otherwise, cutoff_24h is the 24h floor and is further back — use it as the floor.
        if [[ "$last_tally_minus5m" < "$cutoff_24h" ]]; then
          tally_cutoff_ts="$last_tally_minus5m"  # broader window (further back in time)
        else
          tally_cutoff_ts="$cutoff_24h"  # 24h floor is broader (coordinator recently restarted)
        fi
      else
        tally_cutoff_ts="$cutoff_24h"
      fi

     # Issue #1798: Tight window for "no new votes" early skip check (separate from tally_cutoff_ts).
     # tally_cutoff_ts can be up to 24h (needed to rebuild vote counts on restart), but
     # the early skip check only needs votes since the LAST TALLY RUN to determine if a topic
     # needs re-processing. Using the full 24h window causes all enacted topics to be re-processed
     # (because old votes exist in the 24h window), preventing the early skip from firing.
     # Fix: compute a tight cutoff based on last_tally_ts (or 10min ago as fallback).
     local recent_tally_cutoff_ts
     if [ -n "$last_tally_ts" ]; then
       # Use last_tally_ts with 2-min buffer for clock skew — any vote after last tally is "new"
       recent_tally_cutoff_ts=$(date -u -d "${last_tally_ts} -2 minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$last_tally_ts")
     else
       # On first run after restart, use 10-min window to catch genuine recent activity
       recent_tally_cutoff_ts=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
     fi

     kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" -l agentex/thought -o json 2>/dev/null \
         | jq --arg cutoff "$tally_cutoff_ts" '[.items[] |
             select(.data.thoughtType == "proposal" or .data.thoughtType == "vote" or .data.thoughtType == "debate") |
             select(if $cutoff != "" then .metadata.creationTimestamp >= $cutoff else true end) | {
             agent: (.data.agentRef // "unknown"),
             content: (.data.content // ""),
             type: (.data.thoughtType // ""),
             parent: (.data.parentRef // ""),
             ts: .metadata.creationTimestamp
           }]' 2>/dev/null > "$thoughts_file" || echo "[]" > "$thoughts_file"

    # Update lastTallyTimestamp so next run only processes newer thoughts
    local now_ts
    now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p "{\"data\":{\"lastTallyTimestamp\":\"${now_ts}\"}}" 2>/dev/null || true

    local thought_count
    thought_count=$(jq 'length' "$thoughts_file" 2>/dev/null || echo 0)
    if [ "$thought_count" -eq 0 ]; then
        echo "[$(date -u +%H:%M:%S)] No new governance thoughts since ${tally_cutoff_ts:-startup} — skipping tally"
        # Issue #1719: Run zombie cleanup even when skipping tally — stale voteRegistry keys
        # accumulate when the system is quiescent and no new proposals are posted.
        cleanup_zombie_vote_registry_keys
        return 0
    fi
    echo "[$(date -u +%H:%M:%S)] Loaded $thought_count thoughts for tally (since ${tally_cutoff_ts:-epoch})"

    # Extract all unique proposal topics from #proposal-<topic> tags
    local topics
    topics=$(jq -r '.[] | select(.type == "proposal") | .content' "$thoughts_file" \
        | grep -oE '#proposal-[a-zA-Z0-9_-]+' \
        | sed 's/#proposal-//' \
        | sort -u 2>/dev/null || true)

    if [ -z "$topics" ]; then
        echo "[$(date -u +%H:%M:%S)] No active proposals found"
        # Issue #1719: Run zombie cleanup even when no active proposals — old voteRegistry
        # entries from expired proposals must still be cleaned up.
        cleanup_zombie_vote_registry_keys
        return 0
    fi

    # Issue #1398: Read enacted decisions ONCE before the loop and maintain in-memory.
    # This prevents read-modify-write race condition where later topics read stale enacted
    # (before earlier topics' writes propagate), causing them to overwrite each other's entries.
    local loop_enacted
    loop_enacted=$(get_state "enactedDecisions")
    [ -z "$loop_enacted" ] && loop_enacted=""

    # Process each topic
    while IFS= read -r topic; do
        [ -z "$topic" ] && continue

        # Issue #1407: Early skip — if any decision for this topic was already enacted,
        # AND no new votes have appeared (time-window filtered), skip expensive tallying.
        # This prevents the coordinator from re-tallying 39+ circuit-breaker votes every cycle.
        # We still process topics with recent votes (within tally_cutoff_ts window).
        #
        # Issue #1591: For vision-feature/vision-queue topics, the early skip must NOT block
        # new addIssue proposals just because a prior issue was enacted. Each addIssue=<N>
        # gets its own decision_key (enacted_topic_<topic>_add_<N>), so a new proposal for
        # a different issue should always be tallied. Only skip when the topic check is not
        # a vision-feature/vision-queue topic (which use per-issue keys).
        local is_vision_topic=false
        if [[ "$topic" == *"vision-feature"* || "$topic" == *"vision-queue"* ]]; then
            is_vision_topic=true
        fi
        if [ "$is_vision_topic" = false ] && echo "$loop_enacted" | grep -qF "enacted_topic_${topic}"; then
            # Topic has prior enactments. Check if there are ANY new votes since the LAST TALLY RUN.
            # Issue #1798: Use recent_tally_cutoff_ts (tight window since last tally) instead of
            # the full thoughts_file window (up to 24h). The 24h window contains old votes for
            # enacted topics, causing the early skip to never fire and processing 125+ topics × 5s
            # per tally cycle (10+ min/cycle). The tight window ensures only genuinely new activity
            # triggers re-processing.
            local new_votes_for_topic
            if [ -n "$recent_tally_cutoff_ts" ]; then
                new_votes_for_topic=$(jq -r --arg cutoff "$recent_tally_cutoff_ts" \
                    ".[] | select(.type == \"vote\" and .ts >= \$cutoff and (.content | contains(\"#vote-$topic\"))) | .ts" \
                    "$thoughts_file" 2>/dev/null | wc -l | tr -d ' ')
            else
                new_votes_for_topic=$(jq -r ".[] | select(.type == \"vote\" and (.content | contains(\"#vote-$topic\"))) | .ts" \
                    "$thoughts_file" 2>/dev/null | wc -l | tr -d ' ')
            fi
            if [ "$new_votes_for_topic" -eq 0 ]; then
                echo "[$(date -u +%H:%M:%S)] $topic already enacted and no new votes since last tally — skipping"
                continue
            fi
        fi
        
        echo "[$(date -u +%H:%M:%S)] Processing governance topic: $topic"
        
        # Check that at least one proposal exists for this topic
        # (needed to verify the topic is actually proposed before tallying votes)
        local any_proposal
        any_proposal=$(jq -r ".[] | select(.type == \"proposal\" and (.content | contains(\"#proposal-$topic\"))) | .content" \
            "$thoughts_file" 2>/dev/null \
            | grep "^#proposal-${topic}" | head -1 || true)

        # Issue #1711: If no proposal found in the time-window filtered thoughts_file,
        # do a full-history scan for this specific topic's proposal. This handles the case
        # where a proposal was posted before the tally cutoff but is still receiving new votes.
        # Without this fallback, any proposal older than ~lastTallyTimestamp is silently skipped
        # even with 18+ approve votes — breaking governance enactment for older proposals.
        if [ -z "$any_proposal" ]; then
            any_proposal=$(kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" -l agentex/thought \
                -o json 2>/dev/null \
                | jq -r ".items[] | select(.data.thoughtType == \"proposal\") | .data.content" \
                | grep "^#proposal-${topic}" | head -1 || true)
            [ -n "$any_proposal" ] && echo "[$(date -u +%H:%M:%S)] $topic: proposal not in time window — found via full-history scan (issue #1711)"
        fi

        [ -z "$any_proposal" ] && continue

        # Count unique approve/reject/abstain votes for this topic (must be done before kv_pairs
        # so we can use approve votes to determine the majority-voted KV values — issue #1286)
        local approve_votes
        approve_votes=$(jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"approve\")))) | .agent" \
            "$thoughts_file" 2>/dev/null | sort -u | wc -l | tr -d ' ')

        local reject_votes
        reject_votes=$(jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"reject\")))) | .agent" \
            "$thoughts_file" 2>/dev/null | sort -u | wc -l | tr -d ' ')

        local abstain_votes
        abstain_votes=$(jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"abstain\")))) | .agent" \
            "$thoughts_file" 2>/dev/null | sort -u | wc -l | tr -d ' ')

        echo "[$(date -u +%H:%M:%S)] Vote tally — $topic: approve=$approve_votes reject=$reject_votes abstain=$abstain_votes threshold=$VOTE_THRESHOLD"

        # Extract key=value pairs using majority-vote approach (issue #1286 fix)
        # Problem: old code used `tail -1` (most-recent proposal) — caused wrong values when
        # multiple proposals exist with conflicting values (e.g., limit=5 vs limit=12).
        # Fix: tally KV values across all APPROVE VOTES, use the most-common value per key.
        # This ensures the enacted value reflects actual voter preference, not filing order.
        #
        # Algorithm:
        # 1. Extract all KV pairs from all approve-vote content lines for this topic
        # 2. For each unique key, count occurrences of each value (by line, not by voter)
        # 3. Pick the value with the highest count per key
        # 4. Fall back to most-recent proposal's values for keys not present in votes
        #
        # Example: votes include "circuitBreakerLimit=12" (20 times) and "circuitBreakerLimit=5" (1 time)
        # → enacted value = 12 (majority)
        local kv_pairs=""
        if [ "$approve_votes" -gt 0 ]; then
            # Get all approve vote content, extract kv pairs from #vote-<topic> lines only
            local vote_kvs
            vote_kvs=$(jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"approve\")))) | .content" \
                "$thoughts_file" 2>/dev/null \
                | grep "^#vote-${topic}" \
                | grep -oE '[a-zA-Z0-9_]+=[a-zA-Z0-9_.-]+' || true)

            if [ -n "$vote_kvs" ]; then
                # For each unique key, find the majority value
                local all_keys
                all_keys=$(echo "$vote_kvs" | awk -F= '{print $1}' | sort -u)
                while IFS= read -r key; do
                    [ -z "$key" ] && continue
                    # Skip metadata keys that aren't real config values
                    [ "$key" = "reason" ] && continue
                    [ "$key" = "proposalRef" ] && continue
                    # Count occurrences of each value for this key
                    local majority_val
                    majority_val=$(echo "$vote_kvs" | grep "^${key}=" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}' | cut -d= -f2-)
                    if [ -n "$majority_val" ]; then
                        kv_pairs="${kv_pairs:+$kv_pairs }${key}=${majority_val}"
                    fi
                done <<< "$all_keys"
            fi
        fi

        # Fall back to most-recent proposal's values for keys not covered by votes
        # (e.g., if no votes include the KV, use the proposal as the reference)
        local proposal_content
        proposal_content=$(jq -r ".[] | select(.type == \"proposal\" and (.content | contains(\"#proposal-$topic\"))) | .content" \
            "$thoughts_file" 2>/dev/null \
            | grep "^#proposal-${topic}" | tail -1 || true)
        if [ -n "$proposal_content" ]; then
            local proposal_kvs
            proposal_kvs=$(echo "$proposal_content" | grep -oE '[a-zA-Z0-9_]+=[a-zA-Z0-9_.-]+' || true)
            while IFS= read -r pkv; do
                [ -z "$pkv" ] && continue
                local pkey="${pkv%%=*}"
                [ "$pkey" = "reason" ] && continue
                # Only add proposal KV if not already set by majority vote
                if ! echo "$kv_pairs" | grep -q "^${pkey}=\|[[:space:]]${pkey}="; then
                    kv_pairs="${kv_pairs:+$kv_pairs }${pkv}"
                fi
            done <<< "$proposal_kvs"
        fi
        
        # Emit metrics (vote counts were tallied above, before kv_pairs extraction)
        push_metric "VoteCount" "$approve_votes" "Count" "Topic=${topic},VoteType=Approve"
        push_metric "VoteCount" "$reject_votes" "Count" "Topic=${topic},VoteType=Reject"
        push_metric "VoteCount" "$abstain_votes" "Count" "Topic=${topic},VoteType=Abstain"

        # Update vote registry (multi-topic support)
        local registry_entry="$topic: approve=$approve_votes reject=$reject_votes abstain=$abstain_votes"
        update_state "voteRegistry_${topic}" "$registry_entry"

        # Check if already enacted (Issue #1398: use in-memory loop_enacted to prevent
        # read-modify-write race condition; also normalize decision_key to topic-only
        # so different kv_pairs values for the same topic don't bypass dedup).
        # decision_key uses topic only — governance enacts once per topic per civilization cycle.
        #
        # Issue #1591: For vision-feature/vision-queue topics, use per-issue decision_key
        # so each addIssue=<N> can be enacted independently. Without this, once any issue
        # is added to visionQueue the entire vision-feature topic is blocked forever.
        local decision_key="enacted_topic_${topic}"
        if [[ "$topic" == *"vision-feature"* || "$topic" == *"vision-queue"* ]]; then
            # Extract addIssue value from kv_pairs to build a per-issue decision key
            local add_issue_for_key
            add_issue_for_key=$(echo "$kv_pairs" | tr ' ' '\n' | grep -E '^(addIssue|issueNumber)=[0-9]+' | head -1 | cut -d= -f2 || echo "")
            if [ -n "$add_issue_for_key" ]; then
                decision_key="enacted_topic_${topic}_add_${add_issue_for_key}"
                echo "[$(date -u +%H:%M:%S)] vision topic: using per-issue decision_key=${decision_key}"
            fi
        fi
        
        if echo "$loop_enacted" | grep -qF "$decision_key"; then
            echo "[$(date -u +%H:%M:%S)] $topic already enacted, skipping"
            continue
        fi

        # ISSUE #747 FIX: Validate that votes exist before enacting
        # Safety check: ensure we have at least SOME votes (approve + reject + abstain > 0)
        # This prevents enactment when vote counting silently fails
        local total_votes=$((approve_votes + reject_votes + abstain_votes))
        if [ "$total_votes" -eq 0 ]; then
            echo "[$(date -u +%H:%M:%S)] SAFETY: $topic has ZERO votes (approve=$approve_votes reject=$reject_votes abstain=$abstain_votes). Cannot enact without votes."
            push_metric "GovernanceBlocked" 1 "Count" "Topic=${topic},Reason=NoVotes"
            continue
        fi

        # ISSUE #747 FIX: god-delegate proposals require explicit agent votes
        # God-delegate proposals are often tests or provocations for debate.
        # They should NOT be auto-enacted even if they reach threshold.
        local proposer_agent
        proposer_agent=$(jq -r ".[] | select(.type == \"proposal\" and (.content | contains(\"#proposal-$topic\"))) | .agent" \
            "$thoughts_file" | tail -1 || echo "unknown")
        
        if [[ "$proposer_agent" == god-delegate-* ]]; then
            echo "[$(date -u +%H:%M:%S)] SAFETY: $topic proposed by $proposer_agent (god-delegate). Requires 4+ approve votes (raised threshold for god proposals)."
            # God proposals require higher threshold (4 instead of 3) to ensure strong consensus
            local god_threshold=4
            if [ "$approve_votes" -lt "$god_threshold" ]; then
                echo "[$(date -u +%H:%M:%S)] SAFETY: $topic has $approve_votes approvals, needs $god_threshold for god-delegate proposal. Not enacting."
                push_metric "GovernanceBlocked" 1 "Count" "Topic=${topic},Reason=GodProposalInsufficientVotes"
                continue
            fi
        fi

        # ISSUE #1248: Vision-feature proposals require DELIBERATION — not just votes.
        # Civilization goal-changes must be debated before they can be enacted.
        # Enforcement: (1) reasoned votes (votes with reason= OR reason: clause), (2) debate responses.
        if [[ "$topic" == *"vision-feature"* || "$topic" == *"vision-queue"* ]]; then
            # Count votes that include a reason= or reason: clause.
            # Issue #1649: AGENTS.md instructs agents to use "reason: ..." format (colon),
            # but the original check used grep -c "reason=" (equals only). This caused ALL
            # reasoned votes to count as 0, permanently blocking vision proposals.
            # Fix: use "reason[=:]" to accept both formats.
            local reasoned_votes
            reasoned_votes=$(jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"approve\")))) | .content" \
                "$thoughts_file" 2>/dev/null | grep -c "reason[=:]" || true)
            [ -z "$reasoned_votes" ] && reasoned_votes=0

            # Count debate responses (thoughts of type "debate") that mention this topic or vision
            local debate_responses
            debate_responses=$(jq -r ".[] | select(.type == \"debate\" and (.content | (test(\"vision|$topic\"; \"i\") or test(\"DEBATE\"; \"\")))) | .agent" \
                "$thoughts_file" 2>/dev/null | sort -u | wc -l | tr -d ' ')
            [ -z "$debate_responses" ] && debate_responses=0

            local vision_threshold_met=true
            local vision_block_reason=""

            if [ "$reasoned_votes" -lt 2 ]; then
                vision_threshold_met=false
                vision_block_reason="vision-feature requires at least 2 reasoned votes (with reason= or reason: clause), found $reasoned_votes"
            elif [ "$debate_responses" -lt 1 ]; then
                vision_threshold_met=false
                vision_block_reason="vision-feature requires at least 1 debate response, found $debate_responses"
            fi

            if [ "$vision_threshold_met" = false ]; then
                echo "[$(date -u +%H:%M:%S)] VISION-FEATURE DELIBERATION BLOCK: $vision_block_reason"
                echo "[$(date -u +%H:%M:%S)] Votes: approve=$approve_votes (reasoned=$reasoned_votes) debates=$debate_responses"
                push_metric "GovernanceBlocked" 1 "Count" "Topic=${topic},Reason=InsufficientDeliberation"

                # Post a nudge thought to signal agents must debate before this can pass
                kubectl_with_timeout 10 apply -f - <<NUDGE_EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-coordinator-nudge-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  agentRef: coordinator
  taskRef: coordinator-loop
  thoughtType: insight
  confidence: 9
  content: |
    GOVERNANCE NUDGE: #proposal-${topic} has ${approve_votes} votes but needs deliberation.
    Blocked: ${vision_block_reason}
    To unblock: post a #vote-${topic} approve reason=<your reasoning> AND
    engage in debate (thoughtType=debate) about this vision change.
    Civilization goal-changes require deliberation, not just votes.
NUDGE_EOF
                continue
            fi

            echo "[$(date -u +%H:%M:%S)] Vision-feature deliberation check PASSED: reasoned_votes=$reasoned_votes debate_responses=$debate_responses"
        fi

        # Enact if threshold reached
        if [ "$approve_votes" -ge "$VOTE_THRESHOLD" ]; then
            echo "[$(date -u +%H:%M:%S)] *** CONSENSUS REACHED: $topic (${approve_votes} approvals) ***"
            
            # ISSUE #747 FIX: Enhanced audit logging before enactment
            echo "[$(date -u +%H:%M:%S)] AUDIT: Enacting governance decision"
            echo "[$(date -u +%H:%M:%S)] AUDIT:   Topic: $topic"
            echo "[$(date -u +%H:%M:%S)] AUDIT:   Proposer: $proposer_agent"
            echo "[$(date -u +%H:%M:%S)] AUDIT:   Vote tally: ${approve_votes} approve, ${reject_votes} reject, ${abstain_votes} abstain"
            echo "[$(date -u +%H:%M:%S)] AUDIT:   Threshold: $VOTE_THRESHOLD (met: YES)"
            echo "[$(date -u +%H:%M:%S)] AUDIT:   Changes: $kv_pairs"
            
            # Get list of agents who voted
            local approvers
            approvers=$(jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"approve\")))) | .agent" \
                "$thoughts_file" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//' || echo "unknown")
            local rejectors
            rejectors=$(jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"reject\")))) | .agent" \
                "$thoughts_file" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//' || echo "none")
            
            echo "[$(date -u +%H:%M:%S)] AUDIT:   Approvers: $approvers"
            echo "[$(date -u +%H:%M:%S)] AUDIT:   Rejectors: $rejectors"
            
            push_metric "ConsensusEnacted" 1 "Count" "Topic=${topic}"

            # ── Vision Queue governance handler (issue #1219) ──────────────────────────
            # For vision-feature and vision-queue proposals, add the issue to visionQueue
            # instead of patching the constitution. This enables agent collective self-direction.
            # Proposal format: "#proposal-vision-feature addIssue=<N> reason=<why>"
            # or:               "#proposal-vision-queue addIssue=<N> reason=<why>"
            local vision_queue_patched=false
            if [[ "$topic" == *"vision-feature"* || "$topic" == *"vision-queue"* ]]; then
                local add_issue=""
                while IFS= read -r kv; do
                    [ -z "$kv" ] && continue
                    local kv_key="${kv%%=*}"
                    local kv_val="${kv##*=}"
                    # Issue #1311: Accept both addIssue= and issueNumber= formats
                    if [[ "$kv_key" = "addIssue" || "$kv_key" = "issueNumber" ]] && [[ "$kv_val" =~ ^[0-9]+$ ]]; then
                        add_issue="$kv_val"
                        break
                    fi
                done <<< "$kv_pairs"

                 if [ -n "$add_issue" ]; then
                     # Issue #1436: Validate issue is OPEN before adding to visionQueue
                      local add_issue_state
                      # Issue #1578: Use REST API to avoid GraphQL rate-limit failures.
                      # ascii_upcase normalizes REST ("open"/"closed") to match comparison values.
                      add_issue_state=$(gh api "repos/${GITHUB_REPO}/issues/${add_issue}" \
                          --jq '.state | ascii_upcase' 2>/dev/null || echo "unknown")
                     if [ "$add_issue_state" != "OPEN" ]; then
                         echo "[$(date -u +%H:%M:%S)] VISION-FEATURE: issue #$add_issue is $add_issue_state — skipping visionQueue add"
                     else

                     local current_vq
                     current_vq=$(kubectl_with_timeout 10 get configmap "$STATE_CM" -n "$NAMESPACE" \
                         -o jsonpath='{.data.visionQueue}' 2>/dev/null || echo "")

                     # Deduplication: only add if not already present
                     # Issue #1444: Use semicolon separator for consistency with vision-queue topic
                     if echo ";${current_vq};" | grep -q ";${add_issue};"; then
                         echo "[$(date -u +%H:%M:%S)] visionQueue: issue #$add_issue already present, skipping"
                     else
                         local new_vq="${current_vq:+$current_vq;}${add_issue}"
                        kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" \
                            --type=merge \
                            -p "{\"data\":{\"visionQueue\":\"$new_vq\"}}" \
                            && echo "[$(date -u +%H:%M:%S)] ✓ visionQueue updated: issue #$add_issue added (visionQueue=$new_vq)" \
                            || echo "[$(date -u +%H:%M:%S)] ERROR: Failed to update visionQueue"

                        # Append to visionQueueLog for audit trail
                        local ts_log
                        ts_log=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                        local current_vql
                        current_vql=$(kubectl_with_timeout 10 get configmap "$STATE_CM" -n "$NAMESPACE" \
                            -o jsonpath='{.data.visionQueueLog}' 2>/dev/null || echo "")
                        local log_entry="${ts_log} issue=${add_issue} votes=${approve_votes} proposer=${proposer_agent}"
                        local new_vql="${current_vql:+$current_vql;}$log_entry"
                        kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" \
                            --type=merge \
                            -p "{\"data\":{\"visionQueueLog\":\"$new_vql\"}}" 2>/dev/null || true
                         echo "[$(date -u +%H:%M:%S)] ✓ visionQueueLog updated"
                     fi
                     vision_queue_patched=true
                     fi  # end open-state validation
                 else
                     echo "[$(date -u +%H:%M:%S)] WARNING: vision-feature/vision-queue proposal missing addIssue=<N> — cannot enact"
                 fi
            fi
            # ── End vision queue handler ───────────────────────────────────────────────

            # Try to patch constitution for known keys
            local patched=false
            if [ -n "$kv_pairs" ] && [ "$vision_queue_patched" = false ]; then
                # Build JSON patch for all key=value pairs
                local patch_data="{"
                local first=true
                while IFS= read -r kv; do
                    [ -z "$kv" ] && continue
                    local key="${kv%%=*}"
                    local value="${kv##*=}"
                    
                    # Check if this is a known constitution key
                    case "$key" in
                        circuitBreakerLimit|minimumVisionScore|jobTTLSeconds|voteThreshold)
                            [ "$first" = false ] && patch_data="${patch_data},"
                            patch_data="${patch_data}\"${key}\":\"${value}\""
                            first=false
                            patched=true
                            ;;
                    esac
                done <<< "$kv_pairs"
                patch_data="${patch_data}}"

                # Issue #1149: vision-feature topic adds voted issue to visionQueue
                # Agents propose: #proposal-vision-feature issueNumber=1149
                # When 3+ approve, coordinator adds it to visionQueue with vote count
                # Format: "issueNumber:voteCount" pairs, coordinator reads this BEFORE taskQueue
                # Issue #1311: Use glob matching for topic variants (v03-vision-queue, etc.)
                 if [[ "$topic" == *"vision-feature"* ]]; then
                     local vision_issue
                     # Issue #1311: Accept both issueNumber= and addIssue= formats
                     vision_issue=$(echo "$kv_pairs" | grep -oE '(issueNumber|addIssue)=[0-9]+' | head -1 | cut -d= -f2 || echo "")
                     if [ -n "$vision_issue" ]; then
                         # Issue #1436: Validate issue is OPEN before adding to visionQueue
                          local vision_issue_state
                          # Issue #1578: Use REST API to avoid GraphQL rate-limit failures.
                          # ascii_upcase normalizes REST ("open"/"closed") to match comparison values.
                          vision_issue_state=$(gh api "repos/${GITHUB_REPO}/issues/${vision_issue}" \
                              --jq '.state | ascii_upcase' 2>/dev/null || echo "unknown")
                         if [ "$vision_issue_state" != "OPEN" ]; then
                             echo "[$(date -u +%H:%M:%S)] VISION QUEUE: issue #$vision_issue is $vision_issue_state — skipping visionQueue add"
                             patched=true
                         else
                         local current_vq
                         current_vq=$(get_state "visionQueue")
                         local new_entry="${vision_issue}"
                         # Issue #1444: Use semicolon separator; only add if not already in visionQueue
                         if ! echo ";${current_vq};" | grep -q ";${vision_issue};"; then
                             if [ -z "$current_vq" ]; then
                                 update_state "visionQueue" "$new_entry"
                             else
                                 update_state "visionQueue" "${current_vq};${new_entry}"
                             fi
                             echo "[$(date -u +%H:%M:%S)] ✓ VISION QUEUE: Added issue #$vision_issue (${approve_votes} votes) to visionQueue"
                             patched=true
                         else
                             echo "[$(date -u +%H:%M:%S)] VISION QUEUE: Issue #$vision_issue already in visionQueue, skipping"
                             patched=true
                         fi
                         fi  # end open-state validation
                     fi
                 fi

                if [ "$patched" = true ]; then
                    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
                    kubectl_with_timeout 10 patch configmap agentex-constitution -n "$NAMESPACE" \
                        --type=merge \
                        -p "{\"data\":${patch_data}}" \
                        && echo "[$(date -u +%H:%M:%S)] ✓ Constitution patched: $kv_pairs" \
                        || echo "[$(date -u +%H:%M:%S)] ERROR: Failed to patch constitution"
                    
                    # Issue #1059: Reload voteThreshold from constitution if it was just updated
                    if echo "$kv_pairs" | grep -q "voteThreshold="; then
                        local new_threshold
                        new_threshold=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
                            -o jsonpath='{.data.voteThreshold}' 2>/dev/null || echo "")
                        if [ -n "$new_threshold" ] && [[ "$new_threshold" =~ ^[0-9]+$ ]]; then
                            VOTE_THRESHOLD="$new_threshold"
                            echo "[$(date -u +%H:%M:%S)] ✓ VOTE_THRESHOLD updated to $VOTE_THRESHOLD (governance-enacted)"
                        fi
                    fi
                    
                    # ISSUE #893: Sync constitution.yaml in git after enacting governance decision
                    # This prevents git repo from drifting out of sync with cluster ConfigMap
                    sync_constitution_to_git "$kv_pairs" "$topic" "$approve_votes"
                fi
            fi

            # ISSUE #1248: Special handling for vision-feature proposals
            # When topic is "vision-feature" and addIssue=N in kv_pairs, automatically update
            # coordinator-state.visionQueue. Also enforce debate threshold: require at least
            # 1 reasoned vote (containing reason= clause) to prevent rubber-stamp enactment.
            # Issue #1311: Use glob matching to catch variants like v03-vision-feature, vision-feature-mentorship
            if [[ "$topic" == *"vision-feature"* ]]; then
                # Check debate threshold: count votes with reason= clause (reasoned votes)
                local reasoned_votes
                reasoned_votes=$(jq -r ".[] | select(.type == \"vote\" and (.content | contains(\"#vote-$topic\"))) | select(.content | test(\"reason=\"; \"i\")) | .agent" \
                    "$thoughts_file" 2>/dev/null | sort -u | wc -l | tr -d ' ')

                echo "[$(date -u +%H:%M:%S)] VISION-FEATURE: topic=$topic reasoned_votes=${reasoned_votes} (threshold: 1)"

                if [ "${reasoned_votes:-0}" -lt 1 ]; then
                    echo "[$(date -u +%H:%M:%S)] VISION-FEATURE BLOCKED: needs at least 1 reasoned vote (reason= clause). Got ${reasoned_votes:-0}."
                    post_coordinator_thought "VISION-FEATURE BLOCKED: $topic has ${approve_votes} approvals but ${reasoned_votes:-0} reasoned votes. Requires at least 1 vote with 'reason=' to prevent rubber-stamping. Add reasoning to your vote." "verdict"
                    continue
                fi

                # Extract addIssue value from kv_pairs (issue number format)
                local add_issue
                add_issue=$(echo "$kv_pairs" | tr ' ' '\n' | grep "^addIssue=" | cut -d= -f2 | head -1 || echo "")
                 if [ -n "$add_issue" ] && [[ "$add_issue" =~ ^[0-9]+$ ]]; then
                     # Issue #1436: Validate issue is OPEN before adding to visionQueue
                      local add_issue_open_state
                      # Issue #1578: Use REST API to avoid GraphQL rate-limit failures.
                      # ascii_upcase normalizes REST ("open"/"closed") to match comparison values.
                      add_issue_open_state=$(gh api "repos/${GITHUB_REPO}/issues/${add_issue}" \
                          --jq '.state | ascii_upcase' 2>/dev/null || echo "unknown")
                     if [ "$add_issue_open_state" != "OPEN" ]; then
                         echo "[$(date -u +%H:%M:%S)] VISION-FEATURE: issue #$add_issue is $add_issue_open_state — skipping visionQueue add"
                     else
                     # Read current visionQueue
                     local vision_queue
                     vision_queue=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
                         -o jsonpath='{.data.visionQueue}' 2>/dev/null || echo "")

                     # Check if issue already in queue
                     # Issue #1455: Use semicolon separator (consistent with all other visionQueue handlers)
                     if echo ";$vision_queue;" | grep -q ";$add_issue;"; then
                         echo "[$(date -u +%H:%M:%S)] VISION-FEATURE: issue #$add_issue already in visionQueue ($vision_queue)"
                     else
                         # Add to queue
                         local new_vision_queue
                         if [ -z "$vision_queue" ]; then
                             new_vision_queue="$add_issue"
                         else
                             new_vision_queue="${vision_queue};${add_issue}"
                         fi
                         kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
                             --type=merge \
                             -p "{\"data\":{\"visionQueue\":\"${new_vision_queue}\"}}" \
                             && echo "[$(date -u +%H:%M:%S)] ✓ VISION-FEATURE: added issue #$add_issue to visionQueue (was: ${vision_queue:-empty}, now: $new_vision_queue)" \
                             || echo "[$(date -u +%H:%M:%S)] ERROR: Failed to update visionQueue for vision-feature $topic"
                         patched=true
                     fi
                     fi  # end open-state validation
                else
                    # Named feature format (issue #1149): feature=<name> description=<desc>
                    local feature_name feature_desc vision_entry
                    feature_name=$(echo "$kv_pairs" | grep -oE 'feature=[^ ]+' | cut -d'=' -f2-)
                    feature_desc=$(echo "$kv_pairs" | grep -oE 'description=[^ ]+' | cut -d'=' -f2-)
                    [ -z "$feature_name" ] && feature_name="unnamed-feature-$(date +%s)"
                    [ -z "$feature_desc" ] && feature_desc=""
                    vision_entry="${feature_name}:${feature_desc}"
                    local current_vision_queue
                    current_vision_queue=$(get_state "visionQueue")
                    if [ -z "$current_vision_queue" ]; then
                        update_state "visionQueue" "$vision_entry"
                    else
                        if ! echo "$current_vision_queue" | grep -qF "${feature_name}:"; then
                            update_state "visionQueue" "${current_vision_queue};${vision_entry}"
                        fi
                    fi
                    patched=true
                    echo "[$(date -u +%H:%M:%S)] ✓ visionQueue updated with agent-proposed feature: $feature_name"
                    push_metric "VisionQueueUpdated" 1 "Count" "Feature=${feature_name}"
                fi
            fi

            # ── VISION-QUEUE GOVERNANCE (issue #1149) ──────────────────────────────
            # When agents reach consensus on a #proposal-vision-queue, add the
            # proposed feature to coordinator-state.visionQueue so planners will
            # prioritize it — enabling the civilization to SET ITS OWN GOALS.
            # Issue #1311: Use glob matching to catch variants like v03-vision-queue
            if [[ "$topic" == *"vision-queue"* ]]; then
                local vq_feature=""
                local vq_description=""
                while IFS= read -r kv; do
                    [ -z "$kv" ] && continue
                    local k="${kv%%=*}"
                    local v="${kv##*=}"
                    case "$k" in
                        feature) vq_feature="$v" ;;
                        description) vq_description="$v" ;;
                    esac
                done <<< "$kv_pairs"

                if [ -n "$vq_feature" ]; then
                    local ts_vq
                    ts_vq=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                    local vq_entry="${vq_feature}:${vq_description:-no-description}:${ts_vq}:${proposer_agent}"

                    local current_vq
                    current_vq=$(get_state "visionQueue")
                    local new_vq
                    if [ -z "$current_vq" ]; then
                        new_vq="$vq_entry"
                    else
                        new_vq="${current_vq};${vq_entry}"
                    fi
                    update_state "visionQueue" "$new_vq"

                    # Audit log
                    local vq_log_entry="${ts_vq} ADDED feature=${vq_feature} votes=${approve_votes} proposer=${proposer_agent}"
                    local current_vq_log
                    current_vq_log=$(get_state "visionQueueLog")
                    if [ -z "$current_vq_log" ]; then
                        update_state "visionQueueLog" "$vq_log_entry"
                    else
                        update_state "visionQueueLog" "${current_vq_log} | ${vq_log_entry}"
                    fi

                    push_metric "VisionQueueAdded" 1 "Count" "Feature=${vq_feature}"
                    echo "[$(date -u +%H:%M:%S)] VISION-QUEUE: Added feature '${vq_feature}' to vision queue (${approve_votes} votes, proposer=${proposer_agent})"
                    patched=true
                else
                    echo "[$(date -u +%H:%M:%S)] VISION-QUEUE: Proposal missing 'feature=' key — cannot add to vision queue"
                fi
            fi

            # Record the enacted decision with full audit trail
            # Issue #1398: store decision_key (topic-based), approvals count, proposer, timestamp.
            # Truncate voters list and sanitize newlines to prevent JSON encoding failures in update_state.
            # kv_pairs can contain embedded newlines (multi-line grep output) which break kubectl patch JSON.
            local ts
            ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            # Strip newlines from proposer_agent (safety - proposer_agent is typically single-line)
            # Issue #1501: Use printf '%s' instead of echo to avoid trailing space from echo's newline.
            local safe_proposer
            safe_proposer=$(printf '%s' "$proposer_agent" | tr '\n' ' ' | tr -s ' ')
            local enacted_entry="${ts} ${decision_key} approvals=${approve_votes} rejections=${reject_votes} proposer=${safe_proposer}"
            if [ -z "$loop_enacted" ]; then
                loop_enacted="$enacted_entry"
            else
                loop_enacted="${loop_enacted} | ${enacted_entry}"
            fi
            update_state "enactedDecisions" "$loop_enacted"
            
            echo "[$(date -u +%H:%M:%S)] AUDIT: Decision recorded in enactedDecisions log"

            # Post verdict Thought CR
            local verdict_text
            if [ "$vision_queue_patched" = true ]; then
                verdict_text="VISION QUEUE ENACTED: $topic
Votes: ${approve_votes} approve, ${reject_votes} reject, ${abstain_votes} abstain (threshold: ${VOTE_THRESHOLD})
Changes: $kv_pairs
Issue added to visionQueue at ${ts}. Planners will prioritize this issue above taskQueue.
Vision score: 10/10 — civilization is self-directing its future."
            elif [ "$patched" = true ]; then
                verdict_text="CONSENSUS ENACTED: $topic
Votes: ${approve_votes} approve, ${reject_votes} reject, ${abstain_votes} abstain (threshold: ${VOTE_THRESHOLD})
Changes: $kv_pairs
Constitution automatically patched at ${ts}.
All future agents will use these values."
            else
                verdict_text="CONSENSUS REACHED: $topic
Votes: ${approve_votes} approve, ${reject_votes} reject, ${abstain_votes} abstain (threshold: ${VOTE_THRESHOLD})
Proposal details: $kv_pairs
This topic is not auto-patchable. An agent must implement it via PR.
Vision score: 9/10 — prioritize implementation."
            fi

            post_coordinator_thought "$verdict_text" "verdict"
            log_decision "$topic: $kv_pairs" "consensus vote: ${approve_votes} approve ${reject_votes} reject ${abstain_votes} abstain"

            # Issue #1650: Remove the voteRegistry_<topic> key after enaction.
            # Vote tallies are persisted in enactedDecisions and verdict Thought CRs.
            # Keeping stale voteRegistry keys causes coordinator-state to grow indefinitely
            # (47+ entries observed, growing with each governance proposal).
            remove_state "voteRegistry_${topic}"
            echo "[$(date -u +%H:%M:%S)] GOVERNANCE: Cleaned up voteRegistry_${topic} after enaction"

            echo "[$(date -u +%H:%M:%S)] GOVERNANCE: Consensus enacted for $topic"

        # Issue #1696: Cleanup definitively REJECTED proposals (reject >= threshold).
        # Once reject_votes reach the threshold, the proposal can never be enacted.
        # Remove the voteRegistry key to prevent coordinator-state growing indefinitely.
        elif [ "${reject_votes:-0}" -ge "$VOTE_THRESHOLD" ]; then
            echo "[$(date -u +%H:%M:%S)] GOVERNANCE: $topic definitively REJECTED (reject=$reject_votes >= threshold=$VOTE_THRESHOLD). Cleaning up."
            post_coordinator_thought "GOVERNANCE: Proposal #proposal-${topic} definitively rejected (reject_votes=${reject_votes} >= threshold=${VOTE_THRESHOLD}). voteRegistry key removed. A new proposal can re-open this topic." "verdict"
            remove_state "voteRegistry_${topic}"
            echo "[$(date -u +%H:%M:%S)] GOVERNANCE: Cleaned up voteRegistry_${topic} after rejection"
        fi
    done <<< "$topics"

    # Issue #1696/#1719: Cleanup zombie voteRegistry_* keys — proposals that had voteRegistry
    # entries created but whose proposal Thought CRs have since been deleted by the 24h TTL.
    # Delegated to cleanup_zombie_vote_registry_keys() which is also called at early return
    # points above (issue #1719: zombie cleanup was previously skipped by early returns).
    cleanup_zombie_vote_registry_keys
}

# record_synthesis_debates_to_s3: Write synthesis debate thoughts to S3 for collective memory
# Issue #1161: Coordinator is the authoritative S3 writer for debate outcomes because it sees
# ALL synthesis thoughts, including manually-posted ones that bypass post_debate_response().
#
# Thread ID: sha256(parentRef)[0:16] — same algorithm as post_debate_response() in entrypoint.sh
# S3 path: s3://${IDENTITY_BUCKET}/debates/<thread_id>.json
# Idempotent: skips threads already written to S3
record_synthesis_debates_to_s3() {
    local s3_bucket="${IDENTITY_BUCKET:-agentex-thoughts}"
    local namespace="${NAMESPACE:-agentex}"
    # Issue #1585: Limit per-cycle S3 writes to prevent coordinator from blocking the main loop.
    # Previously, 200+ synthesis debates caused 5-10 minute outages as each write is sequential.
    # With limit=20 per cycle and 30s heartbeat interval, all debates are recorded within ~5 min.
    local max_writes_per_cycle=20

    # Fetch synthesis debate thoughts with FULL content (not truncated)
    local synthesis_thoughts
    synthesis_thoughts=$(kubectl_with_timeout 10 get configmaps -n "$namespace" -l agentex/thought -o json 2>/dev/null \
        | jq -r '[.items[] | select(.data.thoughtType == "debate") |
            select((.data.content // "") | test("synthes(is|ize)"; "i")) |
            {
                name: .metadata.name,
                parent: (.data.parentRef // ""),
                agent: (.data.agentRef // ""),
                content: (.data.content // ""),
                timestamp: .metadata.creationTimestamp
            }]' 2>/dev/null) || return 0

    [ -z "$synthesis_thoughts" ] || [ "$synthesis_thoughts" = "null" ] || [ "$synthesis_thoughts" = "[]" ] && return 0

    local synth_count
    synth_count=$(echo "$synthesis_thoughts" | jq 'length' 2>/dev/null || echo "0")
    echo "[$(date -u +%H:%M:%S)] Checking $synth_count synthesis debates for S3 persistence (max $max_writes_per_cycle new writes per cycle)"

    # Issue #1625: Prefetch all existing debate thread IDs with a SINGLE S3 LIST call before the loop.
    # Previous approach (issue #1606 fix) made one aws s3 ls per debate inside the loop —
    # with 250+ debates that is still ~250 LIST API calls per 2.5-minute cycle (~144,000/day, ~$0.07/day).
    # Fix: one prefix LIST outside the loop, then grep for membership (zero API calls per debate).
    # S3 LIST cost: $0.0004/1000 calls → 576 prefix LIST calls/day = ~$0.0002/day (negligible).
    local existing_thread_ids=""
    existing_thread_ids=$(aws s3 ls "s3://${s3_bucket}/debates/" --region "${BEDROCK_REGION:-us-west-2}" 2>/dev/null \
        | awk '{print $4}' | sed 's/\.json$//' | tr '\n' ' ' || echo "")

    local idx=0
    local writes_this_cycle=0
    local skipped_existing=0
    while [ "$idx" -lt "$synth_count" ]; do
        local thought_name parent_ref agent_name content timestamp
        thought_name=$(echo "$synthesis_thoughts" | jq -r ".[$idx].name" 2>/dev/null || echo "")
        parent_ref=$(echo "$synthesis_thoughts" | jq -r ".[$idx].parent" 2>/dev/null || echo "")
        agent_name=$(echo "$synthesis_thoughts" | jq -r ".[$idx].agent" 2>/dev/null || echo "coordinator")
        content=$(echo "$synthesis_thoughts" | jq -r ".[$idx].content" 2>/dev/null || echo "")
        timestamp=$(echo "$synthesis_thoughts" | jq -r ".[$idx].timestamp" 2>/dev/null || echo "")

        # Use same thread_id algorithm as post_debate_response() in entrypoint.sh
        # thread_id = sha256(parent_thought_name)[0:16]
        local raw_parent="${parent_ref:-${thought_name}}"
        local thread_id
        thread_id=$(echo "$raw_parent" | sha256sum | cut -d' ' -f1 | cut -c1-16)

        local s3_path="s3://${s3_bucket}/debates/${thread_id}.json"

        # Issue #1625: Check membership in prefetched list (no S3 API call per debate).
        # The existing_thread_ids list was fetched once above — grep for the thread_id in it.
        if echo " $existing_thread_ids " | grep -qF " ${thread_id} "; then
            # Already written — skip (no count increment)
            skipped_existing=$((skipped_existing + 1))
            idx=$((idx + 1))
            continue
        fi

        if [ "$writes_this_cycle" -ge "$max_writes_per_cycle" ]; then
            echo "[$(date -u +%H:%M:%S)] Reached per-cycle write limit ($max_writes_per_cycle) — remaining NEW debates will be written next cycle"
            break
        fi

        # Extract topic from thought content (look for #proposal- or common keywords)
        local topic=""
        if echo "$content" | grep -qi "circuit.breaker"; then
            topic="circuit-breaker"
        elif echo "$content" | grep -qi "spawn"; then
            topic="spawn-control"
        elif echo "$content" | grep -qi "speciali"; then
            topic="specialization"
        elif echo "$content" | grep -qi "debate"; then
            topic="debate-protocol"
        elif echo "$content" | grep -qi "coordinator"; then
            topic="coordinator"
        fi

        # Truncate content to first 500 chars for resolution field
        local resolution
        resolution=$(echo "$content" | head -c 500)

        # Escape JSON special characters in resolution text
        local escaped_resolution
        # Issue #1260: Add 2>/dev/null to suppress jq parse errors on unexpected input
        escaped_resolution=$(echo "$resolution" | jq -Rs '.' 2>/dev/null || echo '""')

        # Build JSON document
        local debate_json
        debate_json=$(cat <<EOF
{
  "threadId": "$thread_id",
  "topic": "$topic",
  "outcome": "synthesized",
  "resolution": $escaped_resolution,
  "participants": ["$agent_name"],
  "timestamp": "$timestamp",
  "recordedBy": "coordinator",
  "thoughtName": "$thought_name",
  "parentRef": "$parent_ref"
}
EOF
)
        # Write to S3
        if echo "$debate_json" | aws s3 cp - "$s3_path" --content-type application/json >/dev/null 2>&1; then
            echo "[$(date -u +%H:%M:%S)] Recorded synthesis debate: thread=$thread_id agent=$agent_name topic=$topic"
            writes_this_cycle=$((writes_this_cycle + 1))
        else
            echo "[$(date -u +%H:%M:%S)] WARNING: Failed to write debate outcome for thread=$thread_id"
        fi

        idx=$((idx + 1))
    done
    echo "[$(date -u +%H:%M:%S)] Synthesis debate S3 sync: $writes_this_cycle new writes, $skipped_existing already-persisted skipped, 1 prefix LIST call (${synth_count} total synthesis debates)"
}

# ── aggregate_chronicle_candidates (issue #1605) ──────────────────────────────
#
# Aggregate Thought CRs with thoughtType=chronicle-candidate and surface the
# top 3 (by confidence score) in coordinator-state.chronicleCandidates.
#
# The god-delegate reads chronicleCandidates when writing the next chronicle entry,
# making human curation faster while preserving quality control.
#
# v0.4 Collective Memory: agents propose their own insights for the civilization
# chronicle rather than relying solely on god to curate everything.
#
# Implementation:
#   1. Read all Thought CRs with thoughtType=chronicle-candidate
#   2. Sort by confidence (highest first), tie-break by recency
#   3. Take top 3 ConfigMap names
#   4. Patch coordinator-state.chronicleCandidates (semicolon-separated names)
aggregate_chronicle_candidates() {
    # Fetch chronicle-candidate thoughts using label selector to avoid OOM
    local candidates_json
    candidates_json=$(kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" \
        -l agentex/thought -o json 2>/dev/null | \
        jq '[.items[] | select(.data.thoughtType == "chronicle-candidate") | {
            name: .metadata.name,
            confidence: ((.data.confidence // "7") | tonumber),
            agent: (.data.agentRef // ""),
            content: ((.data.content // "") | .[0:200]),
            createdAt: .metadata.creationTimestamp
        }] | sort_by(-.confidence, .createdAt) | .[0:3]' 2>/dev/null || echo "[]")

    if [ -z "$candidates_json" ] || [ "$candidates_json" = "[]" ] || [ "$candidates_json" = "null" ]; then
        # No candidates found — keep existing chronicleCandidates field as-is
        return 0
    fi

    # Extract top candidate names (semicolon-separated)
    local top_candidates
    top_candidates=$(echo "$candidates_json" | jq -r '.[].name' 2>/dev/null | tr '\n' ';' | sed 's/;$//')

    if [ -z "$top_candidates" ]; then
        return 0
    fi

    local candidate_count
    candidate_count=$(echo "$candidates_json" | jq 'length' 2>/dev/null || echo "0")

    echo "[$(date -u +%H:%M:%S)] Chronicle candidates: $candidate_count found, top 3 surfaced in chronicleCandidates (issue #1605)"
    update_state "chronicleCandidates" "$top_candidates"
}

# Track debate activity — count debate threads, surface unresolved disagreements
track_debate_activity() {
    local all_cm
    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    # Issue #1011: Use label selector -l agentex/thought to avoid fetching all 9000+ configmaps
    # (causes OOM kill — coordinator only has 512Mi limit)
    # Issue #1056: Filter to ONLY debate-relevant thoughts (debate, insight, decision) to reduce
    # memory footprint. Observation/blocker/planning thoughts are not useful for debate tracking.
    all_cm=$(kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" -l agentex/thought -o json 2>/dev/null \
        | jq '[.items[] | select(.data.thoughtType == "debate" or .data.thoughtType == "insight" or .data.thoughtType == "decision" or .data.thoughtType == "proposal") | {
            name: .metadata.name,
            type: (.data.thoughtType // ""),
            parent: (.data.parentRef // ""),
            agent: (.data.agentRef // ""),
            content: ((.data.content // "") | .[0:100])
          }]' 2>/dev/null) || return 0

    [ -z "$all_cm" ] || [ "$all_cm" = "null" ] || [ "$all_cm" = "[]" ] && return 0

    # Count debate responses
    local debate_count
    debate_count=$(echo "$all_cm" | jq '[.[] | select(.type == "debate")] | length' 2>/dev/null || echo "0")

    # Count unique debate threads (thoughts with a non-empty parentRef)
    local thread_count
    thread_count=$(echo "$all_cm" | jq '[.[] | select(.parent != "" and .parent != null)] | length' 2>/dev/null || echo "0")

    # Find unresolved disagreements (debate thoughts with stance "disagree" that have no "synthesize" sibling)
    # Issue #1096: Use case-insensitive regex to catch all disagreement patterns (disagree, DISAGREE, Disagree)
    local disagree_count
    disagree_count=$(echo "$all_cm" | jq '[.[] | select(.type == "debate") | select(.content | test("disagree"; "i"))] | length' 2>/dev/null || echo "0")
    # Issue #1096: Use case-insensitive regex to catch all synthesis patterns (synthesis, SYNTHESIS, Synthesis, synthesize, SYNTHESIZE, Synthesize)
    local synthesize_count
    synthesize_count=$(echo "$all_cm" | jq '[.[] | select(.type == "debate") | select(.content | test("synthes(is|ize)"; "i"))] | length' 2>/dev/null || echo "0")

    echo "[$(date -u +%H:%M:%S)] Debate stats: responses=$debate_count threads=$thread_count disagree=$disagree_count synthesize=$synthesize_count"

    # ── Issue #1161: Write synthesis debate outcomes to S3 for collective memory ──
    # The coordinator is the authoritative writer for debate memory because it sees ALL
    # synthesis thoughts — including those posted manually via kubectl (which bypass
    # post_debate_response() and its S3 write). This ensures the debates/ folder in S3
    # is populated even when agents don't use the canonical helper function.
    if [ "$synthesize_count" -gt 0 ]; then
        record_synthesis_debates_to_s3
    fi

    update_state "debateStats" "responses=${debate_count} threads=${thread_count} disagree=${disagree_count} synthesize=${synthesize_count}"
    push_metric "DebateResponses" "$debate_count" "Count" "Component=Coordinator"
    push_metric "DebateThreads" "$thread_count" "Count" "Component=Coordinator"

    # ── Issue #1111: Track unresolved debate threads for planner triage ───────
    # A debate thread is "unresolved" if:
    #   - It has at least one debate thought with "disagree" stance
    #   - No debate thought in the same thread has a "synthesize" response
    # Thread ID = parentRef of the debate thoughts (the original thought being debated)
    #
    # Strategy: collect all parentRefs from disagree thoughts, then remove those that
    # have a corresponding synthesize response in the same thread.
    local unresolved_threads=""

    # Get all parentRefs from "disagree" debate thoughts
    local disagree_threads
    disagree_threads=$(echo "$all_cm" | jq -r '
        [.[] | select(.type == "debate") | select(.content | test("disagree"; "i")) | .parent]
        | unique | .[]' 2>/dev/null || true)

    if [ -n "$disagree_threads" ]; then
        # Get all parentRefs from "synthesize" debate thoughts (resolved threads)
        local resolved_threads
        resolved_threads=$(echo "$all_cm" | jq -r '
            [.[] | select(.type == "debate") | select(.content | test("synthes(is|ize)"; "i")) | .parent]
            | unique | .[]' 2>/dev/null || true)

        # Issue #1667: Pre-fetch all existing thought CM names in one batch query to avoid
        # N individual kubectl get calls (one per disagree thread) for orphan detection.
        local existing_thought_names_tda
        existing_thought_names_tda=$(kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" \
            -l agentex/thought -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

        # Build list of unresolved thread IDs (in disagree but not in resolved)
        while IFS= read -r thread_id; do
            [ -z "$thread_id" ] && continue
            # Skip empty/null parentRefs
            [ "$thread_id" = "null" ] && continue
            # Issue #1667: Skip orphaned entries where the parent CM was already deleted.
            # Uses pre-fetched batch list to avoid N individual kubectl get calls.
            if ! echo " $existing_thought_names_tda " | grep -qF " $thread_id "; then
                echo "[$(date -u +%H:%M:%S)] Skipping orphaned debate thread: $thread_id (parent CM deleted)"
                continue
            fi
            # Check if this thread has a synthesis response
            if ! echo "$resolved_threads" | grep -qF "$thread_id"; then
                [ -n "$unresolved_threads" ] \
                    && unresolved_threads="${unresolved_threads},${thread_id}" \
                    || unresolved_threads="$thread_id"
            fi
        done <<< "$disagree_threads"
    fi

    local unresolved_count=0
    [ -n "$unresolved_threads" ] && unresolved_count=$(echo "$unresolved_threads" | tr ',' '\n' | grep -c . || echo "0")

    echo "[$(date -u +%H:%M:%S)] Unresolved debate threads: $unresolved_count"
    update_state "unresolvedDebates" "$unresolved_threads"
    push_metric "UnresolvedDebates" "$unresolved_count" "Count" "Component=Coordinator"

    # ── Issue #1161: Write synthesis debate outcomes to S3 ────────────────────
    # The coordinator detects synthesis debate thoughts and writes them to S3
    # so agents can query past debate resolutions via query_debate_outcomes().
    # This covers manually-posted debate Thought CRs (which bypass post_debate_response()
    # in entrypoint.sh and thus never reach record_debate_outcome() directly).
    if [ "$synthesize_count" -gt 0 ]; then
        # Get all synthesis debate thoughts with their full names and parents
        local synthesis_thoughts
        synthesis_thoughts=$(echo "$all_cm" | jq -r '
            [.[] | select(.type == "debate") | select(.content | test("synthes(is|ize)"; "i"))]
            | .[] | [.name, .parent, .agent] | @tsv' 2>/dev/null || true)

        # Issue #1625: Prefetch existing thread IDs with a single prefix LIST (not per-file ls).
        local existing_tda_thread_ids=""
        existing_tda_thread_ids=$(aws s3 ls "s3://${IDENTITY_BUCKET}/debates/" --region "$BEDROCK_REGION" 2>/dev/null \
            | awk '{print $4}' | sed 's/\.json$//' | tr '\n' ' ' || echo "")

        local s3_written=0
        while IFS=$'\t' read -r thought_name parent_ref agent_name; do
            [ -z "$thought_name" ] && continue
            { [ -z "$parent_ref" ] || [ "$parent_ref" = "null" ]; } && continue

            # Use sha256(parentRef)[0:16] as thread_id — consistent with post_debate_response()
            # in helpers.sh and record_synthesis_debates_to_s3() (issue #1640)
            local thread_id
            thread_id=$(echo "$parent_ref" | sha256sum | cut -d' ' -f1 | cut -c1-16)
            local s3_path="s3://${IDENTITY_BUCKET}/debates/${thread_id}.json"

            # Issue #1625: Check against prefetched list (no S3 API call per debate)
            if echo " $existing_tda_thread_ids " | grep -qF " ${thread_id} "; then
                continue
            fi

            # Fetch full content of this specific synthesis ConfigMap
            local full_content
            full_content=$(kubectl_with_timeout 10 get configmap "$thought_name" -n "$NAMESPACE" \
                -o jsonpath='{.data.content}' 2>/dev/null || echo "")
            [ -z "$full_content" ] && full_content="(content unavailable)"

            # Build debate outcome JSON
            local timestamp
            timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            local escaped_resolution
            # Issue #1260: Add 2>/dev/null to suppress jq parse errors on unexpected input
            escaped_resolution=$(echo "$full_content" | jq -Rs '.' 2>/dev/null || echo '""')

            local debate_json
            debate_json=$(cat <<DEBATE_EOF
{
  "threadId": "$thread_id",
  "topic": "",
  "outcome": "synthesized",
  "resolution": $escaped_resolution,
  "participants": ["$agent_name"],
  "timestamp": "$timestamp",
  "recordedBy": "coordinator",
  "sourceThought": "$thought_name"
}
DEBATE_EOF
)

            # Write to S3
            if echo "$debate_json" | aws s3 cp - "$s3_path" \
                    --content-type application/json \
                    --region "$BEDROCK_REGION" >/dev/null 2>&1; then
                echo "[$(date -u +%H:%M:%S)] Wrote synthesis outcome to S3: $s3_path (thread=$thread_id)"
                s3_written=$((s3_written + 1))
            else
                echo "[$(date -u +%H:%M:%S)] WARNING: Failed to write synthesis to S3: $s3_path" >&2
            fi
        done <<< "$synthesis_thoughts"

        if [ "$s3_written" -gt 0 ]; then
            push_metric "DebateOutcomesWritten" "$s3_written" "Count" "Component=Coordinator"
            echo "[$(date -u +%H:%M:%S)] Wrote $s3_written synthesis outcome(s) to S3 debates/"
        fi
    fi
    # ── End Issue #1161 ───────────────────────────────────────────────────────

    # ── Issue #1605: Aggregate chronicle-candidate thoughts ──────────────────
    # After processing debate activity, also aggregate chronicle candidates so
    # god-delegate can find agent-proposed chronicle entries efficiently.
    aggregate_chronicle_candidates

    # Issue #1704: Fix debate nudge condition — nudge when unresolved_count > 5 (not synthesize_count == 0).
    # The original condition (synthesize_count == 0) permanently silenced the nudge once any synthesis
    # was ever posted. Using unresolved_count allows nudging to continue across all generations as long
    # as significant unresolved threads accumulate, regardless of historical synthesis activity.
    if [ "$unresolved_count" -gt 5 ]; then
        local existing_nudge
        existing_nudge=$(get_state "lastDebateNudge")
        local now_epoch
        now_epoch=$(date +%s)
        local nudge_epoch=0
        [ -n "$existing_nudge" ] && nudge_epoch=$(date -d "$existing_nudge" +%s 2>/dev/null || echo "0")
        local age=$(( now_epoch - nudge_epoch ))

        # Nudge at most once per 10 minutes
        if [ "$age" -gt 600 ]; then
            # Issue #1912: Include specific thread IDs in nudge so agents know exactly which
            # threads to synthesize (not just a generic "go check coordinator-state" message).
            # Show top 5 oldest unresolved threads to focus synthesis effort.
            local top_threads
            top_threads=$(echo "$unresolved_threads" | tr ',' '\n' | head -5 | tr '\n' ' ')
            post_coordinator_thought \
"DEBATE NUDGE: There are $unresolved_count unresolved debate threads needing synthesis (disagree_count=$disagree_count, synthesize_count=$synthesize_count).
Top threads to synthesize (oldest first):
$(echo "$unresolved_threads" | tr ',' '\n' | head -5 | awk '{print NR\". \"$1}')

To synthesize a thread:
  source /agent/helpers.sh && post_debate_response \"<thread_id>\" \"Synthesis: <resolution>\" synthesize 9

The civilization needs mediators, not just voters. Pick ONE thread, read its debate chain, and synthesize." \
                "insight"
            update_state "lastDebateNudge" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        fi
    fi

    # Issue #1912: Auto-synthesize recurring well-known debate patterns to drain the backlog.
    # Some debates repeat across generations (e.g., "score=10/10 self-improvement audit").
    # The coordinator can post coordinator-authored synthesis for these patterns when backlog > 20.
    if [ "$unresolved_count" -gt 20 ]; then
        auto_synthesize_recurring_debates "$all_cm" "$unresolved_threads" "$unresolved_count"
    fi
}

# auto_synthesize_recurring_debates — coordinator-authored synthesis for high-volume
# recurring debate patterns that individual agents never resolve (issue #1912).
#
# Recurring patterns identified:
#   1. "score=10/10 self-improvement audit" — disagreement about PR count inflation
#   2. "v0.2 validation: specialization routing NOT yet firing" — stale diagnostic data
#
# These debates keep accumulating because agents disagree with recurring planner insights
# but nobody synthesizes the specific thread. The coordinator identifies threads whose
# parent content matches a known pattern and posts a synthesis thought + S3 record.
#
# Throttled: at most 3 auto-syntheses per invocation, at most once per 30 minutes total.
auto_synthesize_recurring_debates() {
    local all_cm="$1"
    local unresolved_threads="$2"
    local unresolved_count="${3:-0}"

    # Throttle: at most once per 30 minutes
    local last_auto_synth
    last_auto_synth=$(get_state "lastAutoSynthesis" 2>/dev/null || echo "")
    local now_epoch
    now_epoch=$(date +%s)
    local last_epoch=0
    [ -n "$last_auto_synth" ] && last_epoch=$(date -d "$last_auto_synth" +%s 2>/dev/null || echo "0")
    local age=$(( now_epoch - last_epoch ))
    if [ "$age" -lt 1800 ]; then
        echo "[$(date -u +%H:%M:%S)] Auto-synthesis throttled (last ran ${age}s ago, min interval 1800s)"
        return 0
    fi

    echo "[$(date -u +%H:%M:%S)] Auto-synthesis: checking $unresolved_count unresolved threads for recurring patterns..."

    local synth_count=0
    local max_auto_synth=3

    while IFS= read -r thread_id; do
        [ -z "$thread_id" ] && continue
        [ "$synth_count" -ge "$max_auto_synth" ] && break

        # Get parent content to check for known patterns
        local parent_content
        parent_content=$(kubectl_with_timeout 5 get configmap "$thread_id" -n "$NAMESPACE" \
            -o jsonpath='{.data.content}' 2>/dev/null || echo "")
        [ -z "$parent_content" ] && continue

        local resolution=""
        local topic=""

        # Pattern 1: "score=10/10 self-improvement audit" — PR count inflation debate
        if echo "$parent_content" | grep -qi "score=10/10" && echo "$parent_content" | grep -qi "self-improvement audit"; then
            resolution="Synthesis: The score=10/10 framing is misleading. Vision score 10/10 requires swarms/memory/persistent identity — not just opening many PRs. Opening 10+ PRs/issues in one session is a proliferation signal per Prime Directive step ②, which says 'find ONE improvement'. The correct framing is: visionScore reflects WHAT was built (vision alignment), not how many artifacts were created. Planner audits should use visionScore 3-5 for bug fixes, 7 for platform capabilities, 10 only for foundational capabilities. Auto-synthesized by coordinator (issue #1912)."
            topic="self-improvement-audit"
        # Pattern 2: "v0.2 validation: specialization routing NOT yet firing"
        elif echo "$parent_content" | grep -qi "v0.2 validation" && echo "$parent_content" | grep -qi "specialization routing"; then
            resolution="Synthesis: The v0.2 validation diagnostic 'specializedAssignments=0' is a known false alarm for older agents. Root cause: identity.sh update_specialization() historically wrote only to per-session S3 files, not canonical paths. PRs #1524 and #1527 fixed canonical file writes. After image rebuild, specializedAssignments should increment. If still 0 after rebuild: check coordinator routing logic reads canonical not per-session files. Old diagnostic messages citing 'none have specializationLabelCounts > 0' were based on sampling the wrong (alphabetically-first/oldest) S3 files. Auto-synthesized by coordinator (issue #1912)."
            topic="v0.2-specialization-routing"
        fi

        if [ -n "$resolution" ]; then
            # Post synthesis Thought CR
            local ts
            ts=$(date +%s)
            local synth_name="thought-coordinator-synth-${ts}-thought"
            if kubectl_with_timeout 10 apply -f - <<SYNTH_EOF >/dev/null 2>&1
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: ${synth_name}
  namespace: ${NAMESPACE}
spec:
  agentRef: coordinator
  taskRef: coordinator-auto-synthesis
  thoughtType: debate
  confidence: 8
  parentRef: ${thread_id}
  content: |
    DEBATE RESPONSE [synthesize]:
    ${resolution}
    parentRef: ${thread_id}
SYNTH_EOF
            then
                echo "[$(date -u +%H:%M:%S)] Auto-synthesized thread: $thread_id (topic=$topic)"

                # Write synthesis outcome to S3 (anti-amnesia, issue #1161)
                local thread_hash
                thread_hash=$(echo "$thread_id" | sha256sum | cut -d' ' -f1 | cut -c1-16)
                local s3_path="s3://${IDENTITY_BUCKET}/debates/${thread_hash}.json"
                local escaped_res
                escaped_res=$(echo "$resolution" | jq -Rs '.' 2>/dev/null || echo '""')
                local timestamp
                timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                local debate_json
                debate_json=$(cat <<DEBATE_EOF
{
  "threadId": "${thread_hash}",
  "topic": "${topic}",
  "outcome": "synthesized",
  "resolution": ${escaped_res},
  "participants": ["coordinator"],
  "timestamp": "${timestamp}",
  "recordedBy": "coordinator",
  "sourceThought": "${synth_name}",
  "note": "auto-synthesized by coordinator for recurring pattern (issue #1912)"
}
DEBATE_EOF
)
                if echo "$debate_json" | aws s3 cp - "$s3_path" \
                        --content-type application/json \
                        --region "$BEDROCK_REGION" >/dev/null 2>&1; then
                    echo "[$(date -u +%H:%M:%S)] Auto-synthesis S3 record written: $s3_path"
                else
                    echo "[$(date -u +%H:%M:%S)] WARNING: Auto-synthesis S3 write failed: $s3_path" >&2
                fi

                synth_count=$((synth_count + 1))
                push_metric "AutoSynthesized" 1 "Count" "Component=Coordinator"
            else
                echo "[$(date -u +%H:%M:%S)] WARNING: Failed to post auto-synthesis for: $thread_id" >&2
            fi
        fi
    done <<< "$(echo "$unresolved_threads" | tr ',' '\n')"

    if [ "$synth_count" -gt 0 ]; then
        update_state "lastAutoSynthesis" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "[$(date -u +%H:%M:%S)] Auto-synthesis complete: $synth_count threads synthesized"
        push_metric "AutoSynthesisTotal" "$synth_count" "Count" "Component=Coordinator"
    else
        echo "[$(date -u +%H:%M:%S)] Auto-synthesis: no matching recurring patterns found"
    fi
}

# NOTE (issue #867): Planner-chain liveness is now handled by the planner-loop Deployment.
# The ensure_planner_chain_alive() watchdog function was removed because planner-loop
# guarantees exactly-one-planner spawning with no TOCTOU races. The coordinator no longer
# needs to spawn recovery planners.
# (Issue #1001): Removed dead function body that was still present after the comment
# was added — the function referenced undefined $PLANNER_LIVENESS_TIMEOUT which would
# have caused a bash unbound variable error under set -u if ever called.

# ── Dynamic Role Promotion (issue #1733) ─────────────────────────────────────
#
# promote_agent_role() scans all active agents' S3 identity files and promotes
# agents that demonstrate consistent excellence. Promotion criteria:
#   - N=3 consecutive visionScores >= 8 in reputationHistory, OR
#   - specializationLabelCounts shows 5+ tasks in one domain
#
# Promoted role format: {base-role}:{specialization}
#   e.g., worker:architecture-specialist, worker:debate-specialist
#
# The promoted role is written to the agent's S3 identity file as "promotedRole".
# score_agent_for_issue() factors in promotedRole for routing priority.
#
# Runs every 15 iterations (~7.5 min) in the main coordinator loop.
# ─────────────────────────────────────────────────────────────────────────────
promote_agent_role() {
    echo "[$(date -u +%H:%M:%S)] Running dynamic role promotion check (issue #1733)..."

    # Update S3 bucket from constitution (runtime portability)
    update_identity_bucket_from_constitution

    local active_agents
    active_agents=$(get_state "activeAgents")
    if [ -z "$active_agents" ]; then
        echo "[$(date -u +%H:%M:%S)] No active agents — skipping role promotion"
        return 0
    fi

    local promotions_this_cycle=0

    IFS=',' read -ra agent_pairs <<< "$active_agents"
    for pair in "${agent_pairs[@]}"; do
        [ -z "$pair" ] && continue
        local agent_name="${pair%%:*}"
        local agent_role
        agent_role=$(echo "$pair" | cut -d: -f2 | tr -d '[:space:]')
        local agent_display_name
        agent_display_name=$(echo "$pair" | cut -d: -f3)

        # Only evaluate worker agents for promotion (planners/architects are already specialized)
        [ "$agent_role" != "worker" ] && continue

        # Skip if already promoted (role contains colon = already a specialist)
        # (agent_role was extracted via cut -d: -f2 so it won't contain a promoted suffix,
        #  but check the S3 identity for an existing promotedRole field)

        # Read agent identity — prefer canonical history
        local identity_json=""
        if [ -n "$agent_display_name" ] && [ "$agent_display_name" != "$agent_name" ]; then
            identity_json=$(aws s3 cp "s3://${IDENTITY_BUCKET}/identities/canonical/${agent_display_name}.json" - \
                --region "$BEDROCK_REGION" 2>/dev/null || echo "")
        fi
        if [ -z "$identity_json" ]; then
            identity_json=$(aws s3 cp "s3://${IDENTITY_BUCKET}/identities/${agent_name}.json" - \
                --region "$BEDROCK_REGION" 2>/dev/null || echo "")
        fi
        [ -z "$identity_json" ] && continue

        # Skip if already has a promotedRole
        local existing_promoted
        existing_promoted=$(echo "$identity_json" | jq -r '.promotedRole // ""' 2>/dev/null || echo "")
        [ -n "$existing_promoted" ] && continue

        local new_role=""
        local promotion_reason=""

        # Criterion 1: 3 consecutive visionScores >= 8 in reputationHistory
        local rep_history
        rep_history=$(echo "$identity_json" | jq -c '.reputationHistory // []' 2>/dev/null || echo "[]")
        local rep_count
        rep_count=$(echo "$rep_history" | jq 'length' 2>/dev/null || echo "0")

        if [ "$rep_count" -ge 3 ]; then
            # Check if last 3 visionScores are all >= 8
            local consecutive_high
            consecutive_high=$(echo "$rep_history" | jq '
                (.[-3:] | map(.visionScore // 0 | tonumber) | all(. >= 8))
                and (length >= 3)' 2>/dev/null || echo "false")

            if [ "$consecutive_high" = "true" ]; then
                # Determine specialization from reputationHistory or specializationLabelCounts
                local top_label
                top_label=$(echo "$identity_json" | jq -r '
                    .specializationLabelCounts // {} | to_entries | sort_by(-.value) | .[0].key // ""
                    ' 2>/dev/null || echo "")

                if [ -n "$top_label" ]; then
                    new_role="worker:${top_label}-specialist"
                else
                    new_role="worker:vision-specialist"
                fi
                promotion_reason="3 consecutive visionScores >= 8 in reputationHistory"
            fi
        fi

        # Criterion 2: 5+ tasks in one domain (specializationLabelCounts)
        if [ -z "$new_role" ]; then
            local domain_count
            domain_count=$(echo "$identity_json" | jq -r '
                .specializationLabelCounts // {} | to_entries | sort_by(-.value) | .[0].value // 0
                ' 2>/dev/null || echo "0")
            local top_domain
            top_domain=$(echo "$identity_json" | jq -r '
                .specializationLabelCounts // {} | to_entries | sort_by(-.value) | .[0].key // ""
                ' 2>/dev/null || echo "")

            if [ "$domain_count" -ge 5 ] && [ -n "$top_domain" ]; then
                new_role="worker:${top_domain}-specialist"
                promotion_reason="5+ tasks in domain '${top_domain}' (count=${domain_count})"
            fi
        fi

        # If promotion criteria met — write promoted role to S3 identity
        if [ -n "$new_role" ]; then
            echo "[$(date -u +%H:%M:%S)] PROMOTING $agent_name (${agent_display_name:-?}) → $new_role ($promotion_reason)"

            # Write promotedRole to S3 identity file
            local updated_json
            updated_json=$(echo "$identity_json" | jq \
                --arg role "$new_role" \
                --arg reason "$promotion_reason" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '. + {promotedRole: $role, promotedAt: $ts, promotionReason: $reason}' \
                2>/dev/null || echo "")

            if [ -n "$updated_json" ]; then
                # Write to per-session identity file
                echo "$updated_json" | aws s3 cp - \
                    "s3://${IDENTITY_BUCKET}/identities/${agent_name}.json" \
                    --region "$BEDROCK_REGION" --content-type application/json 2>/dev/null && \
                    echo "[$(date -u +%H:%M:%S)] Promotion written to s3://identities/${agent_name}.json"

                # Also write to canonical identity if display name available
                if [ -n "$agent_display_name" ] && [ "$agent_display_name" != "$agent_name" ]; then
                    echo "$updated_json" | aws s3 cp - \
                        "s3://${IDENTITY_BUCKET}/identities/canonical/${agent_display_name}.json" \
                        --region "$BEDROCK_REGION" --content-type application/json 2>/dev/null && \
                        echo "[$(date -u +%H:%M:%S)] Promotion written to canonical/${agent_display_name}.json"
                fi

                # Post a Thought CR announcing the promotion
                kubectl_with_timeout 10 apply -f - <<THOUGHT_EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-promotion-$(date +%s)-$$
  namespace: ${NAMESPACE}
spec:
  agentRef: coordinator
  taskRef: coordinator-promotion
  thoughtType: insight
  confidence: 9
  content: |
    ROLE PROMOTION (issue #1733): ${agent_name} (${agent_display_name:-?}) promoted to ${new_role}
    Reason: ${promotion_reason}
    This agent has demonstrated consistent excellence and earned a specialist role.
    Future routing will give this agent priority on matching issues.
THOUGHT_EOF

                push_metric "AgentRolePromotions" 1 "Count" "PromotedRole=${new_role}"
                promotions_this_cycle=$((promotions_this_cycle + 1))
            else
                echo "[$(date -u +%H:%M:%S)] WARNING: Failed to update identity JSON for $agent_name during promotion"
            fi
        fi
    done

    if [ "$promotions_this_cycle" -gt 0 ]; then
        echo "[$(date -u +%H:%M:%S)] Role promotion cycle complete: $promotions_this_cycle agent(s) promoted"
    else
        echo "[$(date -u +%H:%M:%S)] Role promotion cycle complete: no agents met promotion criteria"
    fi
 }

# ── v0.5 Milestone Completion Checker (issue #1752) ──────────────────────────
#
# Periodically checks whether all v0.5 Emergent Specialization success criteria
# are met. When all 5 criteria pass, posts a milestone completion Thought CR and
# files a GitHub issue announcing v0.5 completion.
#
# Success Criteria (from issue #1732):
#   1. Dynamic role promotions: 3+ agents with promotedRole in S3 identity
#   2. Trust graph: 5+ distinct citation edges in coordinator-state.agentTrustGraph
#   3. Proactive issue discovery: 2+ agents with .stats.proactiveIssuesFound > 0 in S3 identity
#   4. Mentor credit loop: 1+ agent with .specializationDetail.mentorCredits array length > 0
#   5. Vision queue proposer identity: 2+ items in visionQueueLog (always true after PR #1739)
#
# State: coordinator-state.v05MilestoneStatus — set to "completed" on success
#        coordinator-state.v05CriteriaStatus  — last check results (for observability)
#
check_v05_milestone() {
    # Skip if already completed
    local milestone_status
    milestone_status=$(get_state "v05MilestoneStatus" 2>/dev/null || echo "")
    if [ "$milestone_status" = "completed" ]; then
        return 0
    fi

    echo "[$(date -u +%H:%M:%S)] Checking v0.5 milestone completion criteria (issue #1752)..."

    update_identity_bucket_from_constitution

    local criteria_met=0
    local criteria_report=""

    # ── Criteria 1, 3, 4: Single S3 download loop (issue #1764) ─────────────
    # All three criteria use the same identity files — download each file once
    # and extract all three metrics in a single pass. This reduces S3 API calls
    # from 150 (3 loops × 50 files) to 50 (1 loop × 50 files).
    #
    # Issue #1808: Sort by modification date DESCENDING (newest first) to ensure recent
    # worker identities are sampled. Without this, alphabetical S3 ordering returns
    # god-delegates and planners first (alphabetically earlier), and workers last —
    # causing criteria 1/3/4 to never see the worker identities that hold promotedRole,
    # proactiveIssuesFound, and mentorCredits values.
    local identity_files
    identity_files=$(aws s3 ls "s3://${IDENTITY_BUCKET}/identities/" \
        --region "$BEDROCK_REGION" 2>/dev/null | \
        sort -k1,2 -r | awk '{print $4}' | grep '\.json$' | grep -v '^$' | head -50 || echo "")

    local promoted_count=0
    local proactive_count=0
    local mentor_credit_count=0

    for ifile in $identity_files; do
        local ijson
        ijson=$(aws s3 cp "s3://${IDENTITY_BUCKET}/identities/${ifile}" - \
            --region "$BEDROCK_REGION" 2>/dev/null || echo "")
        [ -z "$ijson" ] && continue

        # Criterion 1: promotedRole
        local prole
        prole=$(echo "$ijson" | jq -r '.promotedRole // ""' 2>/dev/null || echo "")
        [ -n "$prole" ] && promoted_count=$((promoted_count + 1))

        # Criterion 3: proactiveIssuesFound (under .stats.proactiveIssuesFound per issue #1759)
        local pif
        pif=$(echo "$ijson" | jq -r '.stats.proactiveIssuesFound // 0 | tonumber' 2>/dev/null || echo "0")
        [ "$pif" -gt 0 ] 2>/dev/null && proactive_count=$((proactive_count + 1))

        # Criterion 4: mentorCredits array length (under .specializationDetail.mentorCredits per issue #1759)
        local mc
        mc=$(echo "$ijson" | jq -r '(.specializationDetail.mentorCredits // []) | length' 2>/dev/null || echo "0")
        [ "$mc" -gt 0 ] 2>/dev/null && mentor_credit_count=$((mentor_credit_count + 1))
    done

    # ── Criterion 1: 3+ agents with promotedRole ─────────────────────────────
    if [ "$promoted_count" -ge 3 ]; then
        criteria_met=$((criteria_met + 1))
        criteria_report="${criteria_report}✅ Criterion 1: Dynamic role promotions — ${promoted_count} agents promoted"$'\n'
    else
        criteria_report="${criteria_report}⏳ Criterion 1: Dynamic role promotions — ${promoted_count}/3 agents promoted"$'\n'
    fi
    echo "[$(date -u +%H:%M:%S)] v0.5 Criterion 1: ${promoted_count} agents with promotedRole (need 3)"

    # ── Criterion 2: 5+ distinct citation edges in agentTrustGraph ───────────
    local trust_graph
    trust_graph=$(get_state "agentTrustGraph" 2>/dev/null || echo "")
    local edge_count=0
    if [ -n "$trust_graph" ]; then
        # Count non-empty edges (format: citingAgent:citedAgent:count separated by |)
        edge_count=$(echo "$trust_graph" | tr '|' '\n' | grep -c '.' 2>/dev/null || echo "0")
        # Ensure it's numeric
        [[ "$edge_count" =~ ^[0-9]+$ ]] || edge_count=0
    fi

    if [ "$edge_count" -ge 5 ]; then
        criteria_met=$((criteria_met + 1))
        criteria_report="${criteria_report}✅ Criterion 2: Trust graph — ${edge_count} citation edges"$'\n'
    else
        criteria_report="${criteria_report}⏳ Criterion 2: Trust graph — ${edge_count}/5 citation edges"$'\n'
    fi
    echo "[$(date -u +%H:%M:%S)] v0.5 Criterion 2: ${edge_count} trust graph edges (need 5)"

    # ── Criterion 3: 2+ agents with proactiveIssuesFound > 0 ─────────────────
    # (counts computed in combined S3 loop above)
    if [ "$proactive_count" -ge 2 ]; then
        criteria_met=$((criteria_met + 1))
        criteria_report="${criteria_report}✅ Criterion 3: Proactive issue discovery — ${proactive_count} agents discovered issues"$'\n'
    else
        criteria_report="${criteria_report}⏳ Criterion 3: Proactive issue discovery — ${proactive_count}/2 agents with proactiveIssuesFound > 0"$'\n'
    fi
    echo "[$(date -u +%H:%M:%S)] v0.5 Criterion 3: ${proactive_count} agents with proactiveIssuesFound > 0 (need 2)"

    # ── Criterion 4: 1+ agent with mentorCredits > 0 ─────────────────────────
    # (counts computed in combined S3 loop above)
    if [ "$mentor_credit_count" -ge 1 ]; then
        criteria_met=$((criteria_met + 1))
        criteria_report="${criteria_report}✅ Criterion 4: Mentor credit loop — ${mentor_credit_count} mentor(s) credited"$'\n'
    else
        criteria_report="${criteria_report}⏳ Criterion 4: Mentor credit loop — no mentors credited yet"$'\n'
    fi
    echo "[$(date -u +%H:%M:%S)] v0.5 Criterion 4: ${mentor_credit_count} agents with mentorCredits > 0 (need 1)"

    # ── Criterion 5: 2+ items in visionQueueLog (proposer identity feature) ──
    local vision_queue_log
    vision_queue_log=$(get_state "visionQueueLog" 2>/dev/null || echo "")
    local vql_count=0
    if [ -n "$vision_queue_log" ]; then
        vql_count=$(echo "$vision_queue_log" | tr ';' '\n' | grep -c '.' 2>/dev/null || echo "0")
        [[ "$vql_count" =~ ^[0-9]+$ ]] || vql_count=0
    fi

    if [ "$vql_count" -ge 2 ]; then
        criteria_met=$((criteria_met + 1))
        criteria_report="${criteria_report}✅ Criterion 5: Vision queue proposer identity — ${vql_count} items in visionQueueLog"$'\n'
    else
        criteria_report="${criteria_report}⏳ Criterion 5: Vision queue proposer identity — ${vql_count}/2 items in visionQueueLog"$'\n'
    fi
    echo "[$(date -u +%H:%M:%S)] v0.5 Criterion 5: ${vql_count} items in visionQueueLog (need 2)"

    # ── Store progress in coordinator-state for observability ─────────────────
    local status_summary="${criteria_met}/5 criteria met"
    # Sanitize for JSON (escape backslashes and newlines)
    local safe_report
    # Issue #1769: criteria_report uses $'\n' (actual newlines) as delimiter — convert to ' | '
    # so the stored v05CriteriaStatus is human-readable as a single kubectl jsonpath output.
    safe_report=$(printf '%s' "$criteria_report" | tr '\n' '|' | sed 's/|$//;s/|/ | /g;s/"/\\"/g')
    local safe_status
    safe_status=$(printf '%s' "${status_summary} | ${safe_report}" | tr '\n' ' ' | sed 's/"/\\"/g')
    kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
        -p "{\"data\":{\"v05CriteriaStatus\":\"${safe_status}\"}}" 2>/dev/null || true

    echo "[$(date -u +%H:%M:%S)] v0.5 milestone check: ${criteria_met}/5 criteria met"

    # ── All 5 criteria met: declare milestone complete ────────────────────────
    if [ "$criteria_met" -eq 5 ]; then
        echo "[$(date -u +%H:%M:%S)] 🎉 v0.5 MILESTONE COMPLETE — All 5 Emergent Specialization criteria met!"

        # Mark as completed in coordinator-state
        kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
            -p '{"data":{"v05MilestoneStatus":"completed"}}' 2>/dev/null || true

        # Post milestone completion Thought CR
        kubectl_with_timeout 10 apply -f - <<MILESTONE_THOUGHT_EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-v05-milestone-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  agentRef: coordinator
  taskRef: coordinator-milestone
  thoughtType: insight
  confidence: 10
  content: |
    🎉 v0.5 EMERGENT SPECIALIZATION MILESTONE COMPLETE (issue #1732)

    All 5 success criteria verified by coordinator check_v05_milestone():
$(printf '%s' "$criteria_report" | sed 's/^/    /')

    The civilization has achieved:
    - Dynamic role promotion (roles formed by capability, not assignment)
    - Peer trust graph with 5+ citation relationships
    - Proactive domain issue discovery by specialists
    - Mentor-student credit loop (cross-generation knowledge transfer)
    - Vision queue with proposer identity (persistent advocacy tracking)

    Recommendation: Begin v0.6 planning. The civilization is ready for the next milestone.
MILESTONE_THOUGHT_EOF

        # File GitHub issue announcing v0.5 completion
        local milestone_body="## v0.5 Emergent Specialization Milestone COMPLETE

Automatically verified by coordinator \`check_v05_milestone()\` function (issue #1752).

All 5 success criteria from issue #1732 have been met:

$(printf '%s' "$criteria_report" | sed 's/\\n/\n/g')

### What This Means

The civilization has achieved emergent specialization — roles are formed by demonstrated capability, not assignment. Agents:
- Earn specialist roles automatically based on track record
- Build trust relationships through synthesis citation  
- Proactively hunt for problems in their domains
- Mentor future generations and receive credit for impact
- Advocate for long-term vision features with persistent identity

### Next Step

Begin v0.6 milestone planning. Suggest: focus on **swarm intelligence** — groups of specialists self-organizing around complex goals.

Closes #1732"

        gh issue create \
            --repo "${GITHUB_REPO}" \
            --title "milestone: v0.5 Emergent Specialization COMPLETE — all criteria verified by coordinator" \
            --label "enhancement,self-improvement" \
            --body "$milestone_body" 2>/dev/null || \
            echo "[$(date -u +%H:%M:%S)] WARNING: Could not file v0.5 completion issue (non-fatal)"

        push_metric "MilestoneCompleted" 1 "Count" "Milestone=v0.5"
    fi
}

# ── v0.6 Collective Action Milestone Checker (issue #1789) ───────────────────
#
# Evaluates success criteria for the v0.6 Collective Action milestone:
#   1. swarmFormationCount >= 2  — spontaneous swarm formations recorded in S3
#   2. coalitionSize >= 3        — max coalition size in any swarm
#   3. emergentGoalCount >= 1    — agent-proposed goals pursued by a swarm
#   4. swarmMemoryCount >= 1     — swarm summaries written to S3 on dissolution
#
# Checks S3 swarm dissolution records (s3://agentex-thoughts/swarms/*.json)
# and activeSwarms field for live swarm data.
#
# State: coordinator-state.v06MilestoneStatus — set to "completed" on success
#        coordinator-state.v06CriteriaStatus  — last check results (for observability)
#
check_v06_milestone() {
    # Skip if already completed
    local milestone_status
    milestone_status=$(get_state "v06MilestoneStatus" 2>/dev/null || echo "")
    if [ "$milestone_status" = "completed" ]; then
        return 0
    fi

    echo "[$(date -u +%H:%M:%S)] Checking v0.6 milestone completion criteria (issue #1789)..."

    update_identity_bucket_from_constitution

    local criteria_met=0
    local criteria_report=""

    # ── Read S3 swarm dissolution records ────────────────────────────────────
    # Swarm summaries are written to s3://agentex-thoughts/swarm-memories/*.json
    # by the swarm memory persistence feature (issue #1773).
    # NOTE: Path must be swarm-memories/ to match write_swarm_memory() in helpers.sh (issue #1799).
    local swarm_files
    swarm_files=$(aws s3 ls "s3://${IDENTITY_BUCKET}/swarm-memories/" \
        --region "$BEDROCK_REGION" 2>/dev/null | \
        awk '{print $4}' | grep '\.json$' | grep -v '^$' | head -100 || echo "")

    local swarm_memory_count=0
    local max_coalition_size=0
    local emergent_goal_count=0
    local swarm_formation_count=0

    for sfile in $swarm_files; do
        local sjson
        sjson=$(aws s3 cp "s3://${IDENTITY_BUCKET}/swarm-memories/${sfile}" - \
            --region "$BEDROCK_REGION" 2>/dev/null || echo "")
        [ -z "$sjson" ] && continue

        swarm_memory_count=$((swarm_memory_count + 1))
        swarm_formation_count=$((swarm_formation_count + 1))

        # Issue #1882: Check coalition size using .members array (what write_swarm_memory actually writes).
        # write_swarm_memory() and check_swarm_dissolution() both write JSON key "members" (array).
        # The old code read .memberCount (never written) and .memberAgents (never written in S3 records),
        # causing max_coalition_size to always be 0. Fix: read .members array length first,
        # fall back to .memberAgents for backward compat, then .memberCount for any future format.
        local member_array_len
        member_array_len=$(echo "$sjson" | jq -r '(.members // .memberAgents // []) | if type == "array" then length elif type == "string" then (split(",") | map(select(. != "")) | length) else 0 end' 2>/dev/null || echo "0")
        [[ "$member_array_len" =~ ^[0-9]+$ ]] || member_array_len=0
        if [ "$member_array_len" -gt "$max_coalition_size" ]; then
            max_coalition_size=$member_array_len
        fi

        # Check for emergent goals (agent-proposed goal, not god-assigned)
        local goal_origin
        goal_origin=$(echo "$sjson" | jq -r '.goalOrigin // ""' 2>/dev/null || echo "")
        if [ "$goal_origin" = "agent-proposed" ] || [ "$goal_origin" = "emergent" ]; then
            emergent_goal_count=$((emergent_goal_count + 1))
        fi
    done

    # Also count live (non-disbanded) swarms from activeSwarms for formation count
    local active_swarms_field
    active_swarms_field=$(get_state "activeSwarms" 2>/dev/null || echo "")
    if [ -n "$active_swarms_field" ]; then
        local live_swarm_count
        live_swarm_count=$(echo "$active_swarms_field" | tr '|' '\n' | grep -c '.' 2>/dev/null || echo "0")
        [[ "$live_swarm_count" =~ ^[0-9]+$ ]] || live_swarm_count=0
        swarm_formation_count=$((swarm_formation_count + live_swarm_count))

        # Check coalition sizes of live swarms from their state ConfigMaps
        while IFS=':' read -r swarm_name _rest; do
            [ -z "$swarm_name" ] && continue
            local live_members
            live_members=$(kubectl_with_timeout 10 get configmap "${swarm_name}-state" \
                -n "$NAMESPACE" -o jsonpath='{.data.memberAgents}' 2>/dev/null | \
                tr ',' '\n' | grep -c '.' 2>/dev/null || echo "0")
            [[ "$live_members" =~ ^[0-9]+$ ]] || live_members=0
            if [ "$live_members" -gt "$max_coalition_size" ]; then
                max_coalition_size=$live_members
            fi
        done < <(echo "$active_swarms_field" | tr '|' '\n' | grep -v '^$' || true)
    fi

    echo "[$(date -u +%H:%M:%S)] v0.6 swarm data: formations=${swarm_formation_count} maxCoalition=${max_coalition_size} emergentGoals=${emergent_goal_count} memoryRecords=${swarm_memory_count}"

    # ── Criterion 1: 2+ swarm formations recorded ────────────────────────────
    if [ "$swarm_formation_count" -ge 2 ]; then
        criteria_met=$((criteria_met + 1))
        criteria_report="${criteria_report}✅ Criterion 1: Swarm formations — ${swarm_formation_count} swarms formed\n"
    else
        criteria_report="${criteria_report}⏳ Criterion 1: Swarm formations — ${swarm_formation_count}/2 swarms formed\n"
    fi
    echo "[$(date -u +%H:%M:%S)] v0.6 Criterion 1: ${swarm_formation_count} swarm formations (need 2)"

    # ── Criterion 2: Max coalition size >= 3 ────────────────────────────────
    if [ "$max_coalition_size" -ge 3 ]; then
        criteria_met=$((criteria_met + 1))
        criteria_report="${criteria_report}✅ Criterion 2: Coalition size — max ${max_coalition_size} agents in one swarm\n"
    else
        criteria_report="${criteria_report}⏳ Criterion 2: Coalition size — max ${max_coalition_size}/3 agents in any swarm\n"
    fi
    echo "[$(date -u +%H:%M:%S)] v0.6 Criterion 2: max coalition size ${max_coalition_size} (need 3)"

    # ── Criterion 3: 1+ agent-proposed goals pursued by swarm ───────────────
    if [ "$emergent_goal_count" -ge 1 ]; then
        criteria_met=$((criteria_met + 1))
        criteria_report="${criteria_report}✅ Criterion 3: Emergent goals — ${emergent_goal_count} agent-proposed goal(s) pursued\n"
    else
        criteria_report="${criteria_report}⏳ Criterion 3: Emergent goals — no agent-proposed swarm goals yet\n"
    fi
    echo "[$(date -u +%H:%M:%S)] v0.6 Criterion 3: ${emergent_goal_count} emergent goal(s) (need 1)"

    # ── Criterion 4: 1+ swarm summaries written to S3 on dissolution ────────
    if [ "$swarm_memory_count" -ge 1 ]; then
        criteria_met=$((criteria_met + 1))
        criteria_report="${criteria_report}✅ Criterion 4: Swarm memory — ${swarm_memory_count} dissolution record(s) in S3\n"
    else
        criteria_report="${criteria_report}⏳ Criterion 4: Swarm memory — no dissolution records in S3 yet\n"
    fi
    echo "[$(date -u +%H:%M:%S)] v0.6 Criterion 4: ${swarm_memory_count} swarm dissolution records in S3 (need 1)"

    # ── Store progress in coordinator-state for observability ─────────────────
    local status_summary="${criteria_met}/4 criteria met"
    local safe_report
    safe_report=$(printf '%s' "$criteria_report" | tr '\n' ' ' | sed 's/"/\\"/g' | tr -s ' ')
    local safe_status
    safe_status=$(printf '%s' "${status_summary} | ${safe_report}" | tr '\n' ' ' | sed 's/"/\\"/g')
    kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
        -p "{\"data\":{\"v06CriteriaStatus\":\"${safe_status}\"}}" 2>/dev/null || true

    echo "[$(date -u +%H:%M:%S)] v0.6 milestone check: ${criteria_met}/4 criteria met"

    # ── All 4 criteria met: declare milestone complete ────────────────────────
    if [ "$criteria_met" -eq 4 ]; then
        echo "[$(date -u +%H:%M:%S)] 🎉 v0.6 MILESTONE COMPLETE — All 4 Collective Action criteria met!"

        # Mark as completed in coordinator-state
        kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
            -p '{"data":{"v06MilestoneStatus":"completed"}}' 2>/dev/null || true

        # Post milestone completion Thought CR
        kubectl_with_timeout 10 apply -f - <<MILESTONE_THOUGHT_EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-v06-milestone-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  agentRef: coordinator
  taskRef: coordinator-milestone
  thoughtType: insight
  confidence: 10
  content: |
    🎉 v0.6 COLLECTIVE ACTION MILESTONE COMPLETE (issue #1789)

    All 4 success criteria verified by coordinator check_v06_milestone():
$(printf '%s' "$criteria_report" | sed 's/^/    /')

    The civilization has achieved:
    - Spontaneous swarm formation (agents self-organizing without direct assignment)
    - Coalition sizes of 3+ specialist agents coordinating on shared goals
    - Agent-proposed goals pursued by emergent swarms (true self-direction)
    - Swarm memory persistence (dissolution records in S3 for continuity)

    Recommendation: Begin v0.7 planning. Swarm intelligence is operational.
MILESTONE_THOUGHT_EOF

        # File GitHub issue announcing v0.6 completion
        local milestone_body="## v0.6 Collective Action Milestone COMPLETE

Automatically verified by coordinator \`check_v06_milestone()\` function (issue #1789).

All 4 success criteria have been met:

$(printf '%s' "$criteria_report" | sed 's/\\n/\n/g')

### What This Means

The civilization has achieved collective action — agents form spontaneous coalitions
and coordinate emergent swarms around complex goals. Agents:
- Self-organize into swarms without direct god assignment
- Form coalitions of 3+ specialists around shared goals
- Propose their own swarm goals via governance (not just executing assigned tasks)
- Persist swarm memory to S3 so future civilizations can learn from past coalitions

### Next Step

Begin v0.7 milestone planning. Suggest: focus on **inter-swarm coordination** —
swarms reasoning about other swarms' work and collaborating across goal boundaries.

Closes #1771"

        gh issue create \
            --repo "${GITHUB_REPO}" \
            --title "milestone: v0.6 Collective Action COMPLETE — all criteria verified by coordinator" \
            --label "enhancement,self-improvement" \
            --body "$milestone_body" 2>/dev/null || \
            echo "[$(date -u +%H:%M:%S)] WARNING: Could not file v0.6 completion issue (non-fatal)"

        push_metric "MilestoneCompleted" 1 "Count" "Milestone=v0.6"
    fi
}

# ── Identity-Based Task Routing (issue #1113) ────────────────────────────────
#
# Routes tasks to agents whose S3 identity shows relevant prior work,
# enabling emergent specialization. When an agent has a specialization score
# above SPECIALIZATION_ROUTING_THRESHOLD for a task, the coordinator prefers
# that agent over a generic assignment.
#
# Scoring formula:
#   score = (label_matches * 3) + (keyword_matches * 2)
#   - label_matches: count of issue labels that match agent's specializationLabelCounts
#   - keyword_matches: count of title/body keywords matching agent's specializationDetail.codeAreas
#
# Routing decision:
#   - score > SPECIALIZATION_ROUTING_THRESHOLD (2): route to specialized agent
#   - score <= threshold: fall back to normal assignment
#
# Metrics tracked:
#   - specializedAssignments: count of specialized task assignments
#   - genericAssignments: count of generic (fallback) task assignments
#   - lastSpecializedRouting: timestamp of most recent specialized routing
#
# ── DATA CONTRACT: Expected S3 Identity JSON Schema ──────────────────────────
#
# Agent identity files are stored at:
#   s3://${IDENTITY_BUCKET}/identities/<agent-cr-name>.json
#
# The fields read by score_agent_for_issue() are:
#   {
#     "specialization": "enhancement",         # string: primary specialization label
#     "specializationLabelCounts": {           # object: label -> count of issues worked
#       "enhancement": 5,
#       "bug": 3
#     },
#     "specializationDetail": {
#       "codeAreas": {                         # object: filename -> count of PRs touching it
#         "entrypoint.sh": 3,
#         "coordinator.sh": 2
#       },
#       "debatesWon": 0,
#       "synthesisCount": 2,
#       "citedSynthesesCount": 3,              # shared counter: debate citations + mentor credits
#       "successfulMentorships": 2,            # issue #1743: mentor-only counter for routing bonus
#       "debateQualityScore": 21,              # computed: (synthesisCount*2) + (citedSynthesesCount*5)
#       "mentorCredits": [...]                 # array: [{creditedBy, at}] — log of workers who credited
#     },
#     "reputationAverage": 7,                  # issue #1602: rolling average visionScore (last 10 runs)
#     "reputationHistory": [...]               # issue #1602: last 10 {timestamp, visionScore, workSummary}
#     "promotedRole": "worker:enhancement-specialist",  # issue #1733: role after promotion criteria met
#     "promotedAt": "2026-03-10T00:00:00Z",   # issue #1733: when promotion was awarded
#     "promotionReason": "..."                 # issue #1733: which criterion triggered promotion
#   }
#
# IMPORTANT: If identity.sh changes these field names, update the jq paths in
# score_agent_for_issue() below. Schema drift between identity.sh and this
# function silently breaks routing (score always 0). See issues #1133, #1134.
# ─────────────────────────────────────────────────────────────────────────────

# Read S3 bucket for identities from constitution at runtime
# Override the default set at script top with the live value if available
update_identity_bucket_from_constitution() {
    local s3_bucket
    s3_bucket=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "")
    if [ -n "$s3_bucket" ]; then
        IDENTITY_BUCKET="$s3_bucket"
    fi
}

# Score an agent's identity against a GitHub issue
# Arguments:
#   $1 - agent_name (Kubernetes agent CR name, e.g., worker-1773115086)
#   $2 - issue_number
#   $3 - issue_labels (comma-separated string, e.g., "enhancement,bug")
#   $4 - issue_keywords (space-separated keywords from title/body)
# Returns: integer score via stdout (0 if agent has no specialization data)
#
# Issue #1475: canonical history lookup.
# Agents are ephemeral (new agent_name per pod). Specialization history accumulates
# per-session and is written at exit. A new worker pod has no identity file yet.
# Fix: after reading agent_name file (may be empty for new pods), also check the
# canonical history file at identities/canonical/<displayName>.json (written by
# save_identity() since PR #1489). This allows returning workers (who reclaim a
# display name) to have their historical specialization considered immediately.
score_agent_for_issue() {
    local agent_name="$1"
    local issue_number="$2"
    local issue_labels="$3"
    local issue_keywords="$4"
     local passed_display_name="${5:-}"  # Issue #1515: optional displayName from activeAgents triplet
     local trust_graph_cache="${6:-}"   # Issue #1750: pre-fetched trust graph (avoids N kubectl calls)

    # Read agent identity from S3 — first try per-session file (may be empty for new agents)
    local identity_json=""
    identity_json=$(aws s3 cp "s3://${IDENTITY_BUCKET}/identities/${agent_name}.json" - \
        --region "$BEDROCK_REGION" 2>/dev/null || echo "")

    # Issue #1475 / #1515: try to upgrade to canonical history.
    # The per-session file contains only THIS session's data (usually empty for new agents
    # since it is written at EXIT, not at startup).
    # The canonical file at identities/canonical/<displayName>.json contains accumulated
    # history across all sessions using this display name (written by identity.sh PR #1489).
    #
    # Bug in PR #1505: canonical lookup was only attempted when per-session file existed.
    # Fix (issue #1515): try canonical lookup with passed_display_name FIRST (when available),
    # before giving up on an empty per-session file.
    local display_name=""

    if [ -n "$identity_json" ]; then
        # Per-session file exists — extract displayName from it
        display_name=$(echo "$identity_json" | jq -r '.displayName // ""' 2>/dev/null || echo "")
    fi

    # Prefer the passed displayName from activeAgents registration (more reliable than
    # per-session file which may be empty or from a prior agent with the same name slot).
    if [ -n "$passed_display_name" ] && [ "$passed_display_name" != "$agent_name" ]; then
        display_name="$passed_display_name"
    fi

    # Try canonical lookup whenever we have a display_name (even if per-session file is empty)
    if [ -n "$display_name" ] && [ "$display_name" != "$agent_name" ]; then
        local canonical_json
        canonical_json=$(aws s3 cp "s3://${IDENTITY_BUCKET}/identities/canonical/${display_name}.json" - \
            --region "$BEDROCK_REGION" 2>/dev/null || echo "")
        if [ -n "$canonical_json" ]; then
            # Use canonical (accumulated) history instead of per-session (fresh) file
            identity_json="$canonical_json"
            echo "[$(date -u +%H:%M:%S)] Routing: using canonical history for $agent_name (displayName=$display_name)" >&2
        fi
    fi

    if [ -z "$identity_json" ]; then
        echo "0"
        return 0
    fi

    # Check if identity has ANY specialization data (label counts or code areas).
    # NOTE: Do NOT gate on .specialization string field — that is only set after 3+ issues
    # with the same label (update_specialization threshold). Scoring should work as soon as
    # an agent has any label count history (even 1 issue). Without this, routing always
    # returns 0 until an agent crosses the threshold, making v0.2 routing non-functional.
    # Issue #1152: removed premature early-exit on empty .specialization string.
    local has_label_data
    has_label_data=$(echo "$identity_json" | jq -r \
        'if (.specializationLabelCounts | length) > 0 or (.specializationDetail.codeAreas | length) > 0 then "yes" else "" end' \
        2>/dev/null || echo "")
    if [ -z "$has_label_data" ]; then
        echo "0"
        return 0
    fi

    local score=0

    # Score label matches (weight 3 each)
    # Identity JSON schema (identity.sh): label counts are in .specializationLabelCounts{}
    # NOT in .specialization.issueLabels{} — that path was incorrect (issue #1134 fix, PR #1136)
    if [ -n "$issue_labels" ]; then
        IFS=',' read -ra label_arr <<< "$issue_labels"
        for label in "${label_arr[@]}"; do
            label=$(echo "$label" | tr -d ' ')
            [ -z "$label" ] && continue
            local label_count
            label_count=$(echo "$identity_json" | jq -r \
                --arg lbl "$label" \
                '(.specializationLabelCounts[$lbl] // 0) | tonumber' 2>/dev/null || echo "0")
            if [ "$label_count" -gt 0 ]; then
                score=$((score + 3))
            fi
        done
    fi

    # Score keyword matches against codeAreas (weight 2 each)
    # Identity JSON schema (identity.sh): code areas are in .specializationDetail.codeAreas{}
    # NOT in .specialization.codeAreas{} — that path was incorrect (issue #1134 fix, PR #1136)
    if [ -n "$issue_keywords" ]; then
        local code_areas
        code_areas=$(echo "$identity_json" | jq -r \
            '.specializationDetail.codeAreas // {} | keys | .[]' 2>/dev/null || echo "")
        for area in $code_areas; do
            local area_count
            area_count=$(echo "$identity_json" | jq -r \
                --arg a "$area" \
                '.specializationDetail.codeAreas[$a] // 0 | tonumber' 2>/dev/null || echo "0")
            if [ "$area_count" -gt 0 ]; then
                # Check if any keyword matches this code area
                for kw in $issue_keywords; do
                    if echo "$area" | grep -qi "$kw" || echo "$kw" | grep -qi "$area"; then
                        score=$((score + 2))
                        break  # each area contributes at most 2 points
                    fi
                done
            fi
        done
    fi

     # Issue #1602: Factor in reputationAverage for enhancement-labeled issues.
     # Agents with higher average visionScore get a bonus when routing vision-critical issues.
     # This enables reputation-based routing: high-vision agents get enhancement tasks.
     # Bonus: +2 if reputationAverage >= 7 AND issue has "enhancement" label.
     local rep_average
     rep_average=$(echo "$identity_json" | jq -r '.reputationAverage // 0' 2>/dev/null || echo "0")
     local rep_average_int
     rep_average_int=$(echo "$rep_average" | awk '{printf "%d", $1}' 2>/dev/null || echo "0")
     if echo "$issue_labels" | grep -qi "enhancement" && [ "$rep_average_int" -ge 7 ]; then
         score=$((score + 2))
         echo "[$(date -u +%H:%M:%S)] Routing: reputation bonus +2 for $agent_name (reputationAverage=$rep_average, enhancement issue)" >&2
     fi

     # Issue #1604: Factor in debateQualityScore for architectural issues.
     # Agents who produce syntheses that other agents cite are high-quality debaters.
     # Reward them with routing priority on enhancement/self-improvement issues.
     # Bonus: +3 if debateQualityScore > 10 AND issue has "enhancement" or "self-improvement" label.
     local debate_quality_score
     debate_quality_score=$(echo "$identity_json" | jq -r '.specializationDetail.debateQualityScore // 0' 2>/dev/null || echo "0")
     local debate_quality_int
     debate_quality_int=$(echo "$debate_quality_score" | awk '{printf "%d", $1}' 2>/dev/null || echo "0")
     if (echo "$issue_labels" | grep -qiE "enhancement|self-improvement") && [ "$debate_quality_int" -gt 10 ]; then
         score=$((score + 3))
         echo "[$(date -u +%H:%M:%S)] Routing: debate quality bonus +3 for $agent_name (debateQualityScore=$debate_quality_score, architectural issue)" >&2
     fi

     # Issue #1733: Factor in promotedRole for routing priority.
     # Agents promoted to a specialist role via promote_agent_role() get a +4 bonus
     # when the issue domain matches their specialization.
     # Bonus: +4 if promotedRole contains the issue's label or "specialist".
     local promoted_role
     promoted_role=$(echo "$identity_json" | jq -r '.promotedRole // ""' 2>/dev/null || echo "")
     if [ -n "$promoted_role" ]; then
         # Extract the specialization suffix from the promoted role (e.g., "enhancement-specialist")
         local spec_suffix
         spec_suffix=$(echo "$promoted_role" | cut -d: -f2 | tr -d '[:space:]')
         # Check if any issue label matches the specialist suffix
         local label_match=false
         if [ -n "$issue_labels" ]; then
             IFS=',' read -ra promo_label_arr <<< "$issue_labels"
             for label in "${promo_label_arr[@]}"; do
                 label=$(echo "$label" | tr -d ' ')
                 [ -z "$label" ] && continue
                 if echo "$spec_suffix" | grep -qi "$label" || echo "$label" | grep -qi "${spec_suffix%%-specialist}"; then
                     label_match=true
                     break
                 fi
             done
         fi
         if [ "$label_match" = "true" ]; then
             score=$((score + 4))
             echo "[$(date -u +%H:%M:%S)] Routing: promoted role bonus +4 for $agent_name (promotedRole=$promoted_role, issue labels=$issue_labels)" >&2
         fi
     fi

     # Issue #1750: v0.5 Feature #2 — Trust graph routing bonus.
     # Agents cited by 2+ distinct peers in debate syntheses earn +2 routing bonus.
     # The trust graph is built by cite_debate_outcome() in helpers.sh (issue #1734).
     # Uses pre-fetched cache to avoid N kubectl calls per routing cycle.
     local trust_graph="$trust_graph_cache"
     if [ -z "$trust_graph" ]; then
         trust_graph=$(kubectl_with_timeout 10 get configmap coordinator-state \
             -n "$NAMESPACE" -o jsonpath='{.data.agentTrustGraph}' 2>/dev/null || echo "")
     fi
     if [ -n "$trust_graph" ] && [ -n "$agent_name" ]; then
         local distinct_citers
         distinct_citers=$(echo "$trust_graph" | tr '|' '\n' | \
             grep -E "^[^:]+:${agent_name}:[0-9]+$" | \
             cut -d: -f1 | sort -u | wc -l | tr -d '[:space:]')
         distinct_citers=${distinct_citers:-0}
         if [ "$distinct_citers" -ge 2 ]; then
             score=$((score + 2))
             echo "[$(date -u +%H:%M:%S)] Routing: trust graph bonus +2 for $agent_name (cited by $distinct_citers distinct peers)" >&2
         fi
     fi

     # Issue #1743: v0.5 Feature #4 — Successful mentorships routing bonus.
     # Agents with a track record of successful mentorships earn a routing bonus,
     # prioritizing proven teachers for complex issues matching their specialization.
     # Bonus: +2 per successfulMentorship, capped at +6 (3 mentorships max).
     # Uses the dedicated .specializationDetail.successfulMentorships counter written by
     # credit_mentor_for_success() in helpers.sh — separate from citedSynthesesCount.
     local successful_mentorships
     successful_mentorships=$(echo "$identity_json" | jq -r \
         '.specializationDetail.successfulMentorships // 0 | tonumber' 2>/dev/null || echo "0")
     if [ "$successful_mentorships" -gt 0 ]; then
         local mentorship_bonus
         mentorship_bonus=$(( successful_mentorships * 2 ))
         # Cap at +6 to prevent single-mentor routing dominance
         if [ "$mentorship_bonus" -gt 6 ]; then
             mentorship_bonus=6
         fi
         score=$((score + mentorship_bonus))
         echo "[$(date -u +%H:%M:%S)] Routing: mentorship bonus +${mentorship_bonus} for $agent_name (successfulMentorships=${successful_mentorships})" >&2
     fi

     echo "$score"
}

# Extract keywords from an issue for specialization matching
# Arguments:
#   $1 - issue_number
# Returns: space-separated keyword list via stdout
extract_issue_keywords() {
    local issue_number="$1"
    local issue_json
    issue_json=$(gh issue view "$issue_number" --repo "${GITHUB_REPO}" \
        --json title,body 2>/dev/null || echo "")
    [ -z "$issue_json" ] && echo "" && return 0

    # Extract title + body, normalize to lowercase tokens
    local title body combined
    title=$(echo "$issue_json" | jq -r '.title // ""' 2>/dev/null || echo "")
    body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null | head -5 || echo "")
    combined="$title $body"

    # Extract meaningful keywords (words 4+ chars, avoid common stopwords)
    echo "$combined" | tr '[:upper:]' '[:lower:]' | \
        grep -oE '[a-z][a-z0-9_/-]{3,}' | \
        grep -vE '^(this|that|with|from|have|will|when|then|also|each|they|them|been|were|the|for|and|are|but|not|you|all|can|her|was|one|our|out|day|get|has|him|his|how|its|may|new|now|old|see|two|way|who|any|its|use|into|than|more|some|such|what|like|your|just|into|over|after|where|must|first|their|about|these|those|which|would|could|should|there)$' | \
        sort -u | head -20 | tr '\n' ' '
}

# Find the best specialized agent for a given issue from among active agents
# Arguments:
#   $1 - issue_number
#   $2 - issue_labels (comma-separated)
#   $3 - active_assignments (pre-fetched from caller to avoid redundant kubectl calls, issue #1478)
# Returns: best agent name if score > threshold, empty string otherwise
find_best_agent_for_issue() {
    local issue_number="$1"
    local issue_labels="$2"
    local active_assignments="${3:-}"  # Issue #1478: passed from caller to avoid N redundant get_state calls

    # Get active agents
    local active_agents
    active_agents=$(get_state "activeAgents")
    if [ -z "$active_agents" ]; then
        echo ""
        return 0
    fi

    # If caller didn't pass active_assignments, fetch once here (fallback for direct calls)
    if [ -z "$active_assignments" ]; then
        active_assignments=$(get_state "activeAssignments")
    fi

     # Extract issue keywords (limit API calls by calling once)
     local issue_keywords
     issue_keywords=$(extract_issue_keywords "$issue_number")

     # Issue #1750: v0.5 Feature #2 — Pre-fetch trust graph once per routing cycle.
     # Pass to score_agent_for_issue() to avoid N kubectl calls (one per agent being scored).
     local trust_graph_cache
     trust_graph_cache=$(kubectl_with_timeout 10 get configmap coordinator-state \
         -n "$NAMESPACE" -o jsonpath='{.data.agentTrustGraph}' 2>/dev/null || echo "")

     local best_agent=""
    local best_score=0

    IFS=',' read -ra agent_pairs <<< "$active_agents"
    for pair in "${agent_pairs[@]}"; do
        [ -z "$pair" ] && continue
        local agent_name="${pair%%:*}"
        # Use cut for role: supports both "name:role" and "name:role:displayName" format
        local agent_role
        agent_role=$(echo "$pair" | cut -d: -f2 | tr -d '[:space:]')
        # Issue #1515: extract displayName from triplet (name:role:displayName)
        # Supports old "name:role" format (displayName will be empty string)
        local agent_display_name
        agent_display_name=$(echo "$pair" | cut -d: -f3)

        # Only consider worker agents for specialization routing
        [ "$agent_role" != "worker" ] && continue

        # Don't route to agents that already have assignments
        # Issue #1478: use pre-fetched active_assignments instead of calling get_state N times
        if echo "$active_assignments" | grep -q "${agent_name}:"; then
            continue
        fi

         local agent_score
         # Issue #1515: pass displayName so score_agent_for_issue() can try canonical
         # lookup even when the per-session S3 file is empty (new agent pods)
         # Issue #1750: pass pre-fetched trust_graph_cache to avoid N kubectl calls
         agent_score=$(score_agent_for_issue "$agent_name" "$issue_number" \
             "$issue_labels" "$issue_keywords" "$agent_display_name" "$trust_graph_cache")

        echo "[$(date -u +%H:%M:%S)] Specialization score for $agent_name (displayName=${agent_display_name:-?}) on issue #$issue_number: $agent_score" >&2

        if [ "$agent_score" -gt "$best_score" ]; then
            best_score="$agent_score"
            best_agent="$agent_name"
        fi
    done

    # Only return if score exceeds threshold
    if [ "$best_score" -gt "$SPECIALIZATION_ROUTING_THRESHOLD" ]; then
        echo "[$(date -u +%H:%M:%S)] Specialized routing: $best_agent (score=$best_score) → issue #$issue_number" >&2
        echo "$best_agent"
    else
        echo ""
    fi
}

# Perform identity-based task routing cycle:
# For each issue in the task queue that is NOT yet assigned, attempt to find
# a specialized agent. Record routing decisions and emit metrics.
route_tasks_by_specialization() {
    echo "[$(date -u +%H:%M:%S)] Running identity-based task routing (issue #1113)..."

    # Update S3 bucket from constitution (runtime portability)
    update_identity_bucket_from_constitution

    local task_queue
    task_queue=$(get_state "taskQueue")
    if [ -z "$task_queue" ]; then
        echo "[$(date -u +%H:%M:%S)] Task queue empty, skipping specialization routing"
        return 0
    fi

    local active_assignments
    active_assignments=$(get_state "activeAssignments")

    local specialized_count=0
    local generic_count=0
    local routing_log=""
    # Issue #1675: track unassigned issues seen — routing should only trigger
    # routingCyclesWithZeroSpec escalation when there WERE unassigned issues
    # to route (but no specialized agent was found). If all issues are already
    # assigned, the cycle counter must NOT increment (routing "succeeded" by
    # having nothing to do). Without this, a busy system with all tasks
    # pre-claimed generates false-positive "v0.2 routing regression" issues.
    local unassigned_count=0

     # Issue #1430: Pre-fetch issueLabels cache to avoid per-issue GitHub API calls
     # Cache format: "issue:label1,label2|issue2:label3|..."
     local labels_cache
     labels_cache=$(get_state "issueLabels" 2>/dev/null || echo "")

     # Issue #1811: Pre-fetch open PRs to skip issues that already have an open PR.
     # update_taskqueue() filters issues when building taskQueue, but there is a
     # timing race: a PR opened between the last taskQueue refresh (~2.5 min interval)
     # and this routing run (~3.5 min interval) causes routing to pre-claim an issue
     # that is already being implemented, resulting in duplicate PRs.
     # Fetching open PRs once here (outside the loop) prevents this without adding
     # per-issue API calls.
     local routing_covered_prs_json routing_covered_pr_issues
     routing_covered_prs_json=$(gh api "/repos/${GITHUB_REPO}/pulls?state=open&per_page=100" 2>/dev/null) || true
     routing_covered_pr_issues=""
     if [ -n "$routing_covered_prs_json" ]; then
         routing_covered_pr_issues=$(echo "$routing_covered_prs_json" | \
             jq -r '.[].body // ""' 2>/dev/null | \
             grep -oiE '(closes|fixes|resolves) #[0-9]+' | \
             grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
         local routing_covered_count
         routing_covered_count=$(echo "$routing_covered_pr_issues" | wc -w | tr -d ' ')
         echo "[$(date -u +%H:%M:%S)] Issue #1811: Routing open-PR check found $routing_covered_count covered issues — will skip from specialization routing"
     fi

     IFS=',' read -ra queue_issues <<< "$task_queue"
     for issue_num in "${queue_issues[@]}"; do
         [ -z "$issue_num" ] && continue
         # Issue #1521: trim whitespace — taskQueue can have legacy space-padded entries
         # (e.g., "1436 " from pre-PR-#1473 update_state() writes). Without trimming,
         # [[ "1436 " =~ ^[0-9]+$ ]] fails and routing skips ALL such entries, keeping
         # specializedAssignments=0 even when valid agents and matching issues exist.
         issue_num=$(echo "$issue_num" | tr -d '[:space:]')
         # Only handle numeric issue numbers
         [[ "$issue_num" =~ ^[0-9]+$ ]] || continue

         # Skip if already assigned
         # Issue #1488: Normalize spaces before grep — activeAssignments can have space-padded entries
         local normalized_active_assignments
         normalized_active_assignments=$(echo "$active_assignments" | tr -d ' ')
         if echo "$normalized_active_assignments" | grep -q ":${issue_num}$" || \
            echo "$normalized_active_assignments" | grep -q ":${issue_num},"; then
             continue
         fi

         # Issue #1811: Skip issues that already have an open PR to prevent duplicate work.
         # Guards against the race between taskQueue refresh and routing pre-claim.
         if [ -n "$routing_covered_pr_issues" ] && echo " $routing_covered_pr_issues " | grep -q " $issue_num "; then
             echo "[$(date -u +%H:%M:%S)] Issue #1811: Skipping issue #$issue_num in routing — open PR already exists"
             continue
         fi

         # Count unassigned issues seen this cycle (issue #1675: needed for false-positive prevention)
         unassigned_count=$((unassigned_count + 1))

        # Get issue labels for scoring — use cache first (issue #1430: rate-limit resilient)
        local issue_labels=""
        if [ -n "$labels_cache" ]; then
            issue_labels=$(echo "$labels_cache" | tr '|' '\n' | grep "^${issue_num}:" | cut -d: -f2- | head -1 || echo "")
        fi
        # Fall back to GitHub API on cache miss
        if [ -z "$issue_labels" ]; then
            issue_labels=$(gh issue view "$issue_num" --repo "${GITHUB_REPO}" \
                --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
        fi

        # Find best specialized agent
        # Issue #1478: pass active_assignments to avoid N redundant get_state calls inside find_best_agent_for_issue
         local best_agent
         best_agent=$(find_best_agent_for_issue "$issue_num" "$issue_labels" "$active_assignments")

        if [ -n "$best_agent" ]; then
            # Issue #1474: Pre-claim the issue on behalf of the specialized agent.
            # Write best_agent:issue_num directly to activeAssignments so the agent
            # finds its pre-assignment when it calls request_coordinator_task().
            # Without this, workers race to claim tasks BEFORE routing runs and
            # find nothing left to route, keeping specializedAssignments = 0 forever.
            local new_pre_assignments
            # Issue #1867: Use the local active_assignments variable (not a fresh ConfigMap
            # read) to build new_pre_assignments. A fresh get_state() call here may return
            # stale data that doesn't include earlier pre-claims made in this same routing
            # cycle, causing the same worker to be pre-claimed for multiple issues.
            # The local active_assignments is updated after each successful pre-claim above,
            # so it correctly tracks all assignments made in this cycle.
            if [ -z "$active_assignments" ]; then
                new_pre_assignments="${best_agent}:${issue_num}"
            else
                new_pre_assignments="${active_assignments},${best_agent}:${issue_num}"
            fi
            if update_state "activeAssignments" "$new_pre_assignments"; then
                # Update local variable so subsequent iterations see the new assignment
                active_assignments="$new_pre_assignments"

                # Issue #1546: Record pre-claim timestamp so cleanup_stale_assignments()
                # does not prune this entry before the worker's Job starts.
                # Format: "agent:issue:epoch_seconds;..." (semicolon-separated)
                local ts_epoch
                ts_epoch=$(date +%s)
                local ts_entry="${best_agent}:${issue_num}:${ts_epoch}"
                local cur_pre_claim_ts
                cur_pre_claim_ts=$(get_state "preClaimTimestamps" 2>/dev/null || echo "")
                if [ -z "$cur_pre_claim_ts" ]; then
                    update_state "preClaimTimestamps" "$ts_entry"
                else
                    update_state "preClaimTimestamps" "${cur_pre_claim_ts};${ts_entry}"
                fi

                # Record specialized routing decision in coordinator state
                local routing_entry="${issue_num}:${best_agent}"
                routing_log="${routing_log}${routing_entry};"
                specialized_count=$((specialized_count + 1))
                push_metric "SpecializedTaskRouting" 1 "Count" "IssueNumber=${issue_num}"
                echo "[$(date -u +%H:%M:%S)] SPECIALIZED ROUTING (pre-claimed): issue #$issue_num → $best_agent"
            else
                echo "[$(date -u +%H:%M:%S)] WARNING: pre-claim write failed for $best_agent:$issue_num — falling back to generic"
                generic_count=$((generic_count + 1))
            fi
        else
            generic_count=$((generic_count + 1))
        fi
    done

    # Update routing metrics in coordinator state
    if [ "$specialized_count" -gt 0 ] || [ "$generic_count" -gt 0 ]; then
        # Track cumulative specialized assignments
        local prev_specialized
        prev_specialized=$(get_state "specializedAssignments")
        [[ "$prev_specialized" =~ ^[0-9]+$ ]] || prev_specialized=0
        local new_specialized=$((prev_specialized + specialized_count))
        update_state "specializedAssignments" "$new_specialized"

        # Track cumulative generic assignments
        local prev_generic
        prev_generic=$(get_state "genericAssignments")
        [[ "$prev_generic" =~ ^[0-9]+$ ]] || prev_generic=0
        local new_generic=$((prev_generic + generic_count))
        update_state "genericAssignments" "$new_generic"

        # Record routing log for observability
        if [ -n "$routing_log" ]; then
            local ts
            ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            update_state "lastSpecializedRouting" "$ts"
            update_state "lastRoutingDecisions" "$routing_log"
        fi

        push_metric "SpecializedRoutingCycle" "$specialized_count" "Count" "Component=Coordinator"
        push_metric "GenericRoutingCycle" "$generic_count" "Count" "Component=Coordinator"
        echo "[$(date -u +%H:%M:%S)] Routing cycle complete: specialized=$specialized_count generic=$generic_count total_specialized_all_time=$new_specialized"
    fi

    # ── v0.2 Milestone Validation (issue #1145) ──────────────────────────────
    # If specializedAssignments is still 0 after routing has been attempted,
    # diagnose WHY and post a blocker thought for visibility. This surfaces
    # the v0.2 success criterion ("coordinator routes at least 1 task based on
    # agent specialization") to god-observers.
    #
    # Issue #1675: Only count a cycle as a routing "failure" when there WERE
    # unassigned issues available for routing. When all issues in the queue
    # were already assigned, the cycle is a "no-op" (not a failure) and must
    # NOT increment routingCyclesWithZeroSpec — otherwise a busy system with
    # all tasks pre-claimed generates false-positive v0.2 regression issues.
    local total_specialized
    total_specialized=$(get_state "specializedAssignments")
    [[ "$total_specialized" =~ ^[0-9]+$ ]] || total_specialized=0

    if [ "$total_specialized" -eq 0 ]; then
        # Issue #1675: skip escalation if there were no unassigned issues to route
        if [ "$unassigned_count" -eq 0 ]; then
            echo "[$(date -u +%H:%M:%S)] v0.2 VALIDATION: all queue issues already assigned — routing was a no-op (skipping zero-cycle increment)"
            return 0
        fi
        # Diagnose root cause: check active agents for specialization data
        local active_agents_list
        active_agents_list=$(get_state "activeAgents")
        local agents_with_spec=0
        local agents_checked=0

        IFS=',' read -ra agent_pairs <<< "$active_agents_list"
        for pair in "${agent_pairs[@]}"; do
            [ -z "$pair" ] && continue
            local aname
            aname=$(echo "$pair" | cut -d: -f1)
            [ -z "$aname" ] && continue
            agents_checked=$((agents_checked + 1))

            local spec_data=""
            # Issue #1517: try canonical path first (persistent cross-generation history),
            # then fall back to per-session path. Per-session files are empty for new agents,
            # causing the diagnostic to always report 0 agents with spec data.
            # Step 1: try to get displayName from per-session file
            local per_session_json=""
            per_session_json=$(aws s3 cp "s3://${IDENTITY_BUCKET}/identities/${aname}.json" - \
                --region "$BEDROCK_REGION" 2>/dev/null || echo "")
            if [ -n "$per_session_json" ]; then
                # Check per-session file for spec data first
                spec_data=$(echo "$per_session_json" | \
                    jq -r 'if (.specializationLabelCounts | length) > 0 then "yes" else "" end' \
                    2>/dev/null || echo "")
                # If no spec in per-session, try canonical path using displayName
                if [ -z "$spec_data" ]; then
                    local adisp
                    adisp=$(echo "$per_session_json" | jq -r '.displayName // ""' 2>/dev/null || echo "")
                    if [ -n "$adisp" ] && [ "$adisp" != "$aname" ]; then
                        spec_data=$(aws s3 cp "s3://${IDENTITY_BUCKET}/identities/canonical/${adisp}.json" - \
                            --region "$BEDROCK_REGION" 2>/dev/null | \
                            jq -r 'if (.specializationLabelCounts | length) > 0 then "yes" else "" end' \
                            2>/dev/null || echo "")
                    fi
                fi
            fi
            if [ -n "$spec_data" ]; then
                agents_with_spec=$((agents_with_spec + 1))
            fi
        done

        local blocker_reason
        # Issue #1716: Skip escalation when agents_checked=0 (transient startup condition).
        # When no agents have registered yet, this is NOT a routing failure — it's normal
        # system startup. Incrementing zero_cycles for this case causes false-positive
        # escalations and issue filing during cold starts. Only count cycles where agents
        # exist but routing still fails (agents_with_spec=0 or low match scores).
        if [ "$agents_checked" -eq 0 ]; then
            blocker_reason="No active agents registered in coordinator. Routing cannot fire."
            echo "[$(date -u +%H:%M:%S)] v0.2 VALIDATION: specializedAssignments=0 — $blocker_reason (TRANSIENT — not incrementing zero_cycles counter)"
            push_metric "V02RoutingBlocker" 1 "Count" "Component=Coordinator" "Reason=no-agents"
            # Skip counter increment and escalation — this is a normal startup condition
            return 0
        elif [ "$agents_with_spec" -eq 0 ]; then
            blocker_reason="No active agent has specializationLabelCounts data. Workers must complete at least 1 labeled issue to build specialization. Current agents: $agents_checked checked, 0 with spec data."
        else
            blocker_reason="${agents_with_spec}/${agents_checked} active agents have specialization data but no routing match found yet. Issue labels may not match agent specialization labels, or score threshold ($SPECIALIZATION_ROUTING_THRESHOLD) not met."
        fi

        echo "[$(date -u +%H:%M:%S)] v0.2 VALIDATION: specializedAssignments=0 — $blocker_reason"
        push_metric "V02RoutingBlocker" 1 "Count" "Component=Coordinator"

        # Issue #1568: Track consecutive routing cycles with zero specialization.
        # Increment counter; escalate with blocker thought + GitHub issue after 5 cycles.
        # This ensures routing regressions are self-reported within ~35 minutes.
        # Issue #1716: Counter only increments when agents exist but routing still fails.
        local zero_cycles
        zero_cycles=$(get_state "routingCyclesWithZeroSpec")
        [[ "$zero_cycles" =~ ^[0-9]+$ ]] || zero_cycles=0
        zero_cycles=$((zero_cycles + 1))
        update_state "routingCyclesWithZeroSpec" "$zero_cycles"
        echo "[$(date -u +%H:%M:%S)] routingCyclesWithZeroSpec: $zero_cycles (escalation threshold: 5)"

        if [ "$zero_cycles" -ge 5 ]; then
            # Escalate: post BLOCKER thought (high priority) AND file GitHub issue
            echo "[$(date -u +%H:%M:%S)] ESCALATING: specializedAssignments=0 for $zero_cycles consecutive routing cycles — filing issue"
            push_metric "V02RoutingEscalation" 1 "Count" "Component=Coordinator"

            post_coordinator_thought \
"BLOCKER: v0.2 ROUTING REGRESSION (issue #1568 — $zero_cycles consecutive cycles).
specializedAssignments=0 for $zero_cycles routing cycles (~$((zero_cycles * 7)) minutes).
Blocker: $blocker_reason
Threshold: SPECIALIZATION_ROUTING_THRESHOLD=$SPECIALIZATION_ROUTING_THRESHOLD
Active agents: $agents_checked checked, $agents_with_spec with specialization data
This is an automated escalation — v0.2 routing has failed for too long without self-healing.
See coordinator-state.routingCyclesWithZeroSpec for cycle count." \
                "blocker"

            # File GitHub issue for durable tracking (escalate to god-observer and planners)
            # Only file if we have GitHub access and haven't filed recently (throttle: every 10 cycles)
            if [ "$((zero_cycles % 10))" -eq 5 ] || [ "$zero_cycles" -eq 5 ]; then
                local escalation_issue
                escalation_issue=$(gh issue create \
                    --repo "${GITHUB_REPO}" \
                    --title "bug: specializedAssignments=0 for ${zero_cycles} consecutive routing cycles — v0.2 regression" \
                    --label "bug,self-improvement" \
                    --body "## Auto-filed by coordinator (issue #1568 — routing cycle escalation)

### Problem
\`specializedAssignments\` has been 0 for **${zero_cycles} consecutive routing cycles** (~$((zero_cycles * 7)) minutes).

This means the v0.2 milestone criterion (coordinator routes at least 1 task based on specialization) has regressed.

### Root Cause Diagnosis
${blocker_reason}

### Threshold Status
- SPECIALIZATION_ROUTING_THRESHOLD: ${SPECIALIZATION_ROUTING_THRESHOLD}
- Active agents checked: ${agents_checked}
- Agents with specialization data: ${agents_with_spec}

### Fix
Investigate why routing is not firing. Common causes:
1. Workers claim tasks before routing runs (issue #1474)
2. Specialization data missing from S3 (issue #1536)
3. Label cache stale (issue #1442)

Filed automatically by coordinator after ${zero_cycles} cycles with specializedAssignments=0 (issue #1568)." \
                    2>/dev/null || echo "")
                if [ -n "$escalation_issue" ]; then
                    echo "[$(date -u +%H:%M:%S)] v0.2 escalation issue filed: $escalation_issue"
                else
                    echo "[$(date -u +%H:%M:%S)] WARNING: Failed to file escalation issue (GitHub API unavailable)"
                fi
            fi
        else
            # Not yet at escalation threshold — post regular insight thought
            post_coordinator_thought \
"v0.2 MILESTONE VALIDATION (issue #1145): specializedAssignments=0 after routing cycle.
Blocker: $blocker_reason
Threshold: SPECIALIZATION_ROUTING_THRESHOLD=$SPECIALIZATION_ROUTING_THRESHOLD (1 label match = score 3, triggers routing)
Active agents: $agents_checked checked, $agents_with_spec with specialization data
To unblock: Workers must complete labeled GitHub issues so update_specialization() builds their history.
v0.2 criterion: coordinator routes at least 1 task based on agent specialization.
Consecutive zero cycles: $zero_cycles/5 (escalates to blocker at 5 cycles, ~35 min — issue #1568)" \
                "insight"
        fi
    else
        echo "[$(date -u +%H:%M:%S)] v0.2 VALIDATION PASSED: specializedAssignments=$total_specialized (routing has fired)"
        push_metric "V02RoutingSuccess" "$total_specialized" "Count" "Component=Coordinator"
        # Issue #1568: Reset cycle counter when routing succeeds
        local cur_zero_cycles
        cur_zero_cycles=$(get_state "routingCyclesWithZeroSpec")
        if [ -n "$cur_zero_cycles" ] && [ "$cur_zero_cycles" != "0" ]; then
            update_state "routingCyclesWithZeroSpec" "0"
            echo "[$(date -u +%H:%M:%S)] routingCyclesWithZeroSpec reset to 0 (routing succeeded)"
        fi
    fi
}


echo "Coordinator entering main loop..."
update_state "phase" "Active"

# Initialize spawnSlots on startup (atomic spawn gate, issue #519, fix #632)
# ALWAYS reconcile against actual running jobs on startup — never preserve stale values.
# A stale slots=0 from a crash/restart would freeze the spawn gate until iteration 4.
echo "[$(date -u +%H:%M:%S)] Reconciling spawnSlots on startup..."
reconcile_spawn_slots

# Seed the task queue on first start if empty
INITIAL_QUEUE=$(get_state "taskQueue")
if [ -z "$INITIAL_QUEUE" ]; then
    echo "[$(date -u +%H:%M:%S)] Seeding initial task queue from GitHub..."
    refresh_task_queue
fi

# ── HTTP Health Endpoint (issue #699) ───────────────────────────────────────
# Start a background HTTP server that responds to health checks
# Returns 200 if heartbeat is fresh (< 120s old), 503 if stale
start_health_endpoint() {
    local health_port=8080
    echo "[$(date -u +%H:%M:%S)] Starting HTTP health endpoint on port ${health_port}..."
    
    while true; do
        # Use netcat to listen for HTTP requests
        # Read the request (we don't parse it, just respond to any GET)
        response=$(mktemp)
        
        # Get lastHeartbeat from ConfigMap
        last_heartbeat=$(get_state "lastHeartbeat")
        current_time=$(date +%s)
        
        # Calculate age of last heartbeat
        if [ -n "$last_heartbeat" ]; then
            heartbeat_epoch=$(date -d "$last_heartbeat" +%s 2>/dev/null || echo "0")
            age=$((current_time - heartbeat_epoch))
        else
            age=999999  # No heartbeat yet
        fi
        
        # Stale threshold: 120 seconds (4 missed heartbeats)
        if [ "$age" -lt 120 ]; then
            # Healthy
            cat > "$response" <<EOF
HTTP/1.1 200 OK
Content-Type: application/json
Connection: close

{"status":"healthy","lastHeartbeat":"$last_heartbeat","ageSeconds":$age}
EOF
        else
            # Unhealthy
            cat > "$response" <<EOF
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
Connection: close

{"status":"unhealthy","lastHeartbeat":"$last_heartbeat","ageSeconds":$age,"reason":"heartbeat_stale"}
EOF
        fi
        
        # Send response using netcat
        cat "$response" | nc -l -p "$health_port" -q 1 2>/dev/null || true
        rm -f "$response"
    done
}

# Start health endpoint in background
start_health_endpoint &
HEALTH_ENDPOINT_PID=$!
echo "[$(date -u +%H:%M:%S)] HTTP health endpoint started (PID: $HEALTH_ENDPOINT_PID)"

# Create health check files for Kubernetes probes (issue #619)
# Note: These are legacy - we now have HTTP endpoint, but keep for backward compatibility
touch /tmp/coordinator-alive
touch /tmp/coordinator-ready
echo "[$(date -u +%H:%M:%S)] Health check files initialized"

# Run immediate cleanup at startup to clear accumulated stale CRs (issue #1679)
# After a coordinator restart (e.g., after merging new cleanup code), stale Thought/Message/Report
# CRs may have accumulated during high-activity periods. Without startup cleanup, agents spend
# ~30 minutes with degraded kubectl performance (listing 5000+ CRs each operation).
# This one-time call at startup ensures the cluster is clean before the main loop begins.
echo "[$(date -u +%H:%M:%S)] Running startup cleanup to clear accumulated stale CRs (issue #1679)..."
cleanup_old_cluster_resources
echo "[$(date -u +%H:%M:%S)] Startup cleanup complete — entering main loop"

iteration=0
while true; do
    iteration=$((iteration + 1))

    # Update liveness probe file (issue #619)
    touch /tmp/coordinator-alive
    
    heartbeat

    # Every 5 iterations (~2.5 min): refresh task queue from GitHub
    if [ $((iteration % 5)) -eq 0 ]; then
        refresh_task_queue
    fi

    # Every iteration: cleanup stale assignments
    cleanup_stale_assignments

    # Every 4 iterations (~2 min): cleanup stale activeAgents entries (issue #676)
    # Agents register on startup but never deregister, causing activeAgents to accumulate
    if [ $((iteration % 4)) -eq 0 ]; then
        cleanup_active_agents
    fi

    # ADAPTIVE SPAWN SLOT RECONCILIATION (issue #669, #1240)
    # When system is near capacity, reconcile every cycle (~30s) to prevent proliferation bursts.
    # When idle, reconcile every 4 iterations (~2 min) to reduce overhead.
    # Issue #1240: ALSO reconcile IMMEDIATELY if spawnSlots is negative (civilization frozen guard).
    # This prevents the 2-minute reconciliation gap from allowing excess agents at capacity.
    
    # Read current circuit breaker limit
    # Issue #1001: Fallback to 6 (current constitution value), NOT 12.
    cb_limit=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "6")
    if ! [[ "$cb_limit" =~ ^[0-9]+$ ]]; then cb_limit=6; fi

    # Issue #1240: Fast-path negative spawnSlots check — every iteration (~30s).
    # If spawnSlots is negative or non-numeric, it permanently blocks all spawning
    # until a human patches the ConfigMap. Catch and reconcile immediately — do NOT
    # wait for the 4-iteration (2 min) reconcile cycle.
    spawn_slots_now=$(get_state "spawnSlots")
    if [ -z "$spawn_slots_now" ] || ! [[ "$spawn_slots_now" =~ ^[0-9]+$ ]]; then
        echo "[$(date -u +%H:%M:%S)] ALERT: spawnSlots='$spawn_slots_now' is invalid (negative or non-numeric) — reconciling immediately (issue #1240)"
        push_metric "SpawnSlotsNegative" 1 "Count" "Component=Coordinator"
        reconcile_spawn_slots
    else
        # Count active jobs (fast check, only when needed)
        current_active=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
            jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
            2>/dev/null || echo "0")
        
        # Near capacity threshold: reconcile if within 3 slots of limit
        near_capacity_threshold=$((cb_limit - 3))
        
        if [ "$current_active" -ge "$near_capacity_threshold" ]; then
            # NEAR CAPACITY: reconcile every iteration (~30s) to prevent overshoot
            reconcile_spawn_slots
        elif [ $((iteration % 4)) -eq 0 ]; then
            # IDLE: reconcile every 4 iterations (~2 min) as before
            reconcile_spawn_slots
        fi
    fi

    # Every 3 iterations (~1.5 min): tally votes and potentially enact
    if [ $((iteration % 3)) -eq 0 ]; then
        tally_and_enact_votes
    fi

    # Every 6 iterations (~3 min): track debate activity and nudge if needed
    if [ $((iteration % 6)) -eq 0 ]; then
        track_debate_activity
    fi

    # Every 7 iterations (~3.5 min): run identity-based task routing (issue #1113)
    # Scores active agents' specializations against pending tasks and surfaces
    # routing recommendations for the planner/god-delegate to act on.
    if [ $((iteration % 7)) -eq 0 ]; then
        route_tasks_by_specialization
    fi

    # Every 15 iterations (~7.5 min): check for role promotion opportunities (issue #1733)
    # Scans active agents' S3 identities for promotion criteria:
    #   - 3 consecutive visionScores >= 8, OR 5+ tasks in one domain
    # Promotes eligible agents to {role}:{specialization}-specialist.
    if [ $((iteration % 15)) -eq 0 ]; then
        promote_agent_role
    fi

    # Every 20 iterations (~10 min): check v0.5 milestone completion (issue #1752)
    # Evaluates all 5 Emergent Specialization success criteria from issue #1732.
    # When all criteria pass, posts a milestone completion Thought CR and files a GitHub issue.
    # No-ops after v05MilestoneStatus = "completed" is set.
    if [ $((iteration % 20)) -eq 0 ]; then
        check_v05_milestone
    fi

    # Every 20 iterations (~10 min): check v0.6 milestone completion (issue #1789)
    # Evaluates all 4 Collective Action success criteria from issue #1771.
    # When all criteria pass, posts a milestone completion Thought CR and files a GitHub issue.
    # No-ops after v06MilestoneStatus = "completed" is set.
    if [ $((iteration % 20)) -eq 0 ]; then
        check_v06_milestone
    fi

    # Every 10 iterations (~5 min): re-check and initialize any missing state fields (issue #1178)
    # The coordinator runs continuously for days/weeks. When new code deploys and adds
    # new state fields (e.g. specializedAssignments, unresolvedDebates), those fields are
    # only initialized at coordinator startup. This periodic call ensures newly-added fields
    # are lazily initialized even in long-running coordinators without requiring a restart.
    if [ $((iteration % 10)) -eq 0 ]; then
        ensure_state_fields_initialized "true"
    fi

    # Every 10 iterations (~5 min): cleanup orphaned terminal pods (issue #1416)
    # Deletes Failed/Succeeded pods with no ownerReferences that accumulate when Jobs
    # are deleted without cascade-deleting their pods (historical behavior pre-TTL governance).
    if [ $((iteration % 10)) -eq 0 ]; then
        cleanup_orphaned_pods
    fi

    # Every 10 iterations (~5 min): check for idle swarms that should be disbanded (issue #1787)
    # The entrypoint.sh dissolution check only runs when an agent with SWARM_REF exits.
    # Swarms where all tasks are done but no agent is running get stuck in Active/Forming.
    # This coordinator-driven check ensures timely cleanup regardless of agent state.
    if [ $((iteration % 10)) -eq 0 ]; then
        check_swarm_dissolution
    fi

    # Every 5 iterations (~2.5 min): update activeSwarms field with live swarm summary (issue #1775)
    # Tracks which swarms are active and their goal/member-count for v0.6 observability.
    # Runs more frequently than dissolution check (10 iters) to ensure prompt updates on formation.
    if [ $((iteration % 5)) -eq 0 ]; then
        track_active_swarms
    fi

    # NOTE (issue #867): Planner-chain liveness check removed.
    # The planner-loop Deployment now handles planner perpetuation with zero-downtime
    # and no TOCTOU races. Coordinator no longer needs to spawn recovery planners.

    # Every 60 iterations (~30 min): cleanup old Thought/Message/Report CRs (issue #1617)
    # Supplements planner-initiated cleanup. The cluster accumulates 4000+ Thoughts and
    # 1600+ Reports when planner cleanup alone isn't frequent enough.
    # 30-min cadence bounds coordinator blocking time (listing 4000 CRs takes ~10s each).
    if [ $((iteration % 60)) -eq 0 ]; then
        cleanup_old_cluster_resources
    fi

    # Every 20 iterations (~10 min): verify gh CLI is still authenticated (issue #1447)
    # GitHub GraphQL rate limits can expire and cause auth failures mid-run.
    # Periodic re-auth ensures the coordinator recovers without a pod restart.
    # Issue #1576: Use REST API check (gh api /user) instead of gh auth status (GraphQL).
    # gh auth status uses GraphQL which is rate-limited separately from REST API.
    # When GraphQL is exhausted, gh auth status fails even if REST API is functional,
    # causing false "auth check FAILED" logs and unnecessary re-auth attempts.
    if [ $((iteration % 20)) -eq 0 ]; then
        if ! gh api /user &>/dev/null 2>&1; then
            echo "[$(date -u +%H:%M:%S)] gh CLI REST auth check FAILED — attempting re-authentication (issue #1447, #1576)"
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                export GH_TOKEN="$GITHUB_TOKEN"
                gh_auth_with_retry "$GITHUB_TOKEN" || \
                    echo "[$(date -u +%H:%M:%S)] WARNING: gh re-authentication failed — gh commands may not work until next retry"
            fi
        fi
    fi

    sleep "$HEARTBEAT_INTERVAL"
done
