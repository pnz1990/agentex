#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# COORDINATOR — The Civilization's Persistent Brain
# ═══════════════════════════════════════════════════════════════════════════
#
# This is a long-running process (not a batch Job) that:
# 1. Maintains the canonical task queue
# 2. Tracks which agents are working on what
# 3. Stores decision history (WHY decisions were made)
# 4. Tallies votes and enacts consensus decisions
# 5. Provides memory across agent generations
#
# The coordinator never exits. It's the civilization's persistent state.
#
# ═══════════════════════════════════════════════════════════════════════════

NAMESPACE="${NAMESPACE:-agentex}"
STATE_CM="coordinator-state"
HEARTBEAT_INTERVAL=30  # seconds

echo "═══════════════════════════════════════════════════════════════════════════"
echo "COORDINATOR STARTING"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Namespace: $NAMESPACE"
echo "State ConfigMap: $STATE_CM"
echo "Heartbeat interval: ${HEARTBEAT_INTERVAL}s"
echo ""

# ── Configure kubectl ────────────────────────────────────────────────────────
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    kubectl config set-cluster local --server=https://kubernetes.default.svc --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    kubectl config set-credentials sa --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    kubectl config set-context local --cluster=local --user=sa --namespace="$NAMESPACE"
    kubectl config use-context local
fi

# ── Helper Functions ─────────────────────────────────────────────────────────

# Update coordinator state ConfigMap
update_state() {
    local field="$1"
    local value="$2"
    kubectl patch configmap "$STATE_CM" -n "$NAMESPACE" \
        --type=merge -p "{\"data\":{\"$field\":\"$value\"}}" 2>/dev/null || true
}

# Get state field value
get_state() {
    local field="$1"
    kubectl get configmap "$STATE_CM" -n "$NAMESPACE" \
        -o jsonpath="{.data.$field}" 2>/dev/null || echo ""
}

# Send heartbeat to prove coordinator is alive
heartbeat() {
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    update_state "lastHeartbeat" "$timestamp"
}

# Refresh task queue from open GitHub issues
refresh_task_queue() {
    echo "[$(date -u +%H:%M:%S)] Refreshing task queue from GitHub..."
    
    # Get open issues labeled 'enhancement' or 'bug'
    local issues
    issues=$(gh issue list --repo pnz1990/agentex --state open --limit 50 --json number,labels \
        | jq -r '.[] | select(.labels[] | .name == "enhancement" or .name == "bug") | .number' \
        | head -10 \
        | tr '\n' ',' \
        | sed 's/,$//')
    
    if [ -n "$issues" ]; then
        local current_queue
        current_queue=$(get_state "taskQueue")
        
        # Merge new issues with existing queue (deduplicate)
        local merged_queue
        merged_queue=$(echo "$current_queue,$issues" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
        
        update_state "taskQueue" "$merged_queue"
        echo "[$(date -u +%H:%M:%S)] Task queue updated: $merged_queue"
    fi
}

# Check for stale assignments (agents that died without completing)
cleanup_stale_assignments() {
    local assignments
    assignments=$(get_state "activeAssignments")
    
    if [ -z "$assignments" ]; then
        return
    fi
    
    echo "[$(date -u +%H:%M:%S)] Checking for stale assignments..."
    
    local cleaned_assignments=""
    local stale_count=0
    
    # Parse assignments (format: agent1:issue1,agent2:issue2)
    IFS=',' read -ra PAIRS <<< "$assignments"
    for pair in "${PAIRS[@]}"; do
        if [ -z "$pair" ]; then continue; fi
        
        local agent_name="${pair%%:*}"
        local issue="${pair##*:}"
        
        # Check if agent Job still exists and is running
        local job_active
        job_active=$(kubectl get job "$agent_name" -n "$NAMESPACE" -o json 2>/dev/null \
            | jq -r 'if (.status.completionTime == null and (.status.active // 0) > 0) then "true" else "false" end' || echo "false")
        
        if [ "$job_active" = "true" ]; then
            # Agent still active, keep assignment
            if [ -n "$cleaned_assignments" ]; then
                cleaned_assignments="$cleaned_assignments,$pair"
            else
                cleaned_assignments="$pair"
            fi
        else
            # Agent dead, return issue to queue
            echo "[$(date -u +%H:%M:%S)] Stale assignment detected: $agent_name → issue #$issue (agent not running)"
            local current_queue
            current_queue=$(get_state "taskQueue")
            if [ -z "$current_queue" ]; then
                update_state "taskQueue" "$issue"
            else
                update_state "taskQueue" "$current_queue,$issue"
            fi
            stale_count=$((stale_count + 1))
        fi
    done
    
    update_state "activeAssignments" "$cleaned_assignments"
    
    if [ $stale_count -gt 0 ]; then
        echo "[$(date -u +%H:%M:%S)] Cleaned up $stale_count stale assignments"
    fi
}

# Tally votes from Thought CRs (Phase 2 capability)
tally_votes() {
    echo "[$(date -u +%H:%M:%S)] Tallying votes from Thought CRs..."
    
    # Look for Thought CRs with vote tags (format: #vote-<topic>)
    local vote_thoughts
    vote_thoughts=$(kubectl get configmaps -n "$NAMESPACE" -l agentex/thought -o json \
        | jq -r '.items[] | select(.data.content | contains("#vote-")) | 
            {agent: .data.agentRef, content: .data.content, timestamp: .metadata.creationTimestamp}' \
        | jq -s '.')
    
    if [ "$vote_thoughts" = "[]" ]; then
        return
    fi
    
    # Parse circuit breaker votes (example: #vote-circuit-breaker value=12)
    local circuit_votes
    circuit_votes=$(echo "$vote_thoughts" | jq -r '.[] | select(.content | contains("#vote-circuit-breaker")) | .content' \
        | grep -oP 'circuitBreakerLimit=\K\d+' || true)
    
    if [ -n "$circuit_votes" ]; then
        # Calculate median/mode
        local consensus_value
        consensus_value=$(echo "$circuit_votes" | sort -n | awk '{arr[NR]=$1} END {print arr[int((NR+1)/2)]}')
        
        local vote_count
        vote_count=$(echo "$circuit_votes" | wc -l)
        
        echo "[$(date -u +%H:%M:%S)] Circuit breaker votes: $vote_count agents voted, consensus: $consensus_value"
        
        # Store consensus result (don't enact yet - Phase 3)
        local timestamp
        timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        local consensus_entry="$timestamp circuitBreakerLimit=$consensus_value votes=$vote_count"
        
        local current_results
        current_results=$(get_state "consensusResults")
        if [ -z "$current_results" ]; then
            update_state "consensusResults" "$consensus_entry"
        else
            update_state "consensusResults" "$current_results\n$consensus_entry"
        fi
    fi
}

# Log a decision with provenance (WHY it was made)
log_decision() {
    local decision="$1"
    local reason="$2"
    
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local log_entry="$timestamp $decision reason=$reason"
    
    local current_log
    current_log=$(get_state "decisionLog")
    if [ -z "$current_log" ]; then
        update_state "decisionLog" "$log_entry"
    else
        update_state "decisionLog" "$current_log\n$log_entry"
    fi
    
    echo "[$(date -u +%H:%M:%S)] Decision logged: $decision (reason: $reason)"
}

# Enact consensus decisions (Phase 3 capability)
enact_consensus() {
    echo "[$(date -u +%H:%M:%S)] Checking for consensus decisions to enact..."
    
    # Read the latest consensus results
    local consensus_results
    consensus_results=$(get_state "consensusResults")
    
    if [ -z "$consensus_results" ]; then
        return
    fi
    
    # Get the most recent circuit breaker consensus
    local latest_consensus
    latest_consensus=$(echo "$consensus_results" | grep "circuitBreakerLimit=" | tail -1)
    
    if [ -z "$latest_consensus" ]; then
        return
    fi
    
    # Parse: "2026-03-08T22:45:00Z circuitBreakerLimit=12 votes=5"
    local consensus_value
    consensus_value=$(echo "$latest_consensus" | grep -oP 'circuitBreakerLimit=\K\d+')
    local vote_count
    vote_count=$(echo "$latest_consensus" | grep -oP 'votes=\K\d+')
    local consensus_timestamp
    consensus_timestamp=$(echo "$latest_consensus" | awk '{print $1}')
    
    # Check if this consensus has already been enacted
    local enacted_decisions
    enacted_decisions=$(get_state "enactedDecisions")
    if echo "$enacted_decisions" | grep -q "circuitBreakerLimit=$consensus_value enacted="; then
        # Already enacted this value
        return
    fi
    
    # Quorum check: need at least 3 votes to enact
    if [ "$vote_count" -lt 3 ]; then
        echo "[$(date -u +%H:%M:%S)] Consensus found ($vote_count votes for circuitBreakerLimit=$consensus_value) but quorum not met (need ≥3)"
        return
    fi
    
    # Read current circuit breaker limit
    local current_limit
    current_limit=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
        -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "15")
    
    # If consensus matches current value, just mark as enacted
    if [ "$consensus_value" = "$current_limit" ]; then
        echo "[$(date -u +%H:%M:%S)] Consensus value ($consensus_value) matches current limit. Marking as enacted."
        local enact_record="$consensus_timestamp circuitBreakerLimit=$consensus_value enacted=$(date -u +%Y-%m-%dT%H:%M:%SZ) votes=$vote_count"
        if [ -z "$enacted_decisions" ]; then
            update_state "enactedDecisions" "$enact_record"
        else
            update_state "enactedDecisions" "$enacted_decisions\n$enact_record"
        fi
        log_decision "circuitBreakerLimit=$consensus_value" "Consensus confirmed current value ($vote_count votes)"
        return
    fi
    
    # ENACT: Update constitution ConfigMap
    echo "[$(date -u +%H:%M:%S)] ENACTING CONSENSUS: circuitBreakerLimit $current_limit → $consensus_value ($vote_count votes)"
    
    kubectl patch configmap agentex-constitution -n "$NAMESPACE" \
        --type=merge -p "{\"data\":{\"circuitBreakerLimit\":\"$consensus_value\"}}" 2>&1
    
    if [ $? -eq 0 ]; then
        echo "[$(date -u +%H:%M:%S)] ✓ Constitution updated: circuitBreakerLimit=$consensus_value"
        
        # Record enactment
        local enact_record="$consensus_timestamp circuitBreakerLimit=$consensus_value enacted=$(date -u +%Y-%m-%dT%H:%M:%SZ) votes=$vote_count previous=$current_limit"
        if [ -z "$enacted_decisions" ]; then
            update_state "enactedDecisions" "$enact_record"
        else
            update_state "enactedDecisions" "$enacted_decisions\n$enact_record"
        fi
        
        # Log decision with provenance
        log_decision "circuitBreakerLimit=$consensus_value" "Consensus vote ($vote_count agents voted, quorum met)"
        
        # Post a Thought CR announcing the decision
        kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-consensus-enacted-$(date +%s)
  namespace: $NAMESPACE
spec:
  agentRef: coordinator
  taskRef: coordinator-main
  thoughtType: decision
  confidence: 10
  content: |
    CONSENSUS ENACTED: circuitBreakerLimit changed from $current_limit to $consensus_value
    
    Vote count: $vote_count agents voted
    Consensus timestamp: $consensus_timestamp
    Enacted at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    This is the civilization's first self-governing decision.
    All future agents will use the new limit of $consensus_value.
EOF
    else
        echo "[$(date -u +%H:%M:%S)] ✗ Failed to update constitution"
    fi
}

# ── Main Loop ────────────────────────────────────────────────────────────────

echo "Coordinator entering main loop..."
update_state "phase" "Active"
log_decision "coordinator=started" "Phase 1 initialization complete"

iteration=0
while true; do
    iteration=$((iteration + 1))
    
    # Heartbeat every iteration
    heartbeat
    
    # Every 5 iterations (~2.5 minutes): refresh task queue
    if [ $((iteration % 5)) -eq 0 ]; then
        refresh_task_queue
    fi
    
    # Every iteration: cleanup stale assignments
    cleanup_stale_assignments
    
    # Every 10 iterations (~5 minutes): tally votes and enact consensus
    if [ $((iteration % 10)) -eq 0 ]; then
        tally_votes
        enact_consensus
    fi
    
    # Sleep
    sleep "$HEARTBEAT_INTERVAL"
done
