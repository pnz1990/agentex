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

# ── Helper Functions ─────────────────────────────────────────────────────────

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
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" \
        --type=merge -p "{\"data\":{\"$field\":\"$value\"}}" 2>/dev/null || true
}

get_state() {
    local field="$1"
    kubectl get configmap "$STATE_CM" -n "$NAMESPACE" \
        -o jsonpath="{.data.$field}" 2>/dev/null || echo ""
}

heartbeat() {
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    update_state "lastHeartbeat" "$timestamp"
    
    # Emit coordinator liveness metric (issue #587)
    push_metric "CoordinatorHeartbeat" 1 "Count"
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
        job_active=$(kubectl get job "$agent_name" -n "$NAMESPACE" -o json 2>/dev/null \
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

# Reconcile spawnSlots against actual running job count (leak recovery)
# If agents crash before releasing slots, spawnSlots drifts low.
# This function resets spawnSlots = max(0, circuitBreakerLimit - activeJobs).
reconcile_spawn_slots() {
    local limit
    limit=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "12")
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then limit=12; fi

    local active_jobs
    active_jobs=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
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

# Tally votes from Thought CRs and ENACT consensus when threshold reached
# GENERIC GOVERNANCE ENGINE (issue #630) — handles ANY proposal topic
tally_and_enact_votes() {
    echo "[$(date -u +%H:%M:%S)] Tallying votes from Thought CRs (generic governance engine)..."

    # Read all thought ConfigMaps
    local all_thoughts
    # Use single jq invocation to avoid control-character parse errors from -r | jq -s pipeline
    all_thoughts=$(kubectl get configmaps -n "$NAMESPACE" -o json 2>/dev/null \
        | jq '[.items[] | select(.metadata.name | endswith("-thought")) | {
            agent: (.data.agentRef // "unknown"),
            content: ((.data.content // "") | gsub("[\\u0000-\\u001f]"; " ")),
            type: (.data.thoughtType // ""),
            ts: .metadata.creationTimestamp
          }]' 2>/dev/null) || all_thoughts="[]"

    if [ "$all_thoughts" = "[]" ] || [ -z "$all_thoughts" ]; then
        return 0
    fi

    # Extract all unique proposal topics from #proposal-<topic> tags
    local topics
    topics=$(echo "$all_thoughts" \
        | jq -r '.[] | select(.type == "proposal") | .content' \
        | grep -oE '#proposal-[a-zA-Z0-9_-]+' \
        | sed 's/#proposal-//' \
        | sort -u 2>/dev/null || true)

    if [ -z "$topics" ]; then
        return 0
    fi

    # Process each topic
    while IFS= read -r topic; do
        [ -z "$topic" ] && continue
        
        echo "[$(date -u +%H:%M:%S)] Processing governance topic: $topic"
        
        # Get most recent proposal for this topic
        local proposal_content
        proposal_content=$(echo "$all_thoughts" \
            | jq -r ".[] | select(.type == \"proposal\" and (.content | contains(\"#proposal-$topic\"))) | .content" \
            | tail -1 || true)
        
        [ -z "$proposal_content" ] && continue

        # Extract key=value pairs from proposal
        local kv_pairs
        kv_pairs=$(echo "$proposal_content" | grep -oE '[a-zA-Z0-9_]+=[a-zA-Z0-9_.-]+' || true)
        
        # Count unique approve/reject/abstain votes for this topic
        local approve_votes
        approve_votes=$(echo "$all_thoughts" \
            | jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"approve\")))) | .agent" \
            2>/dev/null | sort -u | wc -l | tr -d ' ')

        local reject_votes
        reject_votes=$(echo "$all_thoughts" \
            | jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"reject\")))) | .agent" \
            2>/dev/null | sort -u | wc -l | tr -d ' ')

        local abstain_votes
        abstain_votes=$(echo "$all_thoughts" \
            | jq -r ".[] | select(.type == \"vote\" and (.content | (contains(\"#vote-$topic\") and contains(\"abstain\")))) | .agent" \
            2>/dev/null | sort -u | wc -l | tr -d ' ')

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
        local decision_key="${topic}_${kv_pairs// /_}"  # unique key for this exact proposal
        
        if echo "$enacted" | grep -qF "$decision_key"; then
            echo "[$(date -u +%H:%M:%S)] $topic already enacted, skipping"
            continue
        fi

        # Enact if threshold reached
        if [ "$approve_votes" -ge "$VOTE_THRESHOLD" ]; then
            echo "[$(date -u +%H:%M:%S)] *** CONSENSUS REACHED: $topic (${approve_votes} approvals) ***"
            
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
                    kubectl patch configmap agentex-constitution -n "$NAMESPACE" \
                        --type=merge \
                        -p "{\"data\":${patch_data}}" \
                        && echo "[$(date -u +%H:%M:%S)] ✓ Constitution patched: $kv_pairs" \
                        || echo "[$(date -u +%H:%M:%S)] ERROR: Failed to patch constitution"
                fi
            fi

            # Record the enacted decision
            local ts
            ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            local enacted_entry="${ts} ${decision_key} approvals=${approve_votes}"
            if [ -z "$enacted" ]; then
                update_state "enactedDecisions" "$enacted_entry"
            else
                update_state "enactedDecisions" "${enacted} | ${enacted_entry}"
            fi

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
    all_cm=$(kubectl get configmaps -n "$NAMESPACE" -o json 2>/dev/null \
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

# Create health check files for Kubernetes probes (issue #619)
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

    # Every 4 iterations (~2 min): reconcile spawn slots against actual job count
    # This recovers leaked slots when agents crash before releasing them
    if [ $((iteration % 4)) -eq 0 ]; then
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

    sleep "$HEARTBEAT_INTERVAL"
done
