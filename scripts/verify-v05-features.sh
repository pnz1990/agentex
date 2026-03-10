#!/usr/bin/env bash
# verify-v05-features.sh
# Verifies that v0.5 Emergent Specialization features are working after coordinator restart
#
# Usage: ./verify-v05-features.sh
#
# Success criteria (from issue #1732, matching coordinator check_v05_milestone()):
# 1. Dynamic role promotions: 3+ agents with promotedRole in S3 identity
# 2. Trust graph: 5+ citation edges in coordinator-state.agentTrustGraph
# 3. Proactive issue discovery: 2+ agents with stats.proactiveIssuesFound > 0
# 4. Mentor credit loop: 1+ agent with specializationDetail.mentorCredits > 0
# 5. Vision queue proposer identity: 2+ items in visionQueueLog
#
# Exit codes:
#   0 = all criteria met
#   1 = some criteria not met (prints which ones failed)

set -euo pipefail

NAMESPACE="agentex"
S3_BUCKET=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")

echo "=== v0.5 Feature Verification ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

criteria_met=0
criteria_total=5

# Scan identity files once for criteria 1, 3, and 4
# (avoids redundant S3 downloads — same pattern as coordinator.sh check_v05_milestone())
echo "[Scanning S3 identity files for criteria 1, 3, 4...]"
identity_files=$(aws s3 ls "s3://${S3_BUCKET}/identities/" | tail -50 | awk '{print $4}' | grep '\.json$' | grep -v '^$' || echo "")
promoted_count=0
proactive_count=0
mentor_credit_count=0

for identity_file in $identity_files; do
  identity_json=$(aws s3 cp "s3://${S3_BUCKET}/identities/${identity_file}" - 2>/dev/null || echo "{}")
  [ -z "$identity_json" ] || [ "$identity_json" = "{}" ] && continue

  # Criterion 1: promotedRole
  prole=$(echo "$identity_json" | jq -r '.promotedRole // ""' 2>/dev/null || echo "")
  if [ -n "$prole" ]; then
    agent_name=$(echo "$identity_json" | jq -r '.agentName // "unknown"')
    echo "  ✓ Found promoted agent: $agent_name → $prole"
    ((promoted_count++))
  fi

  # Criterion 3: proactiveIssuesFound (under .stats.proactiveIssuesFound)
  pif=$(echo "$identity_json" | jq -r '.stats.proactiveIssuesFound // 0 | tonumber' 2>/dev/null || echo "0")
  if [ "$pif" -gt 0 ] 2>/dev/null; then
    agent_name=$(echo "$identity_json" | jq -r '.agentName // "unknown"')
    echo "  ✓ Found proactive agent: $agent_name (proactiveIssuesFound=$pif)"
    ((proactive_count++))
  fi

  # Criterion 4: mentorCredits (array under .specializationDetail.mentorCredits)
  mc=$(echo "$identity_json" | jq -r '(.specializationDetail.mentorCredits // []) | length' 2>/dev/null || echo "0")
  if [ "$mc" -gt 0 ] 2>/dev/null; then
    agent_name=$(echo "$identity_json" | jq -r '.agentName // "unknown"')
    echo "  ✓ Found mentor with credits: $agent_name ($mc credits)"
    ((mentor_credit_count++))
  fi
done
echo ""

# Criterion 1: Dynamic role promotions (PR #1747)
echo "[1/5] Dynamic role promotions..."
if [ "$promoted_count" -ge 3 ]; then
  echo "  ✓ PASS: Found $promoted_count promoted agents (need 3)"
  ((criteria_met++))
else
  echo "  ✗ FAIL: Only $promoted_count promoted agents found (need 3)"
  echo "    Hint: Coordinator calls promote_agent_role() every 15 iterations (~7.5 min)"
  echo "    Promotion criteria: 3 consecutive visionScores >= 8 OR 5+ tasks in one domain"
  echo "    Wait longer or check coordinator logs for errors"
fi
echo ""

# Criterion 2: Trust graph (PR #1737)
echo "[2/5] Trust graph..."
trust_graph=$(kubectl get configmap coordinator-state -n "$NAMESPACE" -o jsonpath='{.data.agentTrustGraph}' 2>/dev/null || echo "")
edge_count=0
if [ -n "$trust_graph" ]; then
  edge_count=$(echo "$trust_graph" | tr '|' '\n' | grep -c '.' 2>/dev/null || echo "0")
fi

if [ "$edge_count" -ge 5 ]; then
  echo "  ✓ PASS: Found $edge_count citation edges in trust graph (need 5)"
  echo "    Sample edges: $(echo "$trust_graph" | tr '|' '\n' | head -3 | paste -sd ' ')"
  ((criteria_met++))
else
  echo "  ✗ FAIL: Only $edge_count citation edges found (need 5)"
  echo "    Hint: Agents must call cite_debate_outcome() to build trust edges"
  echo "    Check if agents are engaging in debate with synthesize stance"
fi
echo ""

# Criterion 3: Proactive issue discovery (PR #1745)
echo "[3/5] Proactive issue discovery..."
if [ "$proactive_count" -ge 2 ]; then
  echo "  ✓ PASS: Found $proactive_count agents with proactiveIssuesFound > 0 (need 2)"
  ((criteria_met++))
else
  echo "  ✗ FAIL: Only $proactive_count agents with proactiveIssuesFound > 0 (need 2)"
  echo "    Hint: proactive_domain_scan() is called automatically at startup for specialist agents"
  echo "    Ensure agents have specialization set and proactive_domain_scan() runs without error"
fi
echo ""

# Criterion 4: Mentor credit loop (PR #1749)
echo "[4/5] Mentor credit loop..."
if [ "$mentor_credit_count" -ge 1 ]; then
  echo "  ✓ PASS: Found $mentor_credit_count agents with mentor credits (need 1)"
  ((criteria_met++))
else
  echo "  ✗ FAIL: No agents with mentor credits found (need 1)"
  echo "    Hint: Workers must call credit_mentor_for_success() when mentored PR passes CI"
  echo "    Check entrypoint.sh exit handler for credit_mentor_for_success() calls"
fi
echo ""

# Criterion 5: Vision queue proposer identity (PR #1739)
echo "[5/5] Vision queue proposer identity..."
vision_log=$(kubectl get configmap coordinator-state -n "$NAMESPACE" -o jsonpath='{.data.visionQueueLog}' 2>/dev/null || echo "")
vql_count=0
if [ -n "$vision_log" ]; then
  vql_count=$(echo "$vision_log" | tr ';' '\n' | grep -c '.' 2>/dev/null || echo "0")
fi

if [ "$vql_count" -ge 2 ]; then
  echo "  ✓ PASS: Found $vql_count entries in visionQueueLog (need 2)"
  echo "    Sample: $(echo "$vision_log" | tr ';' '\n' | head -1)"
  ((criteria_met++))
else
  echo "  ✗ FAIL: Only $vql_count entries in visionQueueLog (need 2)"
  echo "    Hint: Agents must propose vision features via governance votes"
  echo "    See propose_vision_feature() in helpers.sh"
fi
echo ""

# Summary
echo "=== Summary ==="
echo "Criteria met: $criteria_met / $criteria_total"
echo ""

if [ "$criteria_met" -eq "$criteria_total" ]; then
  echo "✓ ALL v0.5 SUCCESS CRITERIA MET"
  echo "The v0.5 Emergent Specialization milestone is complete."
  exit 0
else
  echo "✗ Some criteria not yet met. Wait longer or investigate failures above."
  exit 1
fi
