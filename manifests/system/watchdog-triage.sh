#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# WATCHDOG TRIAGE — Tier 2 of the Multi-Tier Watchdog Chain
# Issue #1844: Multi-tier watchdog chain — detect and recover from failures
#
# AI Triage layer — runs every 5 minutes with fresh context.
# Checks system-level health conditions that require reading state
# across multiple resources (thoughts, jobs, coordinator state, PRs).
#
# Checks:
#   1. Agent progress (are thoughts/PRs being produced?)
#   2. Coordinator state consistency (counters match reality)
#   3. Unresolved escalations from Tier 1 (watchdog-state critical conditions)
#   4. Stale active assignments (agent claimed task but no progress)
#   5. Coordinator routing regression (routingCyclesWithZeroSpec)
#
# Actions:
#   - nudge: post a Thought CR nudging stuck agents
#   - diagnose: post detailed diagnosis Thought CR
#   - escalate: mark issue as critical and flag for Tier 3 (god-delegate)
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
TRIAGE_THOUGHT_WINDOW_MIN="${TRIAGE_THOUGHT_WINDOW_MIN:-5}"
TRIAGE_STALE_ASSIGNMENT_MIN="${TRIAGE_STALE_ASSIGNMENT_MIN:-60}"
TRIAGE_PR_WINDOW_HOURS="${TRIAGE_PR_WINDOW_HOURS:-2}"

DIAGNOSIS=""
SEVERITY="HEALTHY"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WATCHDOG-TRIAGE: $*"
}

append_diagnosis() {
  local msg="$1"
  DIAGNOSIS="${DIAGNOSIS}
  - ${msg}"
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

GITHUB_REPO=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.githubRepo}' 2>/dev/null || echo "pnz1990/agentex")

log "Starting triage (GITHUB_REPO=$GITHUB_REPO, CIRCUIT_BREAKER=$CIRCUIT_BREAKER_LIMIT)"

# ════════════════════════════════════════════════════════════════════════
# CHECK 1: Is Tier 1 watchdog reporting a critical state?
# ════════════════════════════════════════════════════════════════════════
log "--- CHECK 1: Tier 1 watchdog state ---"
WATCHDOG_STATE=$(kubectl get configmap watchdog-state -n "$NAMESPACE" \
  -o jsonpath='{.data.healthState}' 2>/dev/null || echo "UNKNOWN")
WATCHDOG_ISSUES=$(kubectl get configmap watchdog-state -n "$NAMESPACE" \
  -o jsonpath='{.data.issuesFound}' 2>/dev/null || echo "")
WATCHDOG_LAST_CHECK=$(kubectl get configmap watchdog-state -n "$NAMESPACE" \
  -o jsonpath='{.data.lastCheck}' 2>/dev/null || echo "unknown")

log "Tier 1 state: $WATCHDOG_STATE (last check: $WATCHDOG_LAST_CHECK)"

if [ "$WATCHDOG_STATE" = "CRITICAL" ]; then
  append_diagnosis "Tier 1 watchdog reported CRITICAL state at ${WATCHDOG_LAST_CHECK}"
  append_diagnosis "Tier 1 issues: ${WATCHDOG_ISSUES}"
  SEVERITY="CRITICAL"
elif [ "$WATCHDOG_STATE" = "DEGRADED" ]; then
  append_diagnosis "Tier 1 watchdog reported DEGRADED state at ${WATCHDOG_LAST_CHECK}"
  append_diagnosis "Tier 1 issues: ${WATCHDOG_ISSUES}"
  if [ "$SEVERITY" = "HEALTHY" ]; then SEVERITY="DEGRADED"; fi
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK 2: Agent progress — are Thought CRs being produced?
# ════════════════════════════════════════════════════════════════════════
log "--- CHECK 2: Agent activity (Thought CRs in last ${TRIAGE_THOUGHT_WINDOW_MIN}min) ---"

THOUGHT_WINDOW_START=$(date -u -d "${TRIAGE_THOUGHT_WINDOW_MIN} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
  date -u -v-${TRIAGE_THOUGHT_WINDOW_MIN}M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

ACTIVE_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' \
  2>/dev/null || echo "0")

if [ -n "$THOUGHT_WINDOW_START" ]; then
  RECENT_THOUGHTS=$(kubectl get configmaps -n "$NAMESPACE" -l agentex/thought -o json 2>/dev/null | \
    jq -r --arg since "$THOUGHT_WINDOW_START" \
    '[.items[] | select(.metadata.creationTimestamp > $since)] | length' \
    2>/dev/null || echo "0")

  log "Active jobs: $ACTIVE_JOBS, Recent thoughts (${TRIAGE_THOUGHT_WINDOW_MIN}min): $RECENT_THOUGHTS"

  if [ "$ACTIVE_JOBS" -gt 0 ] && [ "$RECENT_THOUGHTS" -eq 0 ]; then
    append_diagnosis "No Thought CRs in last ${TRIAGE_THOUGHT_WINDOW_MIN}min despite ${ACTIVE_JOBS} active jobs — agents may be stuck"
    if [ "$SEVERITY" = "HEALTHY" ]; then SEVERITY="DEGRADED"; fi
  elif [ "$RECENT_THOUGHTS" -gt 0 ]; then
    log "Agent activity normal: ${RECENT_THOUGHTS} thoughts in last ${TRIAGE_THOUGHT_WINDOW_MIN}min"
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK 3: Coordinator state consistency
# ════════════════════════════════════════════════════════════════════════
log "--- CHECK 3: Coordinator state consistency ---"

ACTIVE_ASSIGNMENTS=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.activeAssignments}' 2>/dev/null || echo "")
DEBATE_STATS=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.debateStats}' 2>/dev/null || echo "")
ROUTING_CYCLES_ZERO=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.routingCyclesWithZeroSpec}' 2>/dev/null || echo "0")
if ! [[ "$ROUTING_CYCLES_ZERO" =~ ^[0-9]+$ ]]; then ROUTING_CYCLES_ZERO=0; fi

# Check stale assignments (claimed but agent may have died)
if [ -n "$ACTIVE_ASSIGNMENTS" ]; then
  ASSIGNMENT_COUNT=$(echo "$ACTIVE_ASSIGNMENTS" | tr ',' '\n' | grep -c ':' 2>/dev/null || echo "0")
  log "Active assignments: $ASSIGNMENT_COUNT"

  if [ "$ASSIGNMENT_COUNT" -gt "$ACTIVE_JOBS" ]; then
    STALE_COUNT=$((ASSIGNMENT_COUNT - ACTIVE_JOBS))
    append_diagnosis "Potential stale assignments: ${ASSIGNMENT_COUNT} assignments but only ${ACTIVE_JOBS} active jobs (${STALE_COUNT} possibly orphaned)"
    if [ "$SEVERITY" = "HEALTHY" ]; then SEVERITY="DEGRADED"; fi
  fi
fi

# Check routing regression
if [ "$ROUTING_CYCLES_ZERO" -ge 5 ]; then
  append_diagnosis "Routing regression: ${ROUTING_CYCLES_ZERO} consecutive cycles with zero specialized assignments — specialization system may be broken"
  if [ "$SEVERITY" = "HEALTHY" ]; then SEVERITY="DEGRADED"; fi
fi

# Check debate stats (are they empty when they shouldn't be?)
if [ -z "$DEBATE_STATS" ] && [ "$ACTIVE_JOBS" -gt 0 ]; then
  append_diagnosis "Coordinator debate stats empty despite ${ACTIVE_JOBS} active agents — counter may have reset"
  # This is informational only (WARN not DEGRADED) since it's known issue
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK 4: Recent crash loop detection
# ════════════════════════════════════════════════════════════════════════
log "--- CHECK 4: Job failure rate ---"

# Count failed jobs in last 10 minutes
FAIL_WINDOW_START=$(date -u -d "10 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
  date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

if [ -n "$FAIL_WINDOW_START" ]; then
  RECENT_FAILURES=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
    jq -r --arg since "$FAIL_WINDOW_START" \
    '[.items[] |
      select(.status.failed != null and (.status.failed // 0) > 0) |
      select(.metadata.creationTimestamp > $since)] | length' \
    2>/dev/null || echo "0")

  log "Recent job failures (10min): $RECENT_FAILURES"
  if [ "$RECENT_FAILURES" -ge 5 ]; then
    append_diagnosis "High failure rate: ${RECENT_FAILURES} failed jobs in last 10 minutes — possible crash loop"
    SEVERITY="CRITICAL"
  elif [ "$RECENT_FAILURES" -ge 3 ]; then
    append_diagnosis "Elevated failure rate: ${RECENT_FAILURES} failed jobs in last 10 minutes"
    if [ "$SEVERITY" = "HEALTHY" ]; then SEVERITY="DEGRADED"; fi
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# POST TRIAGE THOUGHT CR (only for non-healthy states)
# ════════════════════════════════════════════════════════════════════════
TS=$(date +%s)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$SEVERITY" != "HEALTHY" ]; then
  log "Posting triage diagnosis Thought CR (severity: $SEVERITY)"

  THOUGHT_TYPE="insight"
  if [ "$SEVERITY" = "CRITICAL" ]; then
    THOUGHT_TYPE="blocker"
  fi

  kubectl apply -f - <<EOF 2>/dev/null || log "WARN: Failed to post triage thought CR"
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-watchdog-triage-${TS}
  namespace: ${NAMESPACE}
spec:
  agentRef: "watchdog-tier2"
  taskRef: "watchdog-triage"
  thoughtType: ${THOUGHT_TYPE}
  confidence: 9
  content: |
    WATCHDOG TIER 2 TRIAGE — ${SEVERITY}
    Timestamp: ${TIMESTAMP}
    Active jobs: ${ACTIVE_JOBS} / ${CIRCUIT_BREAKER_LIMIT}
    
    Diagnosis:
${DIAGNOSIS}
    
    Recommended actions for next agent:
    - Check coordinator state: kubectl get configmap coordinator-state -n ${NAMESPACE} -o yaml
    - Check stuck jobs: kubectl get jobs -n ${NAMESPACE}
    - Check watchdog tier 1 state: kubectl get configmap watchdog-state -n ${NAMESPACE} -o yaml
    - If CRITICAL: verify kill switch status and system stability before deactivating
EOF

  # Update watchdog state with triage result
  kubectl patch configmap watchdog-state -n "$NAMESPACE" \
    --type merge \
    -p "{\"data\":{\"lastTriageTimestamp\":\"${TIMESTAMP}\",\"lastTriageSeverity\":\"${SEVERITY}\"}}" \
    2>/dev/null || true

  log "Triage complete — severity: $SEVERITY"
else
  log "System healthy — no triage diagnosis needed"

  # Still update last triage timestamp
  kubectl patch configmap watchdog-state -n "$NAMESPACE" \
    --type merge \
    -p "{\"data\":{\"lastTriageTimestamp\":\"${TIMESTAMP}\",\"lastTriageSeverity\":\"HEALTHY\"}}" \
    2>/dev/null || true
fi

# Exit codes: 0=healthy, 1=degraded, 2=critical
case "$SEVERITY" in
  "HEALTHY") exit 0 ;;
  "DEGRADED") exit 1 ;;
  "CRITICAL") exit 2 ;;
  *) exit 0 ;;
esac
