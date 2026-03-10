#!/bin/bash
# System Status Dashboard
# Quick health check for agentex civilization
# Usage: ./system-status.sh

set -euo pipefail

NAMESPACE="agentex"

# Read GitHub repo from constitution (do not hardcode!)
REPO=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.githubRepo}' 2>/dev/null)
if [ -z "$REPO" ]; then REPO="${GITHUB_REPO:-pnz1990/agentex}"; fi

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

# 4b. WATCHDOG CHAIN STATUS (issue #1844)
echo -e "${BLUE}🔍 Watchdog Chain Status${NC}"
WATCHDOG_STATE_VAL=$(kubectl get configmap watchdog-state -n "$NAMESPACE" \
  -o jsonpath='{.data.healthState}' 2>/dev/null || echo "")
WATCHDOG_LAST_CHECK=$(kubectl get configmap watchdog-state -n "$NAMESPACE" \
  -o jsonpath='{.data.lastCheck}' 2>/dev/null || echo "")
WATCHDOG_TRIAGE_SEVERITY=$(kubectl get configmap watchdog-state -n "$NAMESPACE" \
  -o jsonpath='{.data.lastTriageSeverity}' 2>/dev/null || echo "")
WATCHDOG_TRIAGE_TS=$(kubectl get configmap watchdog-state -n "$NAMESPACE" \
  -o jsonpath='{.data.lastTriageTimestamp}' 2>/dev/null || echo "")
WATCHDOG_STUCK=$(kubectl get configmap watchdog-state -n "$NAMESPACE" \
  -o jsonpath='{.data.stuckJobCount}' 2>/dev/null || echo "0")
WATCHDOG_ISSUES=$(kubectl get configmap watchdog-state -n "$NAMESPACE" \
  -o jsonpath='{.data.issuesFound}' 2>/dev/null || echo "none")

if [ -z "$WATCHDOG_STATE_VAL" ]; then
  echo -e "   Tier 1 Heartbeat:  ${YELLOW}NOT DEPLOYED${NC} (apply manifests/system/watchdog-cronjob.yaml)"
  echo -e "   Tier 2 Triage:     ${YELLOW}NOT DEPLOYED${NC} (apply manifests/system/watchdog-triage-cronjob.yaml)"
else
  case "$WATCHDOG_STATE_VAL" in
    HEALTHY)   echo -e "   Tier 1 Heartbeat:  ${GREEN}HEALTHY${NC} (last check: $WATCHDOG_LAST_CHECK)" ;;
    DEGRADED)  echo -e "   Tier 1 Heartbeat:  ${YELLOW}DEGRADED${NC} (last check: $WATCHDOG_LAST_CHECK)" ;;
    CRITICAL)  echo -e "   Tier 1 Heartbeat:  ${RED}CRITICAL${NC} (last check: $WATCHDOG_LAST_CHECK)" ;;
    RECOVERING) echo -e "   Tier 1 Heartbeat:  ${YELLOW}RECOVERING${NC} (last check: $WATCHDOG_LAST_CHECK)" ;;
    *)         echo -e "   Tier 1 Heartbeat:  ${YELLOW}${WATCHDOG_STATE_VAL}${NC} (last check: $WATCHDOG_LAST_CHECK)" ;;
  esac
  echo "   Stuck jobs: $WATCHDOG_STUCK"
  if [ "$WATCHDOG_ISSUES" != "none" ] && [ -n "$WATCHDOG_ISSUES" ]; then
    echo "   Issues: $WATCHDOG_ISSUES" | head -c 200
  fi

  if [ -z "$WATCHDOG_TRIAGE_SEVERITY" ] || [ "$WATCHDOG_TRIAGE_SEVERITY" = "UNKNOWN" ]; then
    echo -e "   Tier 2 Triage:     ${YELLOW}NOT YET RUN${NC} (apply manifests/system/watchdog-triage-cronjob.yaml)"
  else
    case "$WATCHDOG_TRIAGE_SEVERITY" in
      HEALTHY)   echo -e "   Tier 2 Triage:     ${GREEN}HEALTHY${NC} (last: $WATCHDOG_TRIAGE_TS)" ;;
      DEGRADED)  echo -e "   Tier 2 Triage:     ${YELLOW}DEGRADED${NC} (last: $WATCHDOG_TRIAGE_TS)" ;;
      CRITICAL)  echo -e "   Tier 2 Triage:     ${RED}CRITICAL${NC} (last: $WATCHDOG_TRIAGE_TS)" ;;
      *)         echo -e "   Tier 2 Triage:     ${YELLOW}${WATCHDOG_TRIAGE_SEVERITY}${NC} (last: $WATCHDOG_TRIAGE_TS)" ;;
    esac
  fi
fi
echo ""

# 5. RECENT THOUGHTS
echo -e "${BLUE}💭 Recent Thoughts (last 5)${NC}"
kubectl get thoughts.kro.run -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp 2>/dev/null | \
  tail -6 | tail -5 | awk '{printf "   %s [%s] %s\n", $1, $3, $4}' 2>/dev/null || echo "   (none)"
echo ""

# 5a. MILESTONE PROGRESS
echo -e "${BLUE}🏆 Milestone Progress${NC}"
V05_STATUS=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.v05MilestoneStatus}' 2>/dev/null || echo "")
V05_CRITERIA=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.v05CriteriaStatus}' 2>/dev/null || echo "")
V06_STATUS=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.v06MilestoneStatus}' 2>/dev/null || echo "")
V06_CRITERIA=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.v06CriteriaStatus}' 2>/dev/null || echo "")

if [ "$V05_STATUS" = "completed" ]; then
  echo -e "   v0.5 Emergent Specialization: ${GREEN}COMPLETE${NC}"
elif [ -n "$V05_CRITERIA" ]; then
  echo -e "   v0.5 Emergent Specialization: ${YELLOW}IN PROGRESS${NC}"
  echo "   Progress: $V05_CRITERIA"
else
  echo -e "   v0.5 Emergent Specialization: ${YELLOW}not yet initialized${NC}"
fi

if [ "$V06_STATUS" = "completed" ]; then
  echo -e "   v0.6 Collective Action:       ${GREEN}COMPLETE${NC}"
elif [ -n "$V06_CRITERIA" ]; then
  echo -e "   v0.6 Collective Action:       ${YELLOW}IN PROGRESS${NC}"
  echo "   Progress: $V06_CRITERIA"
else
  echo -e "   v0.6 Collective Action:       ${YELLOW}not yet initialized${NC}"
fi
echo ""

# 5b. COORDINATOR & GOVERNANCE HEALTH
echo -e "${BLUE}🏛️  Coordinator & Governance Health${NC}"

# Coordinator heartbeat age
COORD_HEARTBEAT=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.lastHeartbeat}' 2>/dev/null || echo "")
COORD_PHASE=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.phase}' 2>/dev/null || echo "unknown")

if [ -n "$COORD_HEARTBEAT" ]; then
  # Calculate age in seconds
  NOW_EPOCH=$(date -u +%s 2>/dev/null || echo "0")
  HB_EPOCH=$(date -u -d "$COORD_HEARTBEAT" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$COORD_HEARTBEAT" +%s 2>/dev/null || echo "0")
  HEARTBEAT_AGE=$(( NOW_EPOCH - HB_EPOCH ))
  HEARTBEAT_MIN=$(( HEARTBEAT_AGE / 60 ))
  if [ "$HEARTBEAT_AGE" -gt 300 ]; then
    echo -e "   Coordinator: ${RED}STALE${NC} (last heartbeat ${HEARTBEAT_MIN}m ago — may be down)"
  elif [ "$HEARTBEAT_AGE" -gt 120 ]; then
    echo -e "   Coordinator: ${YELLOW}SLOW${NC} (last heartbeat ${HEARTBEAT_MIN}m ago) phase=${COORD_PHASE}"
  else
    echo -e "   Coordinator: ${GREEN}ALIVE${NC} (heartbeat ${HEARTBEAT_AGE}s ago) phase=${COORD_PHASE}"
  fi
else
  echo -e "   Coordinator: ${YELLOW}UNKNOWN${NC} (no heartbeat recorded)"
fi

# Debate health stats
DEBATE_STATS=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.debateStats}' 2>/dev/null || echo "")
if [ -n "$DEBATE_STATS" ]; then
  echo "   Debate stats: $DEBATE_STATS"
else
  echo "   Debate stats: (none yet)"
fi

# Unresolved debates count
UNRESOLVED_RAW=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.unresolvedDebates}' 2>/dev/null || echo "")
if [ -n "$UNRESOLVED_RAW" ]; then
  UNRESOLVED_COUNT=$(echo "$UNRESOLVED_RAW" | tr ',' '\n' | grep -c '.' 2>/dev/null || echo "0")
else
  UNRESOLVED_COUNT=0
fi
if [ "$UNRESOLVED_COUNT" -gt 20 ]; then
  echo -e "   Unresolved debates: ${RED}${UNRESOLVED_COUNT}${NC} (backlog high)"
elif [ "$UNRESOLVED_COUNT" -gt 5 ]; then
  echo -e "   Unresolved debates: ${YELLOW}${UNRESOLVED_COUNT}${NC}"
else
  echo -e "   Unresolved debates: ${GREEN}${UNRESOLVED_COUNT}${NC}"
fi

# Specialization routing ratio
SPEC_ASSIGN=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.specializedAssignments}' 2>/dev/null || echo "0")
GEN_ASSIGN=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.genericAssignments}' 2>/dev/null || echo "0")
SPEC_ASSIGN=${SPEC_ASSIGN:-0}
GEN_ASSIGN=${GEN_ASSIGN:-0}
TOTAL_ASSIGN=$(( SPEC_ASSIGN + GEN_ASSIGN ))
if [ "$TOTAL_ASSIGN" -gt 0 ]; then
  SPEC_PCT=$(( SPEC_ASSIGN * 100 / TOTAL_ASSIGN ))
  if [ "$SPEC_PCT" -ge 30 ]; then
    echo -e "   Routing: ${GREEN}${SPEC_PCT}% specialized${NC} (${SPEC_ASSIGN} spec / ${GEN_ASSIGN} generic)"
  else
    echo -e "   Routing: ${YELLOW}${SPEC_PCT}% specialized${NC} (${SPEC_ASSIGN} spec / ${GEN_ASSIGN} generic — v0.2 routing may be stalled)"
  fi
else
  echo "   Routing: no assignments recorded yet"
fi

# Vision queue length
VISION_QUEUE=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.visionQueue}' 2>/dev/null || echo "")
if [ -n "$VISION_QUEUE" ]; then
  VQ_COUNT=$(echo "$VISION_QUEUE" | tr ';' '\n' | grep -c '.' 2>/dev/null || echo "0")
  echo -e "   Vision queue: ${GREEN}${VQ_COUNT} item(s)${NC} — civilization self-directed goals active"
else
  echo "   Vision queue: (empty — no civilization goals voted in yet)"
fi
echo ""

# 6. OPEN GITHUB ISSUES/PRS
echo -e "${BLUE}🔧 GitHub Status${NC}"
if command -v gh &> /dev/null; then
  OPEN_PRS=$(gh pr list --repo "$REPO" --state open --limit 100 --json number 2>/dev/null | jq 'length' || echo "?")
  OPEN_ISSUES=$(gh issue list --repo "$REPO" --state open --limit 100 --json number 2>/dev/null | jq 'length' || echo "?")
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

# Check coordinator heartbeat
if [ -n "${HEARTBEAT_AGE:-}" ]; then
  if [ "$HEARTBEAT_AGE" -gt 300 ]; then
    HEALTH_WARN=$((HEALTH_WARN + 1))
    echo -e "   ${YELLOW}⚠${NC} Coordinator heartbeat stale (${HEARTBEAT_AGE}s ago)"
  else
    HEALTH_OK=$((HEALTH_OK + 1))
    echo -e "   ${GREEN}✓${NC} Coordinator alive"
  fi
fi

# Check watchdog chain state (issue #1844)
if [ -n "${WATCHDOG_STATE_VAL:-}" ]; then
  case "${WATCHDOG_STATE_VAL:-}" in
    HEALTHY)
      HEALTH_OK=$((HEALTH_OK + 1))
      echo -e "   ${GREEN}✓${NC} Watchdog chain healthy"
      ;;
    DEGRADED)
      HEALTH_WARN=$((HEALTH_WARN + 1))
      echo -e "   ${YELLOW}⚠${NC} Watchdog chain: DEGRADED"
      ;;
    CRITICAL)
      HEALTH_CRIT=$((HEALTH_CRIT + 1))
      echo -e "   ${RED}✗${NC} Watchdog chain: CRITICAL"
      ;;
    UNKNOWN)
      echo -e "   ${YELLOW}?${NC} Watchdog chain: not yet initialized"
      ;;
  esac
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
