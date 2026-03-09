#!/bin/bash
set -euo pipefail

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

# ── CONSTITUTION: Read god-owned constants ─────────────────────────────────
# Read vote threshold from constitution (issue #674)
# God can adjust voting rules without rebuilding coordinator image
VOTE_THRESHOLD=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.voteThreshold}' 2>/dev/null || echo "3")
if ! [[ "$VOTE_THRESHOLD" =~ ^[0-9]+$ ]]; then VOTE_THRESHOLD=3; fi

echo "═══════════════════════════════════════════════════════════════════════════"
echo "COORDINATOR STARTING"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Namespace: $NAMESPACE"
echo "State ConfigMap: $STATE_CM"
echo "Vote threshold: $VOTE_THRESHOLD approvals required (from constitution)"
echo ""

# ── Configure kubectl ────────────────────────────────────────────────────────
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    kubectl config set-cluster local --server=https://kubernetes.default.svc --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    kubectl config set-credentials sa --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    kubectl config set-context local --cluster=local --user=sa --namespace="$NAMESPACE"
    kubectl config use-context local
fi

# ── Helper Functions ─────────────────────────────────────────────────────────

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

# Refresh task queue from open GitHub issues
refresh_task_queue() {
    echo "[$(date -u +%H:%M:%S)] Refreshing task queue from GitHub..."

    # Check if gh is available and authenticated
    if ! gh auth status &>/dev/null 2>&1; then
        echo "[$(date -u +%H:%M:%S)] WARNING: gh CLI not authenticated, skipping queue refresh"
        return 0
    fi

    local issues
    issues=$(gh issue list --repo pnz1990/agentex --state open --limit 50 --json number,labels \
        2>/dev/null \
        | jq -r '.[] | select(.labels[] | .name == "enhancement" or .name == "bug") | .number' \
        | head -10 \
        | tr '\n' ',' \
        | sed 's/,$//') || true

    if [ -n "$issues" ]; then
        local current_queue
        current_queue=$(get_state "taskQueue")

        # Merge new issues with existing queue (deduplicate, preserve order)
        local merged_queue
        merged_queue=$(echo "${current_queue},${issues}" | tr ',' '\n' | grep -v '^$' | sort -un | tr '\n' ',' | sed 's/,$//')

        update_state "taskQueue" "$merged_queue"
        echo "[$(date -u +%H:%M:%S)] Task queue: $merged_queue"
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

# Tally votes from Thought CRs and ENACT consensus when threshold reached
tally_and_enact_votes() {
    echo "[$(date -u +%H:%M:%S)] Tallying votes from Thought CRs..."

    # Read all thought ConfigMaps
    local all_thoughts
    all_thoughts=$(kubectl get configmaps -n "$NAMESPACE" -l agentex/thought -o json 2>/dev/null \
        | jq -r '.items[] | {
            agent: (.data.agentRef // "unknown"),
            content: (.data.content // ""),
            type: (.data.thoughtType // ""),
            ts: .metadata.creationTimestamp
          }' \
        | jq -s '.' 2>/dev/null) || all_thoughts="[]"

    if [ "$all_thoughts" = "[]" ] || [ -z "$all_thoughts" ]; then
        return 0
    fi

    # ── Circuit Breaker Vote ────────────────────────────────────────────────
    # Proposal format: "#proposal-circuit-breaker circuitBreakerLimit=12 reason=<reason>"
    # Vote format:     "#vote-circuit-breaker approve circuitBreakerLimit=12"
    #                  "#vote-circuit-breaker reject reason=<reason>"

    local proposals
    proposals=$(echo "$all_thoughts" \
        | jq -r '.[] | select(.content | contains("#proposal-circuit-breaker")) | .content' \
        2>/dev/null || true)

    if [ -z "$proposals" ]; then
        return 0
    fi

    # Get the proposed value (most recent proposal wins)
    local proposed_value
    proposed_value=$(echo "$proposals" \
        | grep -oE 'circuitBreakerLimit=[0-9]+' \
        | tail -1 \
        | grep -oE '[0-9]+' || true)

    [ -z "$proposed_value" ] && return 0

    # Count approve and reject votes for this topic
    local approve_votes
    approve_votes=$(echo "$all_thoughts" \
        | jq -r '.[] | select(.content | (contains("#vote-circuit-breaker") and contains("approve"))) | .agent' \
        2>/dev/null | sort -u | wc -l | tr -d ' ')

    local reject_votes
    reject_votes=$(echo "$all_thoughts" \
        | jq -r '.[] | select(.content | (contains("#vote-circuit-breaker") and contains("reject"))) | .agent' \
        2>/dev/null | sort -u | wc -l | tr -d ' ')

    echo "[$(date -u +%H:%M:%S)] Vote tally — circuitBreakerLimit=${proposed_value}: approve=${approve_votes} reject=${reject_votes} threshold=${VOTE_THRESHOLD}"

    # Update vote registry
    update_state "voteRegistry" "circuitBreakerLimit=${proposed_value} approve=${approve_votes} reject=${reject_votes} threshold=${VOTE_THRESHOLD}"

    # Check if already enacted (prevent re-enacting)
    local enacted
    enacted=$(get_state "enactedDecisions")
    if echo "$enacted" | grep -q "circuitBreakerLimit=${proposed_value}"; then
        echo "[$(date -u +%H:%M:%S)] circuitBreakerLimit=${proposed_value} already enacted, skipping"
        return 0
    fi

    # Enact if threshold reached
    if [ "$approve_votes" -ge "$VOTE_THRESHOLD" ]; then
        echo "[$(date -u +%H:%M:%S)] *** CONSENSUS REACHED: circuitBreakerLimit=${proposed_value} (${approve_votes} approvals) ***"

        # Patch the constitution
        kubectl patch configmap agentex-constitution -n "$NAMESPACE" \
            --type=merge \
            -p "{\"data\":{\"circuitBreakerLimit\":\"${proposed_value}\"}}" \
            && echo "[$(date -u +%H:%M:%S)] ✓ Constitution patched: circuitBreakerLimit=${proposed_value}" \
            || echo "[$(date -u +%H:%M:%S)] ERROR: Failed to patch constitution"

        # Record the enacted decision
        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        local enacted_entry="${ts} circuitBreakerLimit=${proposed_value} approvals=${approve_votes}"
        if [ -z "$enacted" ]; then
            update_state "enactedDecisions" "$enacted_entry"
        else
            update_state "enactedDecisions" "${enacted} | ${enacted_entry}"
        fi

        # Post verdict Thought CR — this is the civilizational milestone
        post_coordinator_thought \
"CONSENSUS ENACTED: circuitBreakerLimit changed to ${proposed_value}.
Votes: ${approve_votes} approve, ${reject_votes} reject (threshold: ${VOTE_THRESHOLD}).
The civilization has made its first collective governance decision.
Constitution patched at ${ts}. All future agents will use limit=${proposed_value}." \
            "verdict"

        log_decision "circuitBreakerLimit=${proposed_value}" "consensus vote: ${approve_votes} approve ${reject_votes} reject"

        echo "[$(date -u +%H:%M:%S)] MILESTONE: First collective vote enacted."
    fi
}

# ── Main Loop ────────────────────────────────────────────────────────────────

echo "Coordinator entering main loop..."
update_state "phase" "Active"

# Seed the task queue on first start if empty
INITIAL_QUEUE=$(get_state "taskQueue")
if [ -z "$INITIAL_QUEUE" ]; then
    echo "[$(date -u +%H:%M:%S)] Seeding initial task queue from GitHub..."
    refresh_task_queue
fi

iteration=0
while true; do
    iteration=$((iteration + 1))

    heartbeat

    # Every 5 iterations (~2.5 min): refresh task queue from GitHub
    if [ $((iteration % 5)) -eq 0 ]; then
        refresh_task_queue
    fi

    # Every iteration: cleanup stale assignments
    cleanup_stale_assignments

    # Every 3 iterations (~1.5 min): tally votes and potentially enact
    if [ $((iteration % 3)) -eq 0 ]; then
        tally_and_enact_votes
    fi

    sleep "$HEARTBEAT_INTERVAL"
done
