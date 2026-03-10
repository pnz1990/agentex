#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# WATCHDOG HEARTBEAT — Tier 1 of the Multi-Tier Watchdog Chain
# Issue #1844: Multi-tier watchdog chain — detect and recover from failures
#
# This is the mechanical heartbeat layer. It cannot reason, but it cannot
# crash (bash-safe with extensive error handling). Runs every 30 seconds.
#
# Checks:
#   1. Coordinator health (is it alive? is heartbeat fresh?)
#   2. Stuck jobs (running > 30 min)
#   3. Spawn rate anomalies (anti-proliferation)
#   4. Kill switch state consistency
#
# Actions:
#   - HEALTHY: update watchdog-state ConfigMap
#   - DEGRADED: post Thought CR with diagnosis
#   - CRITICAL: activate kill switch + post escalation Thought CR
#
# Usage: Run as a CronJob or sidecar in the coordinator pod
#   kubectl apply -f manifests/system/watchdog-cronjob.yaml
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
WATCHDOG_STATE_CM="watchdog-state"
STUCK_JOB_THRESHOLD_MINUTES="${STUCK_JOB_THRESHOLD:-30}"
SPAWN_RATE_WINDOW_SECONDS="${SPAWN_RATE_WINDOW:-120}"  # 2 minutes
SPAWN_RATE_LIMIT="${SPAWN_RATE_LIMIT:-5}"              # 5 spawns in 2 min
COORDINATOR_HEARTBEAT_STALE_SECONDS="${COORDINATOR_HEARTBEAT_STALE:-300}"  # 5 min

# Health states
STATE_HEALTHY="HEALTHY"
STATE_DEGRADED="DEGRADED"
STATE_CRITICAL="CRITICAL"
STATE_RECOVERING="RECOVERING"

OVERALL_STATE="$STATE_HEALTHY"
ISSUES_FOUND=()
ACTIONS_TAKEN=()

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WATCHDOG: $*"
}

log_issue() {
  local severity="$1"
  local msg="$2"
  ISSUES_FOUND+=("[$severity] $msg")
  log "ISSUE [$severity]: $msg"
}

log_action() {
  local msg="$1"
  ACTIONS_TAKEN+=("$msg")
  log "ACTION: $msg"
}

# ── Configure kubectl ─────────────────────────────────────────────────────────
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  kubectl config set-cluster local \
    --server=https://kubernetes.default.svc \
    --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    2>/dev/null || true
  kubectl config set-credentials sa \
    --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    2>/dev/null || true
  kubectl config set-context local \
    --cluster=local --user=sa --namespace="$NAMESPACE" \
    2>/dev/null || true
  kubectl config use-context local 2>/dev/null || true
fi

# ── Read constitution values ──────────────────────────────────────────────────
CIRCUIT_BREAKER_LIMIT=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "10")
if ! [[ "$CIRCUIT_BREAKER_LIMIT" =~ ^[0-9]+$ ]]; then CIRCUIT_BREAKER_LIMIT=10; fi

S3_BUCKET=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")

log "Starting watchdog heartbeat check (CIRCUIT_BREAKER=$CIRCUIT_BREAKER_LIMIT, NAMESPACE=$NAMESPACE)"

# ════════════════════════════════════════════════════════════════════════
# CHECK 1: Coordinator health
# ════════════════════════════════════════════════════════════════════════
log "--- CHECK 1: Coordinator health ---"
COORD_HEARTBEAT=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.lastHeartbeat}' 2>/dev/null || echo "")
COORD_PHASE=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.phase}' 2>/dev/null || echo "unknown")

if [ -z "$COORD_HEARTBEAT" ]; then
  log_issue "WARN" "Coordinator has no heartbeat recorded (coordinator-state ConfigMap missing or uninitialized)"
  OVERALL_STATE="$STATE_DEGRADED"
else
  NOW_EPOCH=$(date -u +%s 2>/dev/null || echo "0")
  HB_EPOCH=$(date -u -d "$COORD_HEARTBEAT" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$COORD_HEARTBEAT" +%s 2>/dev/null || echo "0")
  HEARTBEAT_AGE=$(( NOW_EPOCH - HB_EPOCH ))

  if [ "$HEARTBEAT_AGE" -gt "$COORDINATOR_HEARTBEAT_STALE_SECONDS" ]; then
    log_issue "CRITICAL" "Coordinator heartbeat stale: last seen ${HEARTBEAT_AGE}s ago (threshold: ${COORDINATOR_HEARTBEAT_STALE_SECONDS}s). Phase: ${COORD_PHASE}"
    OVERALL_STATE="$STATE_CRITICAL"
  elif [ "$HEARTBEAT_AGE" -gt $((COORDINATOR_HEARTBEAT_STALE_SECONDS / 2)) ]; then
    log_issue "WARN" "Coordinator heartbeat slow: last seen ${HEARTBEAT_AGE}s ago. Phase: ${COORD_PHASE}"
    if [ "$OVERALL_STATE" = "$STATE_HEALTHY" ]; then OVERALL_STATE="$STATE_DEGRADED"; fi
  else
    log "Coordinator healthy: heartbeat ${HEARTBEAT_AGE}s ago, phase=${COORD_PHASE}"
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK 2: Stuck jobs (running > STUCK_JOB_THRESHOLD_MINUTES)
# ════════════════════════════════════════════════════════════════════════
log "--- CHECK 2: Stuck jobs (threshold: ${STUCK_JOB_THRESHOLD_MINUTES}min) ---"
STUCK_THRESHOLD_SECONDS=$((STUCK_JOB_THRESHOLD_MINUTES * 60))

STUCK_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq -r --arg threshold "$(date -u -d "${STUCK_JOB_THRESHOLD_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -v-${STUCK_JOB_THRESHOLD_MINUTES}M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
  '.items[] |
    select(.status.completionTime == null) |
    select((.status.active // 0) > 0) |
    select($threshold != "" and .metadata.creationTimestamp < $threshold) |
    "\(.metadata.name) (started: \(.metadata.creationTimestamp), active: \(.status.active // 0))"' \
  2>/dev/null || echo "")

if [ -n "$STUCK_JOBS" ]; then
  STUCK_COUNT=$(echo "$STUCK_JOBS" | grep -c '.' || echo "0")
  log_issue "WARN" "Found ${STUCK_COUNT} stuck job(s) running > ${STUCK_JOB_THRESHOLD_MINUTES}min:"
  while IFS= read -r job; do
    [ -n "$job" ] && log_issue "WARN" "  Stuck: $job"
  done <<< "$STUCK_JOBS"
  if [ "$OVERALL_STATE" = "$STATE_HEALTHY" ]; then OVERALL_STATE="$STATE_DEGRADED"; fi
else
  log "No stuck jobs found"
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK 3: Spawn rate (anti-proliferation)
# ════════════════════════════════════════════════════════════════════════
log "--- CHECK 3: Spawn rate (window: ${SPAWN_RATE_WINDOW_SECONDS}s, limit: ${SPAWN_RATE_LIMIT}) ---"

WINDOW_START=$(date -u -d "${SPAWN_RATE_WINDOW_SECONDS} seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
  date -u -v-${SPAWN_RATE_WINDOW_SECONDS}S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

if [ -n "$WINDOW_START" ]; then
  RECENT_SPAWNS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r --arg since "$WINDOW_START" \
    '[.items[] | select(.metadata.creationTimestamp > $since)] | length' \
    2>/dev/null || echo "0")

  log "Recent spawns in last ${SPAWN_RATE_WINDOW_SECONDS}s: $RECENT_SPAWNS (limit: $SPAWN_RATE_LIMIT)"

  if [ "$RECENT_SPAWNS" -gt "$SPAWN_RATE_LIMIT" ]; then
    log_issue "CRITICAL" "Proliferation detected: ${RECENT_SPAWNS} spawns in ${SPAWN_RATE_WINDOW_SECONDS}s (limit: ${SPAWN_RATE_LIMIT})"
    OVERALL_STATE="$STATE_CRITICAL"

    # Automatically activate kill switch on proliferation
    KILLSWITCH_ENABLED=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
      -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")

    if [ "$KILLSWITCH_ENABLED" != "true" ]; then
      log "ACTIVATING KILL SWITCH: Proliferation detected (${RECENT_SPAWNS} spawns in ${SPAWN_RATE_WINDOW_SECONDS}s)"
      kubectl create configmap agentex-killswitch -n "$NAMESPACE" \
        --from-literal=enabled=true \
        --from-literal=reason="Watchdog Tier 1: Proliferation detected — ${RECENT_SPAWNS} spawns in ${SPAWN_RATE_WINDOW_SECONDS}s (limit: ${SPAWN_RATE_LIMIT}). Auto-activated by watchdog-heartbeat at $(date -u +%Y-%m-%dT%H:%M:%SZ)." \
        --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
      log_action "KILL_SWITCH_ACTIVATED: proliferation threshold exceeded"
    else
      log "Kill switch already active — no duplicate activation needed"
    fi
  else
    log "Spawn rate normal: ${RECENT_SPAWNS} in last ${SPAWN_RATE_WINDOW_SECONDS}s"
  fi
else
  log "WARN: Could not compute spawn rate window start time — skipping spawn rate check"
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK 4: Active job count vs circuit breaker
# ════════════════════════════════════════════════════════════════════════
log "--- CHECK 4: Circuit breaker status ---"
ACTIVE_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
  2>/dev/null || echo "0")

log "Active jobs: $ACTIVE_JOBS / $CIRCUIT_BREAKER_LIMIT"

if [ "$ACTIVE_JOBS" -ge "$CIRCUIT_BREAKER_LIMIT" ]; then
  log_issue "WARN" "Circuit breaker at capacity: ${ACTIVE_JOBS}/${CIRCUIT_BREAKER_LIMIT} active jobs"
  if [ "$OVERALL_STATE" = "$STATE_HEALTHY" ]; then OVERALL_STATE="$STATE_DEGRADED"; fi
elif [ "$ACTIVE_JOBS" -ge $((CIRCUIT_BREAKER_LIMIT * 8 / 10)) ]; then
  log_issue "WARN" "Circuit breaker near capacity: ${ACTIVE_JOBS}/${CIRCUIT_BREAKER_LIMIT} (>80%)"
  if [ "$OVERALL_STATE" = "$STATE_HEALTHY" ]; then OVERALL_STATE="$STATE_DEGRADED"; fi
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK 5: Kill switch state (ensure it's not stuck on when it shouldn't be)
# ════════════════════════════════════════════════════════════════════════
log "--- CHECK 5: Kill switch consistency ---"
KILLSWITCH_ENABLED=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
  -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
KILLSWITCH_REASON=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
  -o jsonpath='{.data.reason}' 2>/dev/null || echo "")

if [ "$KILLSWITCH_ENABLED" = "true" ]; then
  log_issue "INFO" "Kill switch is currently ACTIVE. Reason: ${KILLSWITCH_REASON:-unknown}"
  # If kill switch is active but no proliferation (jobs are low), flag for triage
  if [ "$ACTIVE_JOBS" -lt $((CIRCUIT_BREAKER_LIMIT / 2)) ] && [ "$OVERALL_STATE" != "$STATE_CRITICAL" ]; then
    log_issue "WARN" "Kill switch active but job count is low (${ACTIVE_JOBS}/${CIRCUIT_BREAKER_LIMIT}) — may need manual review to deactivate"
    if [ "$OVERALL_STATE" = "$STATE_HEALTHY" ]; then OVERALL_STATE="$STATE_DEGRADED"; fi
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# UPDATE WATCHDOG STATE
# ════════════════════════════════════════════════════════════════════════
log "--- Updating watchdog state ---"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ISSUES_STR=$(printf '%s|' "${ISSUES_FOUND[@]:-none}" | sed 's/|$//')
ACTIONS_STR=$(printf '%s|' "${ACTIONS_TAKEN[@]:-none}" | sed 's/|$//')

kubectl create configmap "$WATCHDOG_STATE_CM" -n "$NAMESPACE" \
  --from-literal=lastCheck="$TIMESTAMP" \
  --from-literal=healthState="$OVERALL_STATE" \
  --from-literal=activeJobs="$ACTIVE_JOBS" \
  --from-literal=circuitBreakerLimit="$CIRCUIT_BREAKER_LIMIT" \
  --from-literal=coordinatorHeartbeatAge="${HEARTBEAT_AGE:-unknown}" \
  --from-literal=stuckJobCount="$(echo "$STUCK_JOBS" | grep -c '.' 2>/dev/null || echo "0")" \
  --from-literal=issuesFound="${ISSUES_STR:-none}" \
  --from-literal=actionsTaken="${ACTIONS_STR:-none}" \
  --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════
# POST THOUGHT CR FOR DEGRADED/CRITICAL STATES
# ════════════════════════════════════════════════════════════════════════
TS=$(date +%s)

if [ "$OVERALL_STATE" = "$STATE_CRITICAL" ]; then
  log "CRITICAL state — posting escalation Thought CR"
  kubectl apply -f - <<EOF 2>/dev/null || log "WARN: Failed to post critical thought CR"
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-watchdog-critical-${TS}
  namespace: ${NAMESPACE}
spec:
  agentRef: "watchdog-tier1"
  taskRef: "watchdog-heartbeat"
  thoughtType: blocker
  confidence: 10
  content: |
    WATCHDOG TIER 1 — CRITICAL STATE DETECTED
    Timestamp: ${TIMESTAMP}
    State: CRITICAL
    Active jobs: ${ACTIVE_JOBS} / ${CIRCUIT_BREAKER_LIMIT}
    
    Issues found:
    $(printf '    - %s\n' "${ISSUES_FOUND[@]:-none}")
    
    Actions taken:
    $(printf '    - %s\n' "${ACTIONS_TAKEN[@]:-none}")
    
    HUMAN ATTENTION MAY BE REQUIRED.
    Check kill switch: kubectl get configmap agentex-killswitch -n ${NAMESPACE}
    Check jobs: kubectl get jobs -n ${NAMESPACE}
EOF

elif [ "$OVERALL_STATE" = "$STATE_DEGRADED" ]; then
  log "DEGRADED state — posting diagnosis Thought CR"
  kubectl apply -f - <<EOF 2>/dev/null || log "WARN: Failed to post degraded thought CR"
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-watchdog-degraded-${TS}
  namespace: ${NAMESPACE}
spec:
  agentRef: "watchdog-tier1"
  taskRef: "watchdog-heartbeat"
  thoughtType: insight
  confidence: 8
  content: |
    WATCHDOG TIER 1 — DEGRADED STATE
    Timestamp: ${TIMESTAMP}
    State: DEGRADED (system operational but not fully healthy)
    Active jobs: ${ACTIVE_JOBS} / ${CIRCUIT_BREAKER_LIMIT}
    
    Issues found:
    $(printf '    - %s\n' "${ISSUES_FOUND[@]:-none}")
    
    Tier 2 AI Triage will investigate and diagnose.
    No kill switch activation — situation does not warrant emergency stop.
EOF
fi

log "Watchdog heartbeat complete. State: $OVERALL_STATE"
log "Issues found: ${#ISSUES_FOUND[@]}"
log "Actions taken: ${#ACTIONS_TAKEN[@]}"

# Exit codes: 0=healthy, 1=degraded, 2=critical
case "$OVERALL_STATE" in
  "$STATE_HEALTHY") exit 0 ;;
  "$STATE_DEGRADED") exit 1 ;;
  "$STATE_CRITICAL") exit 2 ;;
  *) exit 0 ;;
esac
