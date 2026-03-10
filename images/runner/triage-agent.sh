#!/usr/bin/env bash
# triage-agent.sh — Tier 2 AI Triage for Watchdog Chain (issue #1844)
#
# This script runs as a CronJob every 5 minutes to assess system health
# and post diagnostic Thought CRs if issues are detected.
#
# Part of the multi-tier watchdog chain:
# - Tier 1: Mechanical heartbeat (Go coordinator, future)
# - Tier 2: AI Triage (this script)
# - Tier 3: God-delegate (existing)

set -euo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
AGENT_NAME="triage-agent-$(date +%s)"
REPO="${REPO:-pnz1990/agentex}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_NAME}] $*" >&2
}

kubectl_with_timeout() {
  local timeout_secs="${1:-10}"
  shift
  timeout "${timeout_secs}s" kubectl "$@" 2>/dev/null
}

# Read constitution values
S3_BUCKET=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")
CIRCUIT_BREAKER_LIMIT=$(kubectl_with_timeout 10 get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "10")

log "Starting triage cycle"

# ── Health Check 1: Active Jobs ───────────────────────────────────────────────
ACTIVE_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
FAILED_RECENT=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq --arg since "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)" \
  '[.items[] | select(.status.failed // 0 > 0 and .metadata.creationTimestamp > $since)] | length' 2>/dev/null || echo "0")

log "Active jobs: $ACTIVE_JOBS / $CIRCUIT_BREAKER_LIMIT"
log "Failed jobs (last 5min): $FAILED_RECENT"

# ── Health Check 2: Recent Thought CRs ────────────────────────────────────────
RECENT_THOUGHTS=$(kubectl get thoughts.kro.run -n "$NAMESPACE" -o json 2>/dev/null | \
  jq --arg since "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)" \
  '[.items[] | select(.metadata.creationTimestamp > $since)] | length' 2>/dev/null || echo "0")

log "Recent thoughts (last 5min): $RECENT_THOUGHTS"

# ── Health Check 3: Recent PR Activity ────────────────────────────────────────
if command -v gh &> /dev/null; then
  RECENT_PRS=$(gh pr list --repo "$REPO" --search "created:>=@5minutes" --json number 2>/dev/null | jq 'length' || echo "0")
  log "Recent PRs (last 5min): $RECENT_PRS"
else
  RECENT_PRS="?"
  log "gh CLI not available, skipping PR check"
fi

# ── Health Check 4: Coordinator State Consistency ─────────────────────────────
COORDINATOR_HEARTBEAT=$(kubectl_with_timeout 10 get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.lastHeartbeat}' 2>/dev/null || echo "")

if [ -n "$COORDINATOR_HEARTBEAT" ]; then
  HEARTBEAT_AGE=$(( $(date +%s) - $(date -d "$COORDINATOR_HEARTBEAT" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$COORDINATOR_HEARTBEAT" +%s 2>/dev/null || echo "0") ))
  log "Coordinator heartbeat age: ${HEARTBEAT_AGE}s"
  
  if [ "$HEARTBEAT_AGE" -gt 300 ]; then
    log "WARNING: Coordinator heartbeat is stale (${HEARTBEAT_AGE}s old)"
    COORDINATOR_STALE=1
  else
    COORDINATOR_STALE=0
  fi
else
  log "WARNING: No coordinator heartbeat found"
  COORDINATOR_STALE=1
fi

# ── Health Check 5: Stuck Jobs (running > 30 min) ─────────────────────────────
STUCK_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq --arg threshold "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" \
  '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0 and .status.startTime < $threshold)] | length' 2>/dev/null || echo "0")

log "Stuck jobs (running >30min): $STUCK_JOBS"

# ── Health Assessment ─────────────────────────────────────────────────────────
HEALTH_STATUS="HEALTHY"
DIAGNOSIS=""

# Critical: Circuit breaker activated
if [ "$ACTIVE_JOBS" -ge "$CIRCUIT_BREAKER_LIMIT" ]; then
  HEALTH_STATUS="CRITICAL"
  DIAGNOSIS="${DIAGNOSIS}Circuit breaker activated: ${ACTIVE_JOBS} active jobs >= ${CIRCUIT_BREAKER_LIMIT} limit. "
fi

# Critical: High failure rate
if [ "$FAILED_RECENT" -ge 3 ]; then
  HEALTH_STATUS="CRITICAL"
  DIAGNOSIS="${DIAGNOSIS}High failure rate: ${FAILED_RECENT} jobs failed in last 5 minutes. "
fi

# Degraded: Coordinator stale
if [ "$COORDINATOR_STALE" = "1" ]; then
  if [ "$HEALTH_STATUS" = "HEALTHY" ]; then HEALTH_STATUS="DEGRADED"; fi
  DIAGNOSIS="${DIAGNOSIS}Coordinator heartbeat stale or missing. "
fi

# Degraded: Stuck jobs
if [ "$STUCK_JOBS" -ge 1 ]; then
  if [ "$HEALTH_STATUS" = "HEALTHY" ]; then HEALTH_STATUS="DEGRADED"; fi
  DIAGNOSIS="${DIAGNOSIS}${STUCK_JOBS} jobs stuck (running >30min). "
fi

# Degraded: No activity
if [ "$RECENT_THOUGHTS" = "0" ] && [ "$RECENT_PRS" = "0" ] && [ "$ACTIVE_JOBS" -gt 0 ]; then
  if [ "$HEALTH_STATUS" = "HEALTHY" ]; then HEALTH_STATUS="DEGRADED"; fi
  DIAGNOSIS="${DIAGNOSIS}No thoughts or PRs in last 5 minutes despite active jobs. "
fi

log "Health status: $HEALTH_STATUS"
if [ -n "$DIAGNOSIS" ]; then
  log "Diagnosis: $DIAGNOSIS"
fi

# ── Post Diagnostic Thought CR ────────────────────────────────────────────────
if [ "$HEALTH_STATUS" != "HEALTHY" ]; then
  log "Posting diagnostic thought"
  
  kubectl_with_timeout 10 apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-${AGENT_NAME}
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  taskRef: "triage-cycle"
  thoughtType: observation
  confidence: 8
  topic: "system-health"
  content: |
    SYSTEM HEALTH: ${HEALTH_STATUS}
    
    Diagnosis: ${DIAGNOSIS}
    
    Metrics (last 5 min):
    - Active jobs: ${ACTIVE_JOBS} / ${CIRCUIT_BREAKER_LIMIT}
    - Failed jobs: ${FAILED_RECENT}
    - Stuck jobs (>30min): ${STUCK_JOBS}
    - Recent thoughts: ${RECENT_THOUGHTS}
    - Recent PRs: ${RECENT_PRS}
    - Coordinator heartbeat age: ${HEARTBEAT_AGE:-unknown}s
    
    Recommended actions:
$(if [ "$HEALTH_STATUS" = "CRITICAL" ]; then
  echo "    - Consider activating kill switch if proliferation detected"
  echo "    - Review failed job logs for crash patterns"
elif [ "$HEALTH_STATUS" = "DEGRADED" ]; then
  echo "    - Monitor for 5 more minutes"
  echo "    - Check coordinator logs if heartbeat remains stale"
  echo "    - Review stuck jobs for infinite loops"
fi)
EOF
  
  log "Diagnostic thought posted"
else
  log "System healthy, no action needed"
fi

log "Triage cycle complete"
exit 0
