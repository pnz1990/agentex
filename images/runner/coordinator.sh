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

echo "═══════════════════════════════════════════════════════════════════════════"
echo "COORDINATOR STARTING"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Namespace: $NAMESPACE"
echo "State ConfigMap: $STATE_CM"
echo "Vote threshold: $VOTE_THRESHOLD approvals required"
echo ""

# ── Configure kubectl ────────────────────────────────────────────────────────
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    kubectl config set-cluster local --server=https://kubernetes.default.svc --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    kubectl config set-credentials sa --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    kubectl config set-context local --cluster=local --user=sa --namespace="$NAMESPACE"
    kubectl config use-context local
fi

# ── Configure GitHub Authentication (issue #6) ───────────────────────────────
# Read GitHub token from read-only file mount instead of environment variable
if [ -n "${GITHUB_TOKEN_FILE:-}" ] && [ -f "$GITHUB_TOKEN_FILE" ]; then
  export GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
  echo "GitHub token loaded from read-only file mount"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "GitHub token loaded from environment variable (legacy)"
else
  echo "WARNING: No GitHub token available - gh CLI commands will fail"
fi

# ── Initialize coordinator-state fields (issue #940) ─────────────────────────
# After coordinator restart, some fields may be missing or null. Initialize them
# to prevent jq parse errors and governance tally loop crashes.
echo "Initializing coordinator-state fields..."
for field in activeAgents activeAssignments decisionLog; do
  val=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath="{.data.$field}" 2>/dev/null)
  if [ -z "$val" ]; then
    echo "  Initializing $field (was empty/null)"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
      -p "{\"data\":{\"$field\":\"\"}}" 2>/dev/null || true
  fi
done

# debateStats needs a valid structured value (not just empty string)
debate_stats=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath='{.data.debateStats}' 2>/dev/null)
if [ -z "$debate_stats" ]; then
  echo "  Initializing debateStats (was empty/null)"
  kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
    -p '{"data":{"debateStats":"responses=0 threads=0 disagree=0 synthesize=0"}}' 2>/dev/null || true
fi

# enactedDecisions needs preservation if exists, initialization if not
enacted=$(kubectl get configmap "$STATE_CM" -n "$NAMESPACE" -o jsonpath='{.data.enactedDecisions}' 2>/dev/null)
if [ -z "$enacted" ]; then
  echo "  Initializing enactedDecisions (was empty/null)"
  kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" --type=merge \
    -p '{"data":{"enactedDecisions":""}}' 2>/dev/null || true
fi
echo "Coordinator-state initialization complete"

# ── Helper Functions ─────────────────────────────────────────────────────────

# kubectl timeout wrapper (issue #692: prevent 120s hangs during cluster connectivity issues)
# Coordinator is a long-running process that MUST NOT hang indefinitely on kubectl calls.
# Without this wrapper, kubectl uses 120s default timeout, blocking coordinator operations.
kubectl_with_timeout() {
  local timeout_secs="${1:-10}"
  shift
  timeout "${timeout_secs}s" kubectl "$@" 2>&1
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
    labels=$(gh issue view "$issue_number" --repo pnz1990/agentex \
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
    issues_json=$(gh issue list --repo pnz1990/agentex --state open --limit 50 \
        --json number,labels,title 2>/dev/null) || true

    [ -z "$issues_json" ] && return 0

    # Build scored list: "score:number"
    local scored_issues=""
    local numbers
    numbers=$(echo "$issues_json" | jq -r '.[] | select(.labels[] | .name == "enhancement" or .name == "bug") | .number' 2>/dev/null | head -20)

    for num in $numbers; do
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

        local current_queue
        current_queue=$(get_state "taskQueue")
        # Merge new issues with existing queue (deduplicate, preserve priority order)
        local merged_queue
        merged_queue=$(echo "${sorted_issues},${current_queue}" | tr ',' '\n' | grep -v '^$' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')

        update_state "taskQueue" "$merged_queue"
        echo "[$(date -u +%H:%M:%S)] Task queue (priority-sorted): $merged_queue"
    fi
}

# Check for stale assignments and return them to queue
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
        job_active=$(kubectl_with_timeout 10 get job "$agent_name" -n "$NAMESPACE" -o json 2>/dev/null \
            | jq -r 'if (.status.completionTime == null and (.status.active // 0) > 0) then "true" else "false" end' \
            || echo "false")

        if [ "$job_active" = "true" ]; then
            [ -n "$cleaned_assignments" ] \
                && cleaned_assignments="${cleaned_assignments},${pair}" \
                || cleaned_assignments="$pair"
        else
            echo "[$(date -u +%H:%M:%S)] Stale: $agent_name → issue #$issue, returning to queue"
            local current_queue
            current_queue=$(get_state "taskQueue")
            if [ -z "$current_queue" ]; then
                update_state "taskQueue" "$issue"
            else
                update_state "taskQueue" "${current_queue},${issue}"
            fi
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
        job_active=$(kubectl_with_timeout 10 get job "$agent_name" -n "$NAMESPACE" -o json 2>/dev/null \
            | jq -r 'if (.status.completionTime == null and (.status.active // 0) > 0) then "true" else "false" end' \
            || echo "false")
        
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
    limit=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "12")
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then limit=12; fi

    local active_jobs
    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    active_jobs=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
        2>/dev/null || echo "0")

    local correct_slots=$(( limit - active_jobs ))
    if [ "$correct_slots" -lt 0 ]; then correct_slots=0; fi

    local current_slots
    current_slots=$(get_state "spawnSlots")
    if [ -z "$current_slots" ] || ! [[ "$current_slots" =~ ^[0-9]+$ ]]; then
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
    
    # Clone repo
    if ! git clone "https://github.com/${GITHUB_REPO}" repo 2>/dev/null; then
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
    
    # Read current constitution ConfigMap from cluster
    local current_cm
    current_cm=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" -o json 2>/dev/null)
    if [ -z "$current_cm" ]; then
        echo "[$(date -u +%H:%M:%S)] ERROR: Could not read agentex-constitution ConfigMap"
        return 1
    fi
    
    # Update constitution.yaml data section to match cluster ConfigMap
    # Strategy: Extract .data from ConfigMap JSON and rebuild YAML file
    local constitution_file="manifests/system/constitution.yaml"
    
    # Preserve metadata section (lines 1-16) and rebuild data section from ConfigMap
    head -16 "$constitution_file" > "${constitution_file}.new"
    echo "data:" >> "${constitution_file}.new"
    
    # Extract each key=value from ConfigMap .data and format as YAML
    echo "$current_cm" | jq -r '.data | to_entries[] | 
        if (.value | contains("\n")) then
            "  \(.key): |\n    \(.value | gsub("\n"; "\n    "))"
        else
            "  \(.key): \"\(.value)\""
        end' >> "${constitution_file}.new"
    
    mv "${constitution_file}.new" "$constitution_file"
    
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
                gh pr create \
                    --repo "${GITHUB_REPO}" \
                    --title "chore: sync constitution.yaml with enacted governance ($topic)" \
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

    # Write thoughts to temp file. Read from ConfigMap .data fields — this is where
    # agent-created thoughts live (kro syncs Thought CRs → ConfigMaps with -thought suffix).
    # Do NOT use gsub or encoding transforms — raw .data.content is correct as-is.
    # Do NOT use thoughts.kro.run — that group only has ~4 god-created CRs, not agent thoughts.
    local thoughts_file
    thoughts_file=$(mktemp /tmp/agentex-thoughts-XXXXXX.json)
    trap "rm -f '$thoughts_file'" RETURN

    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" -o json 2>/dev/null \
        | jq '[.items[] | select(.metadata.name | endswith("-thought")) | {
            agent: (.data.agentRef // "unknown"),
            content: (.data.content // ""),
            type: (.data.thoughtType // ""),
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
        
        # Get most recent proposal for this topic
        local proposal_content
        proposal_content=$(jq -r ".[] | select(.type == \"proposal\" and (.content | contains(\"#proposal-$topic\"))) | .content" \
            "$thoughts_file" | tail -1 || true)
        
        [ -z "$proposal_content" ] && continue

        # Extract key=value pairs from proposal declaration line only (issue #754)
        # IMPORTANT: Only extract from first line to avoid picking up values from evidence/reasoning text
        # Example: "#proposal-circuit-breaker circuitBreakerLimit=12 reason=observed-load-at-limit-6"
        # Should extract "circuitBreakerLimit=12" and "reason=...", NOT "limit-6" from later lines
        local kv_pairs
        kv_pairs=$(echo "$proposal_content" | head -1 | grep -oE '[a-zA-Z0-9_]+=[a-zA-Z0-9_.-]+' || true)
        
        # Count unique approve/reject/abstain votes for this topic
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
        
        # Emit metrics
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

            # Try to patch constitution for known keys
            local patched=false
            if [ -n "$kv_pairs" ]; then
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

                if [ "$patched" = true ]; then
                    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
                    kubectl_with_timeout 10 patch configmap agentex-constitution -n "$NAMESPACE" \
                        --type=merge \
                        -p "{\"data\":${patch_data}}" \
                        && echo "[$(date -u +%H:%M:%S)] ✓ Constitution patched: $kv_pairs" \
                        || echo "[$(date -u +%H:%M:%S)] ERROR: Failed to patch constitution"
                    
                    # ISSUE #893: Sync constitution.yaml in git after enacting governance decision
                    # This prevents git repo from drifting out of sync with cluster ConfigMap
                    sync_constitution_to_git "$kv_pairs" "$topic" "$approve_votes"
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
            if [ "$patched" = true ]; then
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

# Track debate activity — count debate threads, surface unresolved disagreements
track_debate_activity() {
    local all_cm
    # Issue #687: Use kubectl_with_timeout to prevent 120s hangs during cluster connectivity issues
    all_cm=$(kubectl_with_timeout 10 get configmaps -n "$NAMESPACE" -o json 2>/dev/null \
        | jq '[.items[] | select(.metadata.name | endswith("-thought")) | {
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
    local disagree_count
    disagree_count=$(echo "$all_cm" | jq '[.[] | select(.type == "debate") | select(.content | test("disagree|DISAGREE"))] | length' 2>/dev/null || echo "0")
    local synthesize_count
    synthesize_count=$(echo "$all_cm" | jq '[.[] | select(.type == "debate") | select(.content | test("synthesize|SYNTHESIZE|Synthesis"))] | length' 2>/dev/null || echo "0")

    echo "[$(date -u +%H:%M:%S)] Debate stats: responses=$debate_count threads=$thread_count disagree=$disagree_count synthesize=$synthesize_count"

    update_state "debateStats" "responses=${debate_count} threads=${thread_count} disagree=${disagree_count} synthesize=${synthesize_count}"
    push_metric "DebateResponses" "$debate_count" "Count" "Component=Coordinator"
    push_metric "DebateThreads" "$thread_count" "Count" "Component=Coordinator"

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
"DEBATE NUDGE: There are $disagree_count unresolved disagreements in Thought CRs and 0 synthesis attempts.
A third agent should read the debate chain and post a synthesis thought.
Use: post_debate_response <parent_thought_name> \"Synthesis: ...\" synthesize 9
The civilization needs mediators, not just voters." \
                "insight"
            update_state "lastDebateNudge" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        fi
    fi
}

# NOTE (issue #867): Planner-chain liveness is now handled by the planner-loop Deployment.
# The ensure_planner_chain_alive() watchdog function has been removed because planner-loop
# guarantees exactly-one-planner spawning with no TOCTOU races. The coordinator no longer
# needs to spawn recovery planners.


ensure_planner_chain_alive() {
    # Issue #947: Guard against scheduling-lag false positives.
    # After spawning a recovery planner, the pod takes 20-90s to become active.
    # During that window active_planners=0 and the watchdog would double-spawn.
    # Solution: write pendingPlannerSpawn timestamp after every spawn and skip
    # the watchdog for PENDING_PLANNER_GRACE seconds after a recent spawn.
    local PENDING_PLANNER_GRACE=90
    local pending_spawn
    pending_spawn=$(get_state "pendingPlannerSpawn")
    if [ -n "$pending_spawn" ]; then
        local pending_epoch
        pending_epoch=$(date -d "$pending_spawn" +%s 2>/dev/null || echo "0")
        local pending_age=$(( $(date +%s) - pending_epoch ))
        if [ "$pending_age" -lt "$PENDING_PLANNER_GRACE" ]; then
            echo "[$(date -u +%H:%M:%S)] Planner liveness: planner recently spawned (${pending_age}s ago, grace=${PENDING_PLANNER_GRACE}s). Skipping to avoid double-spawn."
            return 0
        fi
    fi

    # Count active planner jobs
    local active_planners
    active_planners=$(kubectl_with_timeout 15 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] |
            select(.status.completionTime == null and (.status.active // 0) > 0) |
            select(.metadata.name | test("planner"))] | length' \
        2>/dev/null || echo "-1")

    # kubectl failure — skip check rather than false-positive spawn
    if [ "$active_planners" = "-1" ]; then
        echo "[$(date -u +%H:%M:%S)] Planner liveness: kubectl unavailable, skipping check"
        return 0
    fi

    if [ "$active_planners" -gt 0 ]; then
        # Planner chain healthy — reset last-seen timestamp and clear pending spawn
        update_state "lastPlannerSeen" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        update_state "pendingPlannerSpawn" ""
        return 0
    fi

    # No active planners — check how long the gap has been
    local last_seen
    last_seen=$(get_state "lastPlannerSeen")
    local now_epoch
    now_epoch=$(date +%s)
    local last_seen_epoch=0
    [ -n "$last_seen" ] && last_seen_epoch=$(date -d "$last_seen" +%s 2>/dev/null || echo "0")
    local gap=$(( now_epoch - last_seen_epoch ))

    if [ "$gap" -lt "$PLANNER_LIVENESS_TIMEOUT" ]; then
        echo "[$(date -u +%H:%M:%S)] Planner liveness: no active planner (gap=${gap}s < ${PLANNER_LIVENESS_TIMEOUT}s threshold). Monitoring."
        return 0
    fi

    # Gap exceeded threshold — spawn recovery planner via spawn slot gate
    echo "[$(date -u +%H:%M:%S)] PLANNER CHAIN DEAD: no planner active for ${gap}s (threshold=${PLANNER_LIVENESS_TIMEOUT}s). Spawning recovery planner."

    # Check circuit breaker before spawning
    local cb_limit
    cb_limit=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "8")
    local active_jobs
    active_jobs=$(kubectl_with_timeout 10 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
        jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
        2>/dev/null || echo "99")
    if [ "$active_jobs" -ge "$cb_limit" ]; then
        echo "[$(date -u +%H:%M:%S)] Planner liveness: circuit breaker active ($active_jobs >= $cb_limit). Cannot spawn recovery planner."
        return 0
    fi

    local ts
    ts=$(date +%s)
    local task_name="task-recovery-planner-${ts}"
    local agent_name="planner-recovery-${ts}"

    # Create Task CR
    kubectl_with_timeout 15 apply -f - <<EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Task
metadata:
  name: ${task_name}
  namespace: ${NAMESPACE}
spec:
  title: "Recovery: restart planner chain (coordinator watchdog)"
  description: "Planner chain was dead for ${gap}s. You are the recovery planner. Read the constitution, pick the highest-priority open GitHub issue, implement or delegate it, then spawn your planner successor before exiting. The chain must never break."
  priority: 10
  effort: M
EOF

    # Create Agent CR
    kubectl_with_timeout 15 apply -f - <<EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Agent
metadata:
  name: ${agent_name}
  namespace: ${NAMESPACE}
  labels:
    agentex/role: "planner"
    agentex/generation: "1"
    agentex/spawned-by: "coordinator-watchdog"
spec:
  taskRef: ${task_name}
  role: planner
  priority: 10
EOF

    post_coordinator_thought \
"PLANNER CHAIN RECOVERY: No planner active for ${gap}s. Spawned recovery planner ${agent_name} (task: ${task_name}).
This is the coordinator's planner-chain liveness watchdog. Gap threshold: ${PLANNER_LIVENESS_TIMEOUT}s.
The planner chain is the civilization heartbeat — it must never stay dead for more than 5 minutes." \
        "insight"

    # Reset last-seen AND record pending spawn timestamp so watchdog skips
    # the next PENDING_PLANNER_GRACE seconds (pod scheduling lag window, issue #947)
    update_state "lastPlannerSeen" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    update_state "pendingPlannerSpawn" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo "[$(date -u +%H:%M:%S)] Recovery planner ${agent_name} spawned."
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

    # ADAPTIVE SPAWN SLOT RECONCILIATION (issue #669)
    # When system is near capacity, reconcile every cycle (~30s) to prevent proliferation bursts.
    # When idle, reconcile every 4 iterations (~2 min) to reduce overhead.
    # This prevents the 2-minute reconciliation gap from allowing 16+ agents when limit is 12.
    
    # Read current circuit breaker limit
    cb_limit=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "12")
    if ! [[ "$cb_limit" =~ ^[0-9]+$ ]]; then cb_limit=12; fi
    
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

    # Every 3 iterations (~1.5 min): tally votes and potentially enact
    if [ $((iteration % 3)) -eq 0 ]; then
        tally_and_enact_votes
    fi

    # Every 6 iterations (~3 min): track debate activity and nudge if needed
    if [ $((iteration % 6)) -eq 0 ]; then
        track_debate_activity
    fi

    # NOTE (issue #867): Planner-chain liveness check removed.
    # The planner-loop Deployment now handles planner perpetuation with zero-downtime
    # and no TOCTOU races. Coordinator no longer needs to spawn recovery planners.

    sleep "$HEARTBEAT_INTERVAL"
done
