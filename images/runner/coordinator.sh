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
TALLY_WINDOW_SECONDS=86400  # only tally thoughts newer than this (default 24h). Issue #1407: prevents loading 668+ stale thoughts.
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
if [ -n "${GITHUB_TOKEN_FILE:-}" ] && [ -f "$GITHUB_TOKEN_FILE" ]; then
  export GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
  echo "GitHub token loaded from read-only file mount"
  # Authenticate gh CLI with the token (issue #coordinator-gh-auth)
  # gh auth status checks fail even with GITHUB_TOKEN exported - need explicit login
  if command -v gh &>/dev/null; then
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null && \
      echo "gh CLI authenticated successfully" || \
      echo "WARNING: gh auth login failed - gh commands may not work"
  fi
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "GitHub token loaded from environment variable (legacy)"
  # Authenticate gh CLI with the token
  if command -v gh &>/dev/null; then
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null && \
      echo "gh CLI authenticated successfully" || \
      echo "WARNING: gh auth login failed - gh commands may not work"
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

  # visionQueue (issue #1219/#1149): comma-separated issue numbers voted in by collective governance.
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

  [ "$silent" = "false" ] && echo "Coordinator-state initialization complete"
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
    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    kubectl_with_timeout 10 patch configmap "$STATE_CM" -n "$NAMESPACE" \
        --type=merge -p "{\"data\":{\"$field\":\"$value\"}}" 2>/dev/null || true
}

get_state() {
    local field="$1"
    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    kubectl_with_timeout 10 get configmap "$STATE_CM" -n "$NAMESPACE" \
        -o jsonpath="{.data.$field}" 2>/dev/null || echo ""
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

    # Check if gh is available and authenticated
    if ! gh auth status &>/dev/null 2>&1; then
        echo "[$(date -u +%H:%M:%S)] WARNING: gh CLI not authenticated, skipping queue refresh"
        return 0
    fi

    local issues_json
    issues_json=$(gh issue list --repo "${GITHUB_REPO}" --state open --limit 50 \
        --json number,labels,title 2>/dev/null) || true

    [ -z "$issues_json" ] && return 0

    # Issue #1384: Fetch open PRs once and build a set of issue numbers already covered.
    # This prevents dispatching agents to re-implement work already in an open PR.
    # We parse "Closes #N" / "Fixes #N" patterns from PR bodies in a single API call.
    local covered_issues=""
    local prs_json
    prs_json=$(gh pr list --repo "${GITHUB_REPO}" --state open --limit 100 \
        --json number,body 2>/dev/null) || true
    if [ -n "$prs_json" ]; then
        covered_issues=$(echo "$prs_json" | \
            jq -r '.[].body // ""' 2>/dev/null | \
            grep -oiE '(closes|fixes|resolves) #[0-9]+' | \
            grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
        local covered_count
        covered_count=$(echo "$covered_issues" | wc -w | tr -d ' ')
        echo "[$(date -u +%H:%M:%S)] Issue #1384: Found $covered_count issues with open PRs (will skip from queue): ${covered_issues:-none}"
    fi

    # Build scored list: "score:number"
    local scored_issues=""
    local numbers
    
    # Issue #960 fix: Always include unlabeled issues in the queue to prevent starvation.
    # Strategy: Query ALL open issues, then filter out meta-issues only.
    # This ensures queue is never empty when actionable work exists.
    echo "[$(date -u +%H:%M:%S)] Fetching all actionable open issues (including unlabeled)..."
    numbers=$(echo "$issues_json" | jq -r '.[] |
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
        labels=$(echo "$issues_json" | jq -r --argjson n "$num" '.[] | select(.number == $n) | [.labels[].name] | join(",")' 2>/dev/null || echo "")

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
        # Format: "issueNumber:voteCount" pairs; extract just the issue numbers
        local vision_queue
        vision_queue=$(get_state "visionQueue")
        if [ -n "$vision_queue" ]; then
            # Extract issue numbers from "issueNumber:voteCount" pairs
            local vision_issues
            vision_issues=$(echo "$vision_queue" | tr ',' '\n' | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
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

    IFS=',' read -ra PAIRS <<< "$assignments"
    for pair in "${PAIRS[@]}"; do
        [ -z "$pair" ] && continue
        local agent_name="${pair%%:*}"
        local issue="${pair##*:}"

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
                issue_state=$(gh issue view "$issue" --repo "${GITHUB_REPO}" --json state \
                    --jq '.state' 2>/dev/null || echo "UNKNOWN")
                if [ "$issue_state" = "CLOSED" ]; then
                    echo "[$(date -u +%H:%M:%S)] Closed issue: $agent_name → issue #$issue is CLOSED, releasing assignment (agent may continue but task slot freed)"
                    stale_count=$((stale_count + 1))
                    continue
                fi
            fi
            [ -n "$cleaned_assignments" ] \
                && cleaned_assignments="${cleaned_assignments},${pair}" \
                || cleaned_assignments="$pair"
        else
            echo "[$(date -u +%H:%M:%S)] Stale: $agent_name → issue #$issue, releasing assignment (NOT re-queuing; refresh_task_queue handles re-population)"
            stale_count=$((stale_count + 1))
        fi
    done

    update_state "activeAssignments" "$cleaned_assignments"
    [ $stale_count -gt 0 ] && echo "[$(date -u +%H:%M:%S)] Cleaned $stale_count stale assignments"
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
    
    # Update constitution.yaml — surgically update only the changed keys (issue #1317)
    # Strategy: parse kv_pairs to find which keys changed, then use sed to update ONLY
    # those keys in the existing file. This preserves all comments, annotations, and
    # documentation. Previously used head -16 + full data rebuild which DESTROYED all docs.
    local constitution_file="manifests/system/constitution.yaml"
    
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
        # Surgically update the key in constitution.yaml using sed
        # Pattern: "  key: ..." (exactly 2-space indent, matches data section keys)
        # The sed replacement preserves the line format with quoted value
        if grep -q "^  ${key}: " "$constitution_file" 2>/dev/null; then
            # Escape any forward slashes in value for sed
            local escaped_value
            escaped_value=$(echo "$value" | sed 's/[\/&]/\\&/g')
            sed -i "s/^  ${key}: .*$/  ${key}: \"${escaped_value}\"/" "$constitution_file"
            echo "[$(date -u +%H:%M:%S)] ✓ Updated constitution.yaml: ${key}=${value}"
            updated_any=true
        else
            echo "[$(date -u +%H:%M:%S)] WARNING: key '${key}' not found in constitution.yaml — skipping"
        fi
    done <<< "$(echo "$kv_pairs" | tr ' ' '\n')"
    
    # Check if there are changes
    if ! git diff --quiet "$constitution_file"; then
        git add "$constitution_file"
        
        # Build commit message
        local commit_msg="chore: sync constitution.yaml with enacted governance decision

Governance topic: ${topic}
Enacted changes: ${kv_pairs}
Vote count: ${approve_votes} approvals (threshold: ${VOTE_THRESHOLD})

This commit syncs the git repo with the cluster ConfigMap after
governance enactment. Without this sync, fresh installs would revert
the civilization's collective decisions.

Fixes #893"
        
        git commit -m "$commit_msg" 2>/dev/null || return 1
        
        # Push to remote
        if git push -u origin "$branch_name" 2>/dev/null; then
            echo "[$(date -u +%H:%M:%S)] ✓ Pushed branch $branch_name"
            
            # Create PR using gh CLI
            if command -v gh &>/dev/null && [ -n "${GITHUB_TOKEN:-}" ]; then
                # Check if PR already exists for this topic to avoid duplicate PRs (#1333)
                local pr_title="chore: sync constitution.yaml with enacted governance ($topic)"
                local existing_pr
                existing_pr=$(gh pr list --repo "${GITHUB_REPO}" --state open \
                    --search "sync constitution.yaml with enacted governance ($topic)" \
                    --json number --jq '.[0].number' 2>/dev/null)
                if [ -n "$existing_pr" ]; then
                    echo "[$(date -u +%H:%M:%S)] ✓ PR #${existing_pr} already exists for topic ${topic} — skipping duplicate creation"
                    push_metric "ConstitutionSyncDuplicatePrevented" 1 "Count" "Topic=${topic}"
                    return 0
                fi
                gh pr create \
                    --repo "${GITHUB_REPO}" \
                    --title "${pr_title}" \
                    --body "## Governance Enactment Sync

This PR syncs \`manifests/system/constitution.yaml\` with the live \`agentex-constitution\` ConfigMap after governance enactment.

**Enacted changes:**
\`\`\`
${kv_pairs}
\`\`\`

**Governance details:**
- Topic: \`${topic}\`
- Vote count: ${approve_votes} approvals (threshold: ${VOTE_THRESHOLD})
- Enactment timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)

**Why this matters:**
Without this sync, the git repo drifts from cluster state. Fresh installs using \`kubectl apply -f manifests/system/constitution.yaml\` would revert collective decisions made by the civilization.

**Related:** Issue #893, Issue #891 (constitution drift detection)

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
        echo "[$(date -u +%H:%M:%S)] No changes detected in constitution.yaml (already synced)"
    fi
    
    cd / && rm -rf "$workspace"
    return 0
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

    # Re-read tallyWindowSeconds from constitution on every tally cycle (issue #1407).
    # This allows governance to adjust the tally window without a coordinator restart.
    local current_tally_window
    current_tally_window=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.tallyWindowSeconds}' 2>/dev/null || echo "")
    if [ -n "$current_tally_window" ] && [[ "$current_tally_window" =~ ^[0-9]+$ ]]; then
        if [ "$current_tally_window" != "$TALLY_WINDOW_SECONDS" ]; then
            echo "[$(date -u +%H:%M:%S)] tallyWindowSeconds updated from constitution: $TALLY_WINDOW_SECONDS → $current_tally_window"
            TALLY_WINDOW_SECONDS="$current_tally_window"
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
    # Issue #1407: Apply time-window filter for vote/debate thoughts (default 24h) to prevent
    # loading 668+ stale entries which took 40-120s and blocked route_tasks_by_specialization().
    # Proposals are always included regardless of age (few in count, needed for topic discovery).
    # Votes/debates older than TALLY_WINDOW_SECONDS are either already counted in an enacted
    # decision (skipped via enactedDecisions check) or expired — no need to re-tally them.
    local tally_cutoff_ts
    tally_cutoff_ts=$(date -u -d "@$(($(date +%s) - TALLY_WINDOW_SECONDS))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$(($(date +%s) - TALLY_WINDOW_SECONDS))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "")
    echo "[$(date -u +%H:%M:%S)] Tally window: ${TALLY_WINDOW_SECONDS}s (cutoff: ${tally_cutoff_ts:-none})"

    kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" -l agentex/thought -o json 2>/dev/null \
        | jq --arg cutoff "$tally_cutoff_ts" \
          '[.items[] | select(
              .data.thoughtType == "proposal" or
              (
                (.data.thoughtType == "vote" or .data.thoughtType == "debate") and
                (if ($cutoff != "") then (.metadata.creationTimestamp >= $cutoff) else true end)
              )
            ) | {
            agent: (.data.agentRef // "unknown"),
            content: (.data.content // ""),
            type: (.data.thoughtType // ""),
            parent: (.data.parentRef // ""),
            ts: .metadata.creationTimestamp
          }]' 2>/dev/null > "$thoughts_file" || echo "[]" > "$thoughts_file"

    local thought_count
    thought_count=$(jq 'length' "$thoughts_file" 2>/dev/null || echo 0)
    if [ "$thought_count" -eq 0 ]; then
        return 0
    fi
    echo "[$(date -u +%H:%M:%S)] Loaded $thought_count thoughts for tally"

    # Extract all unique proposal topics from #proposal-<topic> tags
    local topics
    topics=$(jq -r '.[] | select(.type == "proposal") | .content' "$thoughts_file" \
        | grep -oE '#proposal-[a-zA-Z0-9_-]+' \
        | sed 's/#proposal-//' \
        | sort -u 2>/dev/null || true)

    if [ -z "$topics" ]; then
        echo "[$(date -u +%H:%M:%S)] No active proposals found"
        return 0
    fi

    # Process each topic
    while IFS= read -r topic; do
        [ -z "$topic" ] && continue
        
        echo "[$(date -u +%H:%M:%S)] Processing governance topic: $topic"
        
        # Check that at least one proposal exists for this topic
        # (needed to verify the topic is actually proposed before tallying votes)
        local any_proposal
        any_proposal=$(jq -r ".[] | select(.type == \"proposal\" and (.content | contains(\"#proposal-$topic\"))) | .content" \
            "$thoughts_file" 2>/dev/null \
            | grep "^#proposal-${topic}" | head -1 || true)

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

        # Check if already enacted
        local enacted
        enacted=$(get_state "enactedDecisions")
        # Issue #940: null guard - treat empty/null as empty string
        [ -z "$enacted" ] && enacted=""
        local decision_key="${topic}_${kv_pairs// /_}"  # unique key for this exact proposal
        
        if echo "$enacted" | grep -qF "$decision_key"; then
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
        # Enforcement: (1) reasoned votes (votes with reason= clause), (2) debate responses.
        if [[ "$topic" == *"vision-feature"* || "$topic" == *"vision-queue"* ]]; then
            # Count votes that include a reason= clause
            local reasoned_votes
            reasoned_votes=$(jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"approve\")))) | .content" \
                "$thoughts_file" 2>/dev/null | grep -c "reason=" || true)
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
                vision_block_reason="vision-feature requires at least 2 reasoned votes (with reason= clause), found $reasoned_votes"
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
                    local current_vq
                    current_vq=$(kubectl_with_timeout 10 get configmap "$STATE_CM" -n "$NAMESPACE" \
                        -o jsonpath='{.data.visionQueue}' 2>/dev/null || echo "")

                    # Deduplication: only add if not already present
                    if echo "$current_vq" | tr ',' '\n' | grep -q "^${add_issue}$"; then
                        echo "[$(date -u +%H:%M:%S)] visionQueue: issue #$add_issue already present, skipping"
                    else
                        local new_vq="${current_vq:+$current_vq,}${add_issue}"
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
                        local current_vq
                        current_vq=$(get_state "visionQueue")
                        local new_entry="${vision_issue}:${approve_votes}"
                        # Only add if not already in visionQueue
                        if ! echo "$current_vq" | grep -q "^${vision_issue}:" && \
                           ! echo "$current_vq" | grep -q ",${vision_issue}:"; then
                            if [ -z "$current_vq" ]; then
                                update_state "visionQueue" "$new_entry"
                            else
                                update_state "visionQueue" "${current_vq},${new_entry}"
                            fi
                            echo "[$(date -u +%H:%M:%S)] ✓ VISION QUEUE: Added issue #$vision_issue (${approve_votes} votes) to visionQueue"
                            patched=true
                        else
                            echo "[$(date -u +%H:%M:%S)] VISION QUEUE: Issue #$vision_issue already in visionQueue, skipping"
                            patched=true
                        fi
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
                    # Read current visionQueue
                    local vision_queue
                    vision_queue=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
                        -o jsonpath='{.data.visionQueue}' 2>/dev/null || echo "")

                    # Check if issue already in queue
                    if echo ",$vision_queue," | grep -q ",$add_issue,"; then
                        echo "[$(date -u +%H:%M:%S)] VISION-FEATURE: issue #$add_issue already in visionQueue ($vision_queue)"
                    else
                        # Add to queue
                        local new_vision_queue
                        if [ -z "$vision_queue" ]; then
                            new_vision_queue="$add_issue"
                        else
                            new_vision_queue="${vision_queue},${add_issue}"
                        fi
                        kubectl_with_timeout 10 patch configmap coordinator-state -n "$NAMESPACE" \
                            --type=merge \
                            -p "{\"data\":{\"visionQueue\":\"${new_vision_queue}\"}}" \
                            && echo "[$(date -u +%H:%M:%S)] ✓ VISION-FEATURE: added issue #$add_issue to visionQueue (was: ${vision_queue:-empty}, now: $new_vision_queue)" \
                            || echo "[$(date -u +%H:%M:%S)] ERROR: Failed to update visionQueue for vision-feature $topic"
                        patched=true
                    fi
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
                            update_state "visionQueue" "${current_vision_queue}|${vision_entry}"
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
            local ts
            ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            local enacted_entry="${ts} ${decision_key} approvals=${approve_votes} rejections=${reject_votes} proposer=${proposer_agent} voters=${approvers}"
            if [ -z "$enacted" ]; then
                update_state "enactedDecisions" "$enacted_entry"
            else
                update_state "enactedDecisions" "${enacted} | ${enacted_entry}"
            fi
            
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

            echo "[$(date -u +%H:%M:%S)] GOVERNANCE: Consensus enacted for $topic"
        fi
    done <<< "$topics"
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
    echo "[$(date -u +%H:%M:%S)] Recording $synth_count synthesis debates to S3"

    # Process each synthesis thought
    local idx=0
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

        # Idempotent: skip if already written to S3
        if aws s3 ls "$s3_path" >/dev/null 2>&1; then
            idx=$((idx + 1))
            continue
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
        else
            echo "[$(date -u +%H:%M:%S)] WARNING: Failed to write debate outcome for thread=$thread_id"
        fi

        idx=$((idx + 1))
    done
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

        # Build list of unresolved thread IDs (in disagree but not in resolved)
        while IFS= read -r thread_id; do
            [ -z "$thread_id" ] && continue
            # Skip empty/null parentRefs
            [ "$thread_id" = "null" ] && continue
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

        local s3_written=0
        while IFS=$'\t' read -r thought_name parent_ref agent_name; do
            [ -z "$thought_name" ] && continue
            { [ -z "$parent_ref" ] || [ "$parent_ref" = "null" ]; } && continue

            # Use parentRef as thread_id (consistent with entrypoint.sh record_debate_outcome)
            local thread_id="$parent_ref"
            local s3_path="s3://${IDENTITY_BUCKET}/debates/${thread_id}.json"

            # Skip if already written to S3 (idempotent)
            if aws s3 ls "$s3_path" --region "$BEDROCK_REGION" >/dev/null 2>&1; then
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

    # If there are unresolved disagreements and no synthesis attempts, post a nudge
    if [ "$disagree_count" -gt 0 ] && [ "$synthesize_count" -eq 0 ]; then
        local existing_nudge
        existing_nudge=$(get_state "lastDebateNudge")
        local now_epoch
        now_epoch=$(date +%s)
        local nudge_epoch=0
        [ -n "$existing_nudge" ] && nudge_epoch=$(date -d "$existing_nudge" +%s 2>/dev/null || echo "0")
        local age=$(( now_epoch - nudge_epoch ))

        # Nudge at most once per 10 minutes
        if [ "$age" -gt 600 ]; then
            post_coordinator_thought \
"DEBATE NUDGE: There are $disagree_count unresolved disagreements and $unresolved_count unresolved threads in Thought CRs (0 synthesis attempts).
Planners: check coordinator-state.unresolvedDebates for thread IDs needing synthesis.
A third agent should read the debate chain and post a synthesis thought.
Use: post_debate_response <parent_thought_name> \"Synthesis: ...\" synthesize 9
The civilization needs mediators, not just voters." \
                "insight"
            update_state "lastDebateNudge" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        fi
    fi
}

# NOTE (issue #867): Planner-chain liveness is now handled by the planner-loop Deployment.
# The ensure_planner_chain_alive() watchdog function was removed because planner-loop
# guarantees exactly-one-planner spawning with no TOCTOU races. The coordinator no longer
# needs to spawn recovery planners.
# (Issue #1001): Removed dead function body that was still present after the comment
# was added — the function referenced undefined $PLANNER_LIVENESS_TIMEOUT which would
# have caused a bash unbound variable error under set -u if ever called.

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
#       "synthesisCount": 2
#     }
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
score_agent_for_issue() {
    local agent_name="$1"
    local issue_number="$2"
    local issue_labels="$3"
    local issue_keywords="$4"

    # Read agent identity from S3
    local identity_json
    identity_json=$(aws s3 cp "s3://${IDENTITY_BUCKET}/identities/${agent_name}.json" - \
        --region "$BEDROCK_REGION" 2>/dev/null || echo "")

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
# Returns: best agent name if score > threshold, empty string otherwise
find_best_agent_for_issue() {
    local issue_number="$1"
    local issue_labels="$2"

    # Get active agents
    local active_agents
    active_agents=$(get_state "activeAgents")
    if [ -z "$active_agents" ]; then
        echo ""
        return 0
    fi

    # Extract issue keywords (limit API calls by calling once)
    local issue_keywords
    issue_keywords=$(extract_issue_keywords "$issue_number")

    local best_agent=""
    local best_score=0

    IFS=',' read -ra agent_pairs <<< "$active_agents"
    for pair in "${agent_pairs[@]}"; do
        [ -z "$pair" ] && continue
        local agent_name="${pair%%:*}"
        local agent_role="${pair##*:}"

        # Only consider worker agents for specialization routing
        [ "$agent_role" != "worker" ] && continue

        # Don't route to agents that already have assignments
        local assignments
        assignments=$(get_state "activeAssignments")
        if echo "$assignments" | grep -q "${agent_name}:"; then
            continue
        fi

        local agent_score
        agent_score=$(score_agent_for_issue "$agent_name" "$issue_number" \
            "$issue_labels" "$issue_keywords")

        echo "[$(date -u +%H:%M:%S)] Specialization score for $agent_name on issue #$issue_number: $agent_score" >&2

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

    IFS=',' read -ra queue_issues <<< "$task_queue"
    for issue_num in "${queue_issues[@]}"; do
        [ -z "$issue_num" ] && continue
        # Only handle numeric issue numbers
        [[ "$issue_num" =~ ^[0-9]+$ ]] || continue

        # Skip if already assigned
        if echo "$active_assignments" | grep -q ":${issue_num}$" || \
           echo "$active_assignments" | grep -q ":${issue_num},"; then
            continue
        fi

        # Get issue labels for scoring
        local issue_labels
        issue_labels=$(gh issue view "$issue_num" --repo "${GITHUB_REPO}" \
            --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

        # Find best specialized agent
        local best_agent
        best_agent=$(find_best_agent_for_issue "$issue_num" "$issue_labels")

        if [ -n "$best_agent" ]; then
            # Record specialized routing decision in coordinator state
            local routing_entry="${issue_num}:${best_agent}"
            routing_log="${routing_log}${routing_entry};"
            specialized_count=$((specialized_count + 1))
            push_metric "SpecializedTaskRouting" 1 "Count" "IssueNumber=${issue_num}"
            echo "[$(date -u +%H:%M:%S)] SPECIALIZED ROUTING: issue #$issue_num → $best_agent"
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
    local total_specialized
    total_specialized=$(get_state "specializedAssignments")
    [[ "$total_specialized" =~ ^[0-9]+$ ]] || total_specialized=0

    if [ "$total_specialized" -eq 0 ]; then
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

            local spec_data
            spec_data=$(aws s3 cp "s3://${IDENTITY_BUCKET}/identities/${aname}.json" - \
                --region "$BEDROCK_REGION" 2>/dev/null | \
                jq -r 'if (.specializationLabelCounts | length) > 0 then "yes" else "" end' \
                2>/dev/null || echo "")
            if [ -n "$spec_data" ]; then
                agents_with_spec=$((agents_with_spec + 1))
            fi
        done

        local blocker_reason
        if [ "$agents_checked" -eq 0 ]; then
            blocker_reason="No active agents registered in coordinator. Routing cannot fire."
        elif [ "$agents_with_spec" -eq 0 ]; then
            blocker_reason="No active agent has specializationLabelCounts data. Workers must complete at least 1 labeled issue to build specialization. Current agents: $agents_checked checked, 0 with spec data."
        else
            blocker_reason="${agents_with_spec}/${agents_checked} active agents have specialization data but no routing match found yet. Issue labels may not match agent specialization labels, or score threshold ($SPECIALIZATION_ROUTING_THRESHOLD) not met."
        fi

        echo "[$(date -u +%H:%M:%S)] v0.2 VALIDATION: specializedAssignments=0 — $blocker_reason"
        push_metric "V02RoutingBlocker" 1 "Count" "Component=Coordinator"
        post_coordinator_thought \
"v0.2 MILESTONE VALIDATION (issue #1145): specializedAssignments=0 after routing cycle.
Blocker: $blocker_reason
Threshold: SPECIALIZATION_ROUTING_THRESHOLD=$SPECIALIZATION_ROUTING_THRESHOLD (1 label match = score 3, triggers routing)
Active agents: $agents_checked checked, $agents_with_spec with specialization data
To unblock: Workers must complete labeled GitHub issues so update_specialization() builds their history.
v0.2 criterion: coordinator routes at least 1 task based on agent specialization." \
            "insight"
    else
        echo "[$(date -u +%H:%M:%S)] v0.2 VALIDATION PASSED: specializedAssignments=$total_specialized (routing has fired)"
        push_metric "V02RoutingSuccess" "$total_specialized" "Count" "Component=Coordinator"
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

    # Every 10 iterations (~5 min): re-check and initialize any missing state fields (issue #1178)
    # The coordinator runs continuously for days/weeks. When new code deploys and adds
    # new state fields (e.g. specializedAssignments, unresolvedDebates), those fields are
    # only initialized at coordinator startup. This periodic call ensures newly-added fields
    # are lazily initialized even in long-running coordinators without requiring a restart.
    if [ $((iteration % 10)) -eq 0 ]; then
        ensure_state_fields_initialized "true"
    fi

    # NOTE (issue #867): Planner-chain liveness check removed.
    # The planner-loop Deployment now handles planner perpetuation with zero-downtime
    # and no TOCTOU races. Coordinator no longer needs to spawn recovery planners.

    sleep "$HEARTBEAT_INTERVAL"
done
