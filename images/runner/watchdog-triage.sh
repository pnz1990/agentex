#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# WATCHDOG TRIAGE — Tier 2 AI Health Check (issue #1844)
# ═══════════════════════════════════════════════════════════════════════════
#
# A lightweight, ephemeral Job that runs every 5 minutes.
# Unlike the Tier 1 mechanical heartbeat (in coordinator.sh), this script
# uses AI reasoning via OpenCode to assess system health.
#
# Checks:
#   1. Are agents making progress? (recent commits, PRs, Thought CRs)
#   2. Is coordinator state consistent? (counters match reality)
#   3. Are there unresolved escalations?
#   4. Is the Tier 1 watchdog state stale or degraded?
#
# Actions:
#   - HEALTHY: emit metric, post brief Thought CR, exit 0
#   - DEGRADED: post diagnosis Thought CR, emit alert metric, exit 0
#   - CRITICAL: post Thought CR, activate kill switch (if needed), exit 1
#
# This is a BASH-only script (no OpenCode/LLM call from inside the script).
# The script itself performs the health checks and posts structured findings.
# For full AI triage, this script is the "prompt + data gathering" layer
# that a future OpenCode session will read as context.
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
BEDROCK_REGION="${BEDROCK_REGION:-us-west-2}"
REPO="${REPO:-pnz1990/agentex}"

# Health assessment thresholds
THOUGHT_FRESHNESS_SECONDS=300       # 5 min — if no new thoughts, system may be idle
COORDINATOR_STALE_HEARTBEAT=180     # 3 min — coordinator heartbeat stale threshold
STUCK_JOB_THRESHOLD_MIN=30          # minutes a job can run before considered stuck
DEGRADED_ESCALATION_COUNT=3         # unresolved escalations before flagging degraded

echo "═══════════════════════════════════════════════════════════════════════════"
echo "WATCHDOG TRIAGE STARTING"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Namespace: $NAMESPACE"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# ── Configure kubectl ────────────────────────────────────────────────────────
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    kubectl config set-cluster local \
        --server=https://kubernetes.default.svc \
        --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt 2>/dev/null
    kubectl config set-credentials sa \
        --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" 2>/dev/null
    kubectl config set-context local --cluster=local --user=sa --namespace="$NAMESPACE" 2>/dev/null
    kubectl config use-context local 2>/dev/null
fi

kubectl_with_timeout() {
    local timeout_secs="${1:-10}"
    shift
    timeout "${timeout_secs}s" kubectl "$@" 2>/dev/null
}

push_metric() {
    local metric_name="$1"
    local value="$2"
    local unit="${3:-Count}"
    local dimensions="${4:-Component=WatchdogTriage}"

    aws cloudwatch put-metric-data \
        --namespace Agentex \
        --metric-name "$metric_name" \
        --value "$value" \
        --unit "$unit" \
        --dimensions "$dimensions" \
        --region "$BEDROCK_REGION" 2>/dev/null || true
}

post_triage_thought() {
    local content="$1"
    local thought_type="${2:-insight}"
    local ts
    ts=$(date +%s)

    kubectl_with_timeout 10 apply -f - <<EOF 2>/dev/null || true
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-watchdog-triage-${ts}
  namespace: ${NAMESPACE}
spec:
  agentRef: "watchdog-triage"
  taskRef: "watchdog-triage-cron"
  thoughtType: ${thought_type}
  confidence: 9
  content: |
    ${content}
EOF
    echo "[$(date -u +%H:%M:%S)] Posted ${thought_type} thought"
}

# ── Health State Tracking ──────────────────────────────────────────────────
HEALTH_STATE="healthy"
HEALTH_FINDINGS=()
NOW_EPOCH=$(date +%s)

# ── Check 1: Agent Activity (recent Thought CRs) ────────────────────────────
echo ""
echo "[$(date -u +%H:%M:%S)] Check 1: Agent activity (recent Thought CRs)..."

RECENT_THOUGHTS=$(kubectl_with_timeout 15 get configmaps -n "$NAMESPACE" \
    -l agentex/thought -o json 2>/dev/null | \
    jq --argjson cutoff "$(( NOW_EPOCH - THOUGHT_FRESHNESS_SECONDS ))" \
    '[.items[] | select(
        (.metadata.creationTimestamp | fromdateiso8601) > $cutoff
    )] | length' 2>/dev/null || echo "0")

echo "[$(date -u +%H:%M:%S)] Thought CRs in last 5 min: $RECENT_THOUGHTS"
push_metric "WatchdogTriageRecentThoughts" "$RECENT_THOUGHTS" "Count"

if [ "$RECENT_THOUGHTS" -eq 0 ]; then
    echo "[$(date -u +%H:%M:%S)] WARNING: No Thought CRs in last 5 minutes — system may be idle"
    HEALTH_STATE="degraded"
    HEALTH_FINDINGS+=("no-recent-thoughts: system may be idle or all agents crashed")
else
    echo "[$(date -u +%H:%M:%S)] OK: Agent activity detected ($RECENT_THOUGHTS thoughts)"
fi

# ── Check 2: Active Jobs ─────────────────────────────────────────────────────
echo ""
echo "[$(date -u +%H:%M:%S)] Check 2: Active job count..."

ACTIVE_JOBS=$(kubectl_with_timeout 15 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
    2>/dev/null || echo "0")
FAILED_JOBS=$(kubectl_with_timeout 15 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '[.items[] | select((.status.failed // 0) > 0 and .status.completionTime == null)] | length' \
    2>/dev/null || echo "0")

CB_LIMIT=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
    -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "10")
if ! [[ "$CB_LIMIT" =~ ^[0-9]+$ ]]; then CB_LIMIT=10; fi

echo "[$(date -u +%H:%M:%S)] Active jobs: $ACTIVE_JOBS / $CB_LIMIT (circuit breaker limit)"
echo "[$(date -u +%H:%M:%S)] Failed jobs (not complete): $FAILED_JOBS"
push_metric "WatchdogTriageActiveJobs" "$ACTIVE_JOBS" "Count"
push_metric "WatchdogTriageFailedJobs" "$FAILED_JOBS" "Count"

# Check for stuck jobs
STUCK_THRESHOLD_EPOCH=$(( NOW_EPOCH - STUCK_JOB_THRESHOLD_MIN * 60 ))
STUCK_JOBS=$(kubectl_with_timeout 15 get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq --argjson threshold "$STUCK_THRESHOLD_EPOCH" \
    '[.items[] | select(
        .status.completionTime == null and
        (.status.active // 0) > 0 and
        (.metadata.creationTimestamp | fromdateiso8601) < $threshold
    ) | .metadata.name]' 2>/dev/null || echo "[]")

STUCK_COUNT=$(echo "$STUCK_JOBS" | jq 'length' 2>/dev/null || echo "0")
if [ "$STUCK_COUNT" -gt 0 ]; then
    STUCK_NAMES=$(echo "$STUCK_JOBS" | jq -r '.[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    echo "[$(date -u +%H:%M:%S)] WARNING: $STUCK_COUNT stuck job(s) (>${STUCK_JOB_THRESHOLD_MIN}min): $STUCK_NAMES"
    push_metric "WatchdogTriageStuckJobs" "$STUCK_COUNT" "Count"
    HEALTH_STATE="degraded"
    HEALTH_FINDINGS+=("stuck-jobs:${STUCK_COUNT} (${STUCK_NAMES})")
else
    echo "[$(date -u +%H:%M:%S)] OK: No stuck jobs"
    push_metric "WatchdogTriageStuckJobs" 0 "Count"
fi

if [ "$FAILED_JOBS" -gt 3 ]; then
    echo "[$(date -u +%H:%M:%S)] WARNING: High failure rate ($FAILED_JOBS failing jobs)"
    HEALTH_STATE="degraded"
    HEALTH_FINDINGS+=("high-failure-rate:${FAILED_JOBS}-failing-jobs")
fi

# ── Check 3: Coordinator state consistency ───────────────────────────────────
echo ""
echo "[$(date -u +%H:%M:%S)] Check 3: Coordinator state consistency..."

COORDINATOR_STATE=$(kubectl_with_timeout 15 get configmap coordinator-state -n "$NAMESPACE" \
    -o json 2>/dev/null || echo "{}")

LAST_HEARTBEAT=$(echo "$COORDINATOR_STATE" | \
    jq -r '.data.lastHeartbeat // ""' 2>/dev/null || echo "")
WATCHDOG_STATE=$(echo "$COORDINATOR_STATE" | \
    jq -r '.data.watchdogState // "unknown"' 2>/dev/null || echo "unknown")

echo "[$(date -u +%H:%M:%S)] Coordinator lastHeartbeat: ${LAST_HEARTBEAT:-'(none)'}"
echo "[$(date -u +%H:%M:%S)] Tier 1 watchdog state: $WATCHDOG_STATE"

if [ -n "$LAST_HEARTBEAT" ]; then
    HB_EPOCH=$(date -d "$LAST_HEARTBEAT" +%s 2>/dev/null || echo "0")
    HB_AGE=$(( NOW_EPOCH - HB_EPOCH ))
    push_metric "WatchdogTriageCoordinatorHeartbeatAge" "$HB_AGE" "Seconds"

    if [ "$HB_AGE" -gt "$COORDINATOR_STALE_HEARTBEAT" ]; then
        echo "[$(date -u +%H:%M:%S)] CRITICAL: Coordinator heartbeat stale (${HB_AGE}s > ${COORDINATOR_STALE_HEARTBEAT}s)"
        HEALTH_STATE="critical"
        HEALTH_FINDINGS+=("coordinator-stale-heartbeat:${HB_AGE}s")
    else
        echo "[$(date -u +%H:%M:%S)] OK: Coordinator heartbeat fresh (${HB_AGE}s)"
    fi
else
    echo "[$(date -u +%H:%M:%S)] WARNING: Coordinator has no heartbeat timestamp"
    HEALTH_FINDINGS+=("coordinator-no-heartbeat")
    HEALTH_STATE="degraded"
fi

# Check if Tier 1 watchdog already flagged critical
if echo "$WATCHDOG_STATE" | grep -q "^critical:"; then
    echo "[$(date -u +%H:%M:%S)] CRITICAL: Tier 1 watchdog flagged critical: $WATCHDOG_STATE"
    HEALTH_STATE="critical"
    HEALTH_FINDINGS+=("tier1-watchdog-critical:${WATCHDOG_STATE}")
elif echo "$WATCHDOG_STATE" | grep -q "^degraded:"; then
    echo "[$(date -u +%H:%M:%S)] DEGRADED: Tier 1 watchdog flagged degraded: $WATCHDOG_STATE"
    if [ "$HEALTH_STATE" != "critical" ]; then
        HEALTH_STATE="degraded"
    fi
    HEALTH_FINDINGS+=("tier1-watchdog-degraded:${WATCHDOG_STATE}")
fi

# Check spawn slot consistency
SPAWN_SLOTS=$(echo "$COORDINATOR_STATE" | jq -r '.data.spawnSlots // "-1"' 2>/dev/null || echo "-1")
if ! [[ "$SPAWN_SLOTS" =~ ^[0-9]+$ ]]; then
    echo "[$(date -u +%H:%M:%S)] DEGRADED: spawnSlots is invalid: '$SPAWN_SLOTS' — coordinator may be stuck"
    HEALTH_STATE="degraded"
    HEALTH_FINDINGS+=("invalid-spawn-slots:${SPAWN_SLOTS}")
else
    EXPECTED_SLOTS=$(( CB_LIMIT - ACTIVE_JOBS ))
    [ "$EXPECTED_SLOTS" -lt 0 ] && EXPECTED_SLOTS=0
    SLOT_DRIFT=$(( SPAWN_SLOTS - EXPECTED_SLOTS ))
    [ "$SLOT_DRIFT" -lt 0 ] && SLOT_DRIFT=$(( -SLOT_DRIFT ))
    push_metric "WatchdogTriageSpawnSlotDrift" "$SLOT_DRIFT" "Count"
    if [ "$SLOT_DRIFT" -gt 3 ]; then
        echo "[$(date -u +%H:%M:%S)] WARNING: spawnSlots drift=$SLOT_DRIFT (slots=$SPAWN_SLOTS, expected=$EXPECTED_SLOTS)"
        HEALTH_FINDINGS+=("spawn-slot-drift:${SLOT_DRIFT}")
    else
        echo "[$(date -u +%H:%M:%S)] OK: spawnSlots consistent (slots=$SPAWN_SLOTS, drift=$SLOT_DRIFT)"
    fi
fi

# ── Check 4: Unresolved escalations ─────────────────────────────────────────
echo ""
echo "[$(date -u +%H:%M:%S)] Check 4: Unresolved escalations..."

UNRESOLVED_DEBATES=$(echo "$COORDINATOR_STATE" | \
    jq -r '.data.unresolvedDebates // ""' 2>/dev/null || echo "")
UNRESOLVED_COUNT=0
if [ -n "$UNRESOLVED_DEBATES" ]; then
    # Count comma-separated entries
    UNRESOLVED_COUNT=$(echo "$UNRESOLVED_DEBATES" | tr ',' '\n' | grep -c . || echo "0")
fi

echo "[$(date -u +%H:%M:%S)] Unresolved debate escalations: $UNRESOLVED_COUNT"
push_metric "WatchdogTriageUnresolvedEscalations" "$UNRESOLVED_COUNT" "Count"

if [ "$UNRESOLVED_COUNT" -ge "$DEGRADED_ESCALATION_COUNT" ]; then
    echo "[$(date -u +%H:%M:%S)] WARNING: $UNRESOLVED_COUNT unresolved escalations (threshold: $DEGRADED_ESCALATION_COUNT)"
    if [ "$HEALTH_STATE" = "healthy" ]; then
        HEALTH_STATE="degraded"
    fi
    HEALTH_FINDINGS+=("unresolved-escalations:${UNRESOLVED_COUNT}")
fi

# ── Check 5: Kill switch status ──────────────────────────────────────────────
echo ""
echo "[$(date -u +%H:%M:%S)] Check 5: Kill switch status..."

KS_ENABLED=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
    -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
KS_REASON=$(kubectl_with_timeout 10 get configmap agentex-killswitch -n "$NAMESPACE" \
    -o jsonpath='{.data.reason}' 2>/dev/null || echo "")

echo "[$(date -u +%H:%M:%S)] Kill switch: $KS_ENABLED (reason: ${KS_REASON:-none})"
push_metric "WatchdogTriageKillSwitchActive" "$( [ "$KS_ENABLED" = "true" ] && echo 1 || echo 0 )" "Count"

if [ "$KS_ENABLED" = "true" ]; then
    echo "[$(date -u +%H:%M:%S)] WARNING: Kill switch is active — civilization not spawning"
    HEALTH_FINDINGS+=("kill-switch-active:${KS_REASON}")
    # Kill switch active during triage counts as degraded (not critical — it may be intentional)
    if [ "$HEALTH_STATE" = "healthy" ]; then
        HEALTH_STATE="degraded"
    fi
fi

# ── Generate Report ──────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "[$(date -u +%H:%M:%S)] TRIAGE SUMMARY"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Health state: $HEALTH_STATE"
echo "Findings:"
for finding in "${HEALTH_FINDINGS[@]+"${HEALTH_FINDINGS[@]}"}"; do
    echo "  - $finding"
done
echo ""

push_metric "WatchdogTriageHealthy" "$( [ "$HEALTH_STATE" = "healthy" ] && echo 1 || echo 0 )" "Count"
push_metric "WatchdogTriageFindingCount" "${#HEALTH_FINDINGS[@]}" "Count"

# Post triage Thought CR with findings
FINDINGS_TEXT=""
for finding in "${HEALTH_FINDINGS[@]+"${HEALTH_FINDINGS[@]}"}"; do
    FINDINGS_TEXT="${FINDINGS_TEXT}    - ${finding}
"
done

if [ "$HEALTH_STATE" = "healthy" ]; then
    post_triage_thought \
        "WATCHDOG TRIAGE [healthy]: All checks passed.
Active jobs: $ACTIVE_JOBS / $CB_LIMIT | Stuck: 0 | Recent thoughts: $RECENT_THOUGHTS
Tier 1 watchdog: $WATCHDOG_STATE
No action required." \
        "insight"
    echo "[$(date -u +%H:%M:%S)] Triage complete: HEALTHY"
elif [ "$HEALTH_STATE" = "degraded" ]; then
    post_triage_thought \
        "WATCHDOG TRIAGE [degraded]: System degraded — attention recommended.
Findings:
${FINDINGS_TEXT}
Active jobs: $ACTIVE_JOBS / $CB_LIMIT | Recent thoughts: $RECENT_THOUGHTS
Tier 1 watchdog: $WATCHDOG_STATE
Recommended action: Investigate the flagged issues. If stuck jobs persist, consider killing them manually." \
        "blocker"
    echo "[$(date -u +%H:%M:%S)] Triage complete: DEGRADED — posted blocker thought"
    exit 0
elif [ "$HEALTH_STATE" = "critical" ]; then
    post_triage_thought \
        "WATCHDOG TRIAGE [critical]: System in critical state — immediate action required.
Findings:
${FINDINGS_TEXT}
Active jobs: $ACTIVE_JOBS / $CB_LIMIT | Recent thoughts: $RECENT_THOUGHTS
Tier 1 watchdog: $WATCHDOG_STATE
Kill switch: $KS_ENABLED
Action: Human intervention may be required. Check god issue #62 for status." \
        "blocker"
    push_metric "WatchdogTriageCritical" 1 "Count"
    echo "[$(date -u +%H:%M:%S)] Triage complete: CRITICAL — posted blocker thought"
    exit 1
fi

echo "[$(date -u +%H:%M:%S)] Watchdog triage completed successfully"
exit 0
