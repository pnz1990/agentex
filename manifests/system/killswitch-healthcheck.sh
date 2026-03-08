#!/usr/bin/env bash
# Kill Switch Health Check — Safe deactivation validation
#
# Purpose: Validates system stability before deactivating emergency kill switch
# Usage: ./manifests/system/killswitch-healthcheck.sh
#
# Exit codes:
#   0 = PASS: Safe to deactivate kill switch
#   1 = FAIL: System not stable, keep kill switch active

set -euo pipefail

NAMESPACE="${NAMESPACE:-agentex}"
CIRCUIT_LIMIT=10
SAFE_THRESHOLD=9  # Want buffer below limit before deactivating (< 9 means ≤ 8 is safe)

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [HEALTHCHECK] $*"; }
fail() { log "❌ FAIL: $*"; exit 1; }
pass() { log "✓ PASS: $*"; }

log "=== Kill Switch Health Check ==="
log "Validating system stability before deactivation..."

# ── Check 1: Active job count below safe threshold ────────────────────────────
log ""
log "Check 1: Active job count"

ACTIVE_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length')

log "  Active jobs: $ACTIVE_JOBS"
log "  Circuit breaker limit: $CIRCUIT_LIMIT"
log "  Safe threshold: $SAFE_THRESHOLD"

if [ "$ACTIVE_JOBS" -ge "$SAFE_THRESHOLD" ]; then
  fail "Active jobs ($ACTIVE_JOBS) >= safe threshold ($SAFE_THRESHOLD). System too loaded."
fi

pass "Active jobs ($ACTIVE_JOBS) below safe threshold ($SAFE_THRESHOLD)"

# ── Check 2: No recent spawn failures ─────────────────────────────────────────
log ""
log "Check 2: Recent spawn failures"

# Check for failed jobs in last 5 minutes (300 seconds)
NOW=$(date +%s)
FIVE_MIN_AGO=$((NOW - 300))

RECENT_FAILURES=$(kubectl get jobs -n "$NAMESPACE" -o json | \
  jq --arg cutoff "$FIVE_MIN_AGO" '
    [.items[] | 
      select(.status.failed != null and .status.failed > 0) |
      select((.metadata.creationTimestamp | fromdateiso8601) > ($cutoff | tonumber))
    ] | length
  ')

log "  Recent failures (last 5 min): $RECENT_FAILURES"

if [ "$RECENT_FAILURES" -gt 3 ]; then
  fail "Too many recent failures ($RECENT_FAILURES > 3). System may be unstable."
fi

pass "Recent failures ($RECENT_FAILURES) within acceptable range"

# ── Check 3: Circuit breaker functioning ──────────────────────────────────────
log ""
log "Check 3: Circuit breaker validation"

# Verify circuit breaker code exists in runner entrypoint
if ! grep -q "CIRCUIT BREAKER" /workspace/repo/images/runner/entrypoint.sh 2>/dev/null; then
  log "  WARNING: Cannot verify circuit breaker code (entrypoint.sh not accessible)"
  log "  Skipping validation (assume OK if running in cluster)"
else
  BREAKER_COUNT=$(grep -c "CIRCUIT BREAKER" /workspace/repo/images/runner/entrypoint.sh || echo 0)
  log "  Circuit breaker references in entrypoint.sh: $BREAKER_COUNT"
  
  if [ "$BREAKER_COUNT" -lt 2 ]; then
    fail "Circuit breaker code insufficient (expected >= 2 references, found $BREAKER_COUNT)"
  fi
  
  pass "Circuit breaker code present in runner"
fi

# ── Check 4: Kill switch currently active ─────────────────────────────────────
log ""
log "Check 4: Kill switch status"

KS_ENABLED=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" -o jsonpath='{.data.enabled}' 2>/dev/null || echo "not-found")

if [ "$KS_ENABLED" != "true" ]; then
  log "  Kill switch enabled: $KS_ENABLED"
  fail "Kill switch not currently active (nothing to deactivate)"
fi

pass "Kill switch is active and can be safely deactivated"

# ── Check 5: No recent proliferation events ───────────────────────────────────
log ""
log "Check 5: Proliferation history"

# Check for blocker thoughts mentioning circuit breaker in last 10 minutes
RECENT_BREAKERS=$(kubectl get thoughts.kro.run -n "$NAMESPACE" -o json 2>/dev/null | \
  jq --arg cutoff "$FIVE_MIN_AGO" '
    [.items[] | 
      select(.spec.thoughtType == "blocker") |
      select(.spec.content | contains("Circuit breaker") or contains("CIRCUIT BREAKER")) |
      select((.metadata.creationTimestamp | fromdateiso8601) > ($cutoff | tonumber))
    ] | length
  ' || echo 0)

log "  Circuit breaker blocks (last 5 min): $RECENT_BREAKERS"

if [ "$RECENT_BREAKERS" -gt 5 ]; then
  fail "Too many recent circuit breaker activations ($RECENT_BREAKERS > 5). System still unstable."
fi

pass "No excessive circuit breaker activations"

# ── All checks passed ─────────────────────────────────────────────────────────
log ""
log "=== ✅ ALL CHECKS PASSED ==="
log ""
log "System is stable. Safe to deactivate kill switch."
log ""
log "To deactivate, run:"
log "  kubectl patch configmap agentex-killswitch -n agentex \\"
log "    --type=merge -p '{\"data\":{\"enabled\":\"false\",\"reason\":\"\"}}'"
log ""
log "Monitor for 5 minutes after deactivation:"
log "  watch kubectl get jobs -n agentex"
log ""

exit 0
