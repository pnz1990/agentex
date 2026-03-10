#!/usr/bin/env bash
# verify-v06-features.sh
# Verifies that v0.6 Collective Action features are working after coordinator restart
#
# Usage: ./verify-v06-features.sh
#
# Checks:
# A. Coordinator state fields initialized (v06MilestoneStatus, v06CriteriaStatus, activeSwarms)
# B. v0.6 success criteria from check_v06_milestone() in coordinator.sh:
#    1. Spontaneous swarm formations recorded in S3 (swarmFormationCount >= 2)
#    2. Max coalition size in any swarm >= 3 (coalitionSize >= 3)
#    3. Agent-proposed goals pursued (emergentGoalCount >= 1)
#    4. Swarm summaries written to S3 on dissolution (swarmMemoryCount >= 1)
#
# Note: Criteria thresholds match check_v06_milestone() in coordinator.sh (issue #1789).
#
# Exit codes:
#   0 = all criteria met
#   1 = some criteria not yet met or coordinator fields not initialized

set -euo pipefail

NAMESPACE="agentex"
S3_BUCKET=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")

echo "=== v0.6 Collective Action Feature Verification ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "S3 bucket: ${S3_BUCKET}"
echo ""

checks_passed=0
checks_total=0

# ── Section A: Coordinator state field initialization ───────────────────────
echo "--- Section A: Coordinator State Fields ---"
echo ""

# A.1: v06MilestoneStatus field exists
((checks_total++))
echo "[A.1] Checking v06MilestoneStatus field in coordinator-state..."
v06_milestone=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.v06MilestoneStatus}' 2>/dev/null || echo "__MISSING__")
if [ "$v06_milestone" = "__MISSING__" ]; then
  echo "  ✗ FAIL: v06MilestoneStatus field not found in coordinator-state"
  echo "    Fix: Apply PR for issue #1789 (add check_v06_milestone to coordinator.sh)"
  echo "    Or: kubectl patch configmap coordinator-state -n agentex --type=merge -p '{\"data\":{\"v06MilestoneStatus\":\"\"}}'"
else
  if [ "$v06_milestone" = "completed" ]; then
    echo "  ✓ PASS: v06MilestoneStatus = 'completed' — milestone already achieved!"
  else
    echo "  ✓ PASS: v06MilestoneStatus field exists (value: '${v06_milestone:-<empty>}')"
  fi
  ((checks_passed++))
fi
echo ""

# A.2: v06CriteriaStatus field exists
((checks_total++))
echo "[A.2] Checking v06CriteriaStatus field in coordinator-state..."
v06_criteria=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.v06CriteriaStatus}' 2>/dev/null || echo "__MISSING__")
if [ "$v06_criteria" = "__MISSING__" ]; then
  echo "  ✗ FAIL: v06CriteriaStatus field not found in coordinator-state"
  echo "    Fix: Apply PR for issue #1789 (add check_v06_milestone to coordinator.sh)"
else
  if [ -n "$v06_criteria" ]; then
    echo "  ✓ PASS: v06CriteriaStatus populated: ${v06_criteria}"
  else
    echo "  ✓ PASS: v06CriteriaStatus field exists (not yet populated — check_v06_milestone hasn't run)"
  fi
  ((checks_passed++))
fi
echo ""

# A.3: activeSwarms field exists
((checks_total++))
echo "[A.3] Checking activeSwarms field in coordinator-state..."
active_swarms=$(kubectl get configmap coordinator-state -n "$NAMESPACE" \
  -o jsonpath='{.data.activeSwarms}' 2>/dev/null || echo "__MISSING__")
if [ "$active_swarms" = "__MISSING__" ]; then
  echo "  ✗ FAIL: activeSwarms field not found in coordinator-state"
  echo "    Fix: Apply PR for issue #1775 (activeSwarms tracking)"
  echo "    Or: kubectl patch configmap coordinator-state -n agentex --type=merge -p '{\"data\":{\"activeSwarms\":\"\"}}'"
else
  if [ -n "$active_swarms" ]; then
    swarm_count=$(echo "$active_swarms" | tr '|' '\n' | grep -c '.' 2>/dev/null || echo "0")
    echo "  ✓ PASS: activeSwarms field exists — ${swarm_count} active swarm(s): ${active_swarms}"
  else
    echo "  ✓ PASS: activeSwarms field exists (empty — no active swarms)"
  fi
  ((checks_passed++))
fi
echo ""

# ── Section B: v0.6 Success Criteria ─────────────────────────────────────────
echo "--- Section B: v0.6 Success Criteria ---"
echo "Note: criteria thresholds match coordinator.sh check_v06_milestone() (issue #1789)"
echo ""

criteria_met=0
criteria_total=4

# Read swarm dissolution records from S3
# Note: helpers.sh (PR #1779) and entrypoint.sh write to s3://<bucket>/swarm-memories/<name>.json
# coordinator.sh (PR #1793) also writes to swarm-memories/ path
# check_v06_milestone (PR #1794) reads from swarms/ — see issue noted in verify script
echo "[B] Reading S3 swarm records from s3://${S3_BUCKET}/swarm-memories/ ..."
swarm_files_main=$(aws s3 ls "s3://${S3_BUCKET}/swarm-memories/" 2>/dev/null | awk '{print $4}' || echo "")

# Also check legacy/alternate path 'swarms/' in case check_v06_milestone uses it
echo "[B] Also checking s3://${S3_BUCKET}/swarms/ (alternate path used by check_v06_milestone)..."
swarm_files_alt=$(aws s3 ls "s3://${S3_BUCKET}/swarms/" 2>/dev/null | awk '{print $4}' || echo "")

swarm_memory_count=0
max_coalition_size=0
emergent_goal_count=0
swarm_formation_count=0

# Process records from primary path (swarm-memories/)
if [ -n "$swarm_files_main" ]; then
  while IFS= read -r sfile; do
    [ -z "$sfile" ] && continue
    sjson=$(aws s3 cp "s3://${S3_BUCKET}/swarm-memories/${sfile}" - 2>/dev/null || echo "")
    [ -z "$sjson" ] && continue

    swarm_memory_count=$((swarm_memory_count + 1))
    swarm_formation_count=$((swarm_formation_count + 1))

    # Check coalition size
    member_count=$(echo "$sjson" | jq -r '(.members // []) | length' 2>/dev/null || echo "0")
    [[ "$member_count" =~ ^[0-9]+$ ]] || member_count=0
    if [ "$member_count" -gt "$max_coalition_size" ]; then
      max_coalition_size=$member_count
    fi

    # Check for emergent goals
    goal_origin=$(echo "$sjson" | jq -r '.goalOrigin // ""' 2>/dev/null || echo "")
    if [ "$goal_origin" = "agent-proposed" ] || [ "$goal_origin" = "emergent" ]; then
      emergent_goal_count=$((emergent_goal_count + 1))
    fi

    swarm_name=$(echo "$sjson" | jq -r '.swarmName // "unknown"' 2>/dev/null || echo "unknown")
    echo "  Found swarm memory: ${swarm_name} (members=${member_count}, goalOrigin=${goal_origin:-unset})"
  done <<< "$swarm_files_main"
fi

# Process records from alternate path (swarms/)
if [ -n "$swarm_files_alt" ]; then
  while IFS= read -r sfile; do
    [ -z "$sfile" ] && continue
    sjson=$(aws s3 cp "s3://${S3_BUCKET}/swarms/${sfile}" - 2>/dev/null || echo "")
    [ -z "$sjson" ] && continue

    swarm_memory_count=$((swarm_memory_count + 1))
    swarm_formation_count=$((swarm_formation_count + 1))

    member_count=$(echo "$sjson" | jq -r '(.members // (.memberAgents // [])) | length' 2>/dev/null || echo "0")
    [[ "$member_count" =~ ^[0-9]+$ ]] || member_count=0
    if [ "$member_count" -gt "$max_coalition_size" ]; then
      max_coalition_size=$member_count
    fi

    goal_origin=$(echo "$sjson" | jq -r '.goalOrigin // ""' 2>/dev/null || echo "")
    if [ "$goal_origin" = "agent-proposed" ] || [ "$goal_origin" = "emergent" ]; then
      emergent_goal_count=$((emergent_goal_count + 1))
    fi

    swarm_name=$(echo "$sjson" | jq -r '.swarmName // "unknown"' 2>/dev/null || echo "unknown")
    echo "  Found swarm record (alt path): ${swarm_name} (members=${member_count}, goalOrigin=${goal_origin:-unset})"
  done <<< "$swarm_files_alt"
fi

# Also count live swarms from activeSwarms for formation count
if [ -n "$active_swarms" ]; then
  live_count=$(echo "$active_swarms" | tr '|' '\n' | grep -c '.' 2>/dev/null || echo "0")
  echo "  Plus ${live_count} live swarm(s) from activeSwarms field"
  swarm_formation_count=$((swarm_formation_count + live_count))

  # Check coalition sizes from live swarm state ConfigMaps
  while IFS=':' read -r swarm_name _rest; do
    [ -z "$swarm_name" ] && continue
    live_members=$(kubectl get configmap "${swarm_name}-state" \
      -n "$NAMESPACE" -o jsonpath='{.data.memberAgents}' 2>/dev/null | \
      tr ',' '\n' | grep -c '.' 2>/dev/null || echo "0")
    [[ "$live_members" =~ ^[0-9]+$ ]] || live_members=0
    if [ "$live_members" -gt "$max_coalition_size" ]; then
      max_coalition_size=$live_members
    fi
    echo "  Live swarm ${swarm_name}: ${live_members} member(s)"
  done < <(echo "$active_swarms" | tr '|' '\n' | grep -v '^$' || true)
fi

echo ""
echo "[B.summary] Swarm data: formations=${swarm_formation_count} maxCoalition=${max_coalition_size} emergentGoals=${emergent_goal_count} memoryRecords=${swarm_memory_count}"
echo ""

# Criterion B.1: 2+ swarm formations
echo "[B.1] Checking swarm formation count (need >= 2, found ${swarm_formation_count})..."
if [ "$swarm_formation_count" -ge 2 ]; then
  echo "  ✓ PASS: ${swarm_formation_count} swarm formations recorded"
  ((criteria_met++))
else
  echo "  ✗ NOT YET: Only ${swarm_formation_count}/2 swarm formations recorded"
  echo "    Hint: Coordinator spawns swarms for eligible multi-domain issues (PR #1786)"
  echo "    Or: Create a Swarm CR manually to test"
fi
echo ""

# Criterion B.2: Max coalition size >= 3
echo "[B.2] Checking max coalition size (need >= 3, found ${max_coalition_size})..."
if [ "$max_coalition_size" -ge 3 ]; then
  echo "  ✓ PASS: Max coalition size is ${max_coalition_size} agents"
  ((criteria_met++))
else
  echo "  ✗ NOT YET: Max coalition size is ${max_coalition_size}/3"
  echo "    Hint: Swarms need 3+ member agents. Check that workers join swarms via SWARM_REF"
fi
echo ""

# Criterion B.3: Agent-proposed goals
echo "[B.3] Checking emergent/agent-proposed goals pursued (need >= 1, found ${emergent_goal_count})..."
if [ "$emergent_goal_count" -ge 1 ]; then
  echo "  ✓ PASS: ${emergent_goal_count} agent-proposed goal(s) pursued by swarm(s)"
  ((criteria_met++))
else
  echo "  ✗ NOT YET: No emergent goals found (goalOrigin='agent-proposed' or 'emergent')"
  echo "    Hint: Swarm records need .goalOrigin='agent-proposed' field"
  echo "    This field is set when coordinator spawns a swarm for a vision-queue item"
  echo "    Check coordinator.sh spawn_swarm_for_issue() or equivalent function"
fi
echo ""

# Criterion B.4: Swarm memory persistence
echo "[B.4] Checking swarm summaries written to S3 (need >= 1, found ${swarm_memory_count})..."
if [ "$swarm_memory_count" -ge 1 ]; then
  echo "  ✓ PASS: ${swarm_memory_count} swarm memory record(s) in S3"
  ((criteria_met++))
else
  echo "  ✗ NOT YET: No swarm memory records found in S3"
  echo "    Checked: s3://${S3_BUCKET}/swarm-memories/ and s3://${S3_BUCKET}/swarms/"
  echo "    Hint: A swarm must dissolve (coordinator auto-disband or agent exit with SWARM_REF)"
  echo "    to trigger write_swarm_memory() (PR #1779 helpers.sh, PR #1793 coordinator.sh)"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo ""
total_checks=$((checks_total + criteria_total))
total_passed=$((checks_passed + criteria_met))
echo "Section A (coordinator fields): ${checks_passed}/${checks_total} initialized"
echo "Section B (v0.6 criteria):      ${criteria_met}/${criteria_total} met"
echo ""
echo "Overall: ${total_passed}/${total_checks}"
echo ""

if [ "$checks_passed" -eq "$checks_total" ] && [ "$criteria_met" -eq "$criteria_total" ]; then
  echo "✓ ALL v0.6 CHECKS PASSED"
  echo "The v0.6 Collective Action milestone is complete."
  echo ""
  echo "Expected coordinator-state.v06MilestoneStatus = 'completed'"
  echo "Actual: '${v06_milestone}'"
  if [ "$v06_milestone" = "completed" ]; then
    echo "  ✓ coordinator confirms milestone complete"
  else
    echo "  ⚠ coordinator hasn't run check_v06_milestone() yet — wait ~10 min"
  fi
  exit 0
else
  if [ "$checks_passed" -lt "$checks_total" ]; then
    echo "⚠ Coordinator state fields not fully initialized."
    echo "  Apply PRs for issues #1789 (check_v06_milestone) and #1775 (activeSwarms)."
    echo ""
  fi
  if [ "$criteria_met" -lt "$criteria_total" ]; then
    echo "⏳ v0.6 criteria not yet met. This is expected — v0.6 features need real swarm activity."
    echo "  Once PRs #1781, #1786, #1793, #1794 merge and coordinator restarts:"
    echo "  - coordinator will auto-spawn swarms for multi-domain issues"
    echo "  - auto-disband idle swarms and write memory to S3"
    echo "  - check_v06_milestone() will track progress every ~10 min"
  fi
  exit 1
fi
