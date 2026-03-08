#!/bin/bash
# System Status Dashboard
# Quick health check for agentex civilization
# Usage: ./system-status.sh

set -euo pipefail

NAMESPACE="agentex"

# Read circuit breaker limit from constitution (do not hardcode!)
CIRCUIT_BREAKER_LIMIT=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "15")
if ! [[ "$CIRCUIT_BREAKER_LIMIT" =~ ^[0-9]+$ ]]; then CIRCUIT_BREAKER_LIMIT=15; fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║        AGENTEX CIVILIZATION STATUS DASHBOARD              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# 1. CIRCUIT BREAKER STATUS
echo -e "${BLUE}🔒 Circuit Breaker${NC}"
ACTIVE_JOBS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")

if [ "$ACTIVE_JOBS" -ge "$CIRCUIT_BREAKER_LIMIT" ]; then
  echo -e "   Status: ${RED}ACTIVATED${NC} (system overloaded)"
else
  PERCENT=$((ACTIVE_JOBS * 100 / CIRCUIT_BREAKER_LIMIT))
  if [ "$PERCENT" -gt 80 ]; then
    echo -e "   Status: ${YELLOW}WARNING${NC} (${PERCENT}% capacity)"
  else
    echo -e "   Status: ${GREEN}OK${NC} (${PERCENT}% capacity)"
  fi
fi
echo "   Active jobs: $ACTIVE_JOBS / $CIRCUIT_BREAKER_LIMIT"
echo ""

# 2. KILL SWITCH STATUS
echo -e "${BLUE}🛑 Kill Switch${NC}"
KILLSWITCH_ENABLED=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
  -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
if [ "$KILLSWITCH_ENABLED" = "true" ]; then
  KILLSWITCH_REASON=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
    -o jsonpath='{.data.reason}' 2>/dev/null || echo "")
  echo -e "   Status: ${RED}ACTIVE${NC} (all spawning blocked)"
  echo "   Reason: $KILLSWITCH_REASON"
else
  echo -e "   Status: ${GREEN}INACTIVE${NC} (normal operation)"
fi
echo ""

# 3. RECENT AGENT ACTIVITY
echo -e "${BLUE}👥 Recent Agent Activity (last 10 minutes)${NC}"
RECENT_AGENTS=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq -r --arg since "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)" \
  '[.items[] | select(.metadata.creationTimestamp > $since)] | length' 2>/dev/null || echo "0")
echo "   Agents spawned: $RECENT_AGENTS"

COMPLETED_RECENT=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | \
  jq -r --arg since "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)" \
  '[.items[] | select(.status.completionTime > $since)] | length' 2>/dev/null || echo "0")
echo "   Agents completed: $COMPLETED_RECENT"
echo ""

# 4. ROLE DISTRIBUTION
echo -e "${BLUE}🎭 Current Roles${NC}"
PLANNERS=$(kubectl get jobs -n "$NAMESPACE" -l role=planner -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
WORKERS=$(kubectl get jobs -n "$NAMESPACE" -l role=worker -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
ARCHITECTS=$(kubectl get jobs -n "$NAMESPACE" -l role=architect -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")
REVIEWERS=$(kubectl get jobs -n "$NAMESPACE" -l role=reviewer -o json 2>/dev/null | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length' 2>/dev/null || echo "0")

echo "   Planners:   $PLANNERS"
echo "   Workers:    $WORKERS"
echo "   Architects: $ARCHITECTS"
echo "   Reviewers:  $REVIEWERS"
echo ""

# 5. RECENT THOUGHTS
echo -e "${BLUE}💭 Recent Thoughts (last 5)${NC}"
kubectl get thoughts.kro.run -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp 2>/dev/null | \
  tail -6 | tail -5 | awk '{printf "   %s [%s] %s\n", $1, $3, $4}' 2>/dev/null || echo "   (none)"
echo ""

# 6. OPEN GITHUB ISSUES/PRS
echo -e "${BLUE}🔧 GitHub Status${NC}"
if command -v gh &> /dev/null; then
  OPEN_PRS=$(gh pr list --repo pnz1990/agentex --state open --limit 100 --json number 2>/dev/null | jq 'length' || echo "?")
  OPEN_ISSUES=$(gh issue list --repo pnz1990/agentex --state open --limit 100 --json number 2>/dev/null | jq 'length' || echo "?")
  echo "   Open PRs: $OPEN_PRS"
  echo "   Open Issues: $OPEN_ISSUES"
else
  echo "   (gh CLI not available)"
fi
echo ""

# 7. CONSTITUTION VALUES
echo -e "${BLUE}📜 Constitution${NC}"
VISION=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.vision}' 2>/dev/null | head -c 60 || echo "(not set)")
GENERATION=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.civilizationGeneration}' 2>/dev/null || echo "?")
echo "   Vision: ${VISION}..."
echo "   Generation: $GENERATION"
echo ""

# 8. HEALTH SUMMARY
echo -e "${BLUE}📊 Health Summary${NC}"
HEALTH_OK=0
HEALTH_WARN=0
HEALTH_CRIT=0

# Check circuit breaker
if [ "$ACTIVE_JOBS" -ge "$CIRCUIT_BREAKER_LIMIT" ]; then
  HEALTH_CRIT=$((HEALTH_CRIT + 1))
  echo -e "   ${RED}✗${NC} Circuit breaker activated"
elif [ "$ACTIVE_JOBS" -gt $((CIRCUIT_BREAKER_LIMIT * 80 / 100)) ]; then
  HEALTH_WARN=$((HEALTH_WARN + 1))
  echo -e "   ${YELLOW}⚠${NC} Circuit breaker at >80% capacity"
else
  HEALTH_OK=$((HEALTH_OK + 1))
  echo -e "   ${GREEN}✓${NC} Circuit breaker healthy"
fi

# Check kill switch
if [ "$KILLSWITCH_ENABLED" = "true" ]; then
  HEALTH_CRIT=$((HEALTH_CRIT + 1))
  echo -e "   ${RED}✗${NC} Kill switch active"
else
  HEALTH_OK=$((HEALTH_OK + 1))
  echo -e "   ${GREEN}✓${NC} Kill switch inactive"
fi

# Check proliferation pattern
if [ "$RECENT_AGENTS" -gt 30 ]; then
  HEALTH_CRIT=$((HEALTH_CRIT + 1))
  echo -e "   ${RED}✗${NC} Proliferation detected (${RECENT_AGENTS} agents in 10min)"
elif [ "$RECENT_AGENTS" -gt 20 ]; then
  HEALTH_WARN=$((HEALTH_WARN + 1))
  echo -e "   ${YELLOW}⚠${NC} High spawn rate (${RECENT_AGENTS} agents in 10min)"
else
  HEALTH_OK=$((HEALTH_OK + 1))
  echo -e "   ${GREEN}✓${NC} Spawn rate normal"
fi

echo ""
if [ "$HEALTH_CRIT" -gt 0 ]; then
  echo -e "Overall: ${RED}CRITICAL${NC} - Immediate attention required"
  exit 2
elif [ "$HEALTH_WARN" -gt 0 ]; then
  echo -e "Overall: ${YELLOW}WARNING${NC} - Monitor closely"
  exit 1
else
  echo -e "Overall: ${GREEN}HEALTHY${NC} - System operating normally"
  exit 0
fi
