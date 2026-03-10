#!/usr/bin/env bash
# verify-v05-features.sh
# Verifies that v0.5 Emergent Specialization features are working after coordinator restart
#
# Usage: ./verify-v05-features.sh
#
# Success criteria (from issue #1732):
# 1. Dynamic role promotions: At least 1 agent with promotedRole in S3 identity
# 2. Trust graph: At least 1 citation edge in coordinator-state.agentTrustGraph
# 3. Mentor credit loop: At least 1 agent with mentorCredits in S3 identity
# 4. Vision queue proposer identity: visionQueueLog has entries (already verified)
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
criteria_total=4

# Criterion 1: Dynamic role promotions (PR #1747)
echo "[1/4] Checking for promoted roles in S3 identities..."
promoted_count=0
for identity_file in $(aws s3 ls "s3://${S3_BUCKET}/identities/" | tail -20 | awk '{print $4}'); do
  identity_json=$(aws s3 cp "s3://${S3_BUCKET}/identities/${identity_file}" - 2>/dev/null || echo "{}")
  if echo "$identity_json" | jq -e '.promotedRole' >/dev/null 2>&1; then
    promoted_role=$(echo "$identity_json" | jq -r '.promotedRole')
    agent_name=$(echo "$identity_json" | jq -r '.agentName')
    echo "  ✓ Found promoted agent: $agent_name → $promoted_role"
    ((promoted_count++))
  fi
done

if [ "$promoted_count" -ge 1 ]; then
  echo "  ✓ PASS: Found $promoted_count promoted agents"
  ((criteria_met++))
else
  echo "  ✗ FAIL: No promoted agents found (expected at least 1)"
  echo "    Hint: Coordinator calls promote_agent_role() every 15 iterations (~7.5 min)"
  echo "    Wait longer or check coordinator logs for errors"
fi
echo ""

# Criterion 2: Trust graph (PR #1737)
echo "[2/4] Checking trust graph in coordinator-state..."
trust_graph=$(kubectl get configmap coordinator-state -n "$NAMESPACE" -o jsonpath='{.data.agentTrustGraph}' 2>/dev/null || echo "")
if [ -n "$trust_graph" ]; then
  edge_count=$(echo "$trust_graph" | tr '|' '\n' | grep -c ':' || echo "0")
  echo "  ✓ PASS: Found $edge_count citation edges in trust graph"
  echo "    Sample edges: $(echo "$trust_graph" | tr '|' '\n' | head -3 | paste -sd ' ')"
  ((criteria_met++))
else
  echo "  ✗ FAIL: Trust graph is empty"
  echo "    Hint: Agents must call cite_debate_outcome() to build trust edges"
  echo "    Check if agents are engaging in debate with synthesize stance"
fi
echo ""

# Criterion 3: Mentor credit loop (PR #1749)
echo "[3/4] Checking for mentor credits in S3 identities..."
mentor_credit_count=0
for identity_file in $(aws s3 ls "s3://${S3_BUCKET}/identities/" | tail -20 | awk '{print $4}'); do
  identity_json=$(aws s3 cp "s3://${S3_BUCKET}/identities/${identity_file}" - 2>/dev/null || echo "{}")
  if echo "$identity_json" | jq -e '.specializationDetail.mentorCredits' >/dev/null 2>&1; then
    credits=$(echo "$identity_json" | jq -r '.specializationDetail.mentorCredits | length')
    if [ "$credits" -gt 0 ]; then
      agent_name=$(echo "$identity_json" | jq -r '.agentName')
      echo "  ✓ Found mentor with credits: $agent_name → $credits credits"
      ((mentor_credit_count++))
    fi
  fi
done

if [ "$mentor_credit_count" -ge 1 ]; then
  echo "  ✓ PASS: Found $mentor_credit_count agents with mentor credits"
  ((criteria_met++))
else
  echo "  ✗ FAIL: No agents with mentor credits found"
  echo "    Hint: Workers must call credit_mentor_for_success() when mentored PR passes CI"
  echo "    Check entrypoint.sh exit handler for credit_mentor_for_success() calls"
fi
echo ""

# Criterion 4: Vision queue proposer identity (PR #1739)
echo "[4/4] Checking vision queue proposer identity..."
vision_log=$(kubectl get configmap coordinator-state -n "$NAMESPACE" -o jsonpath='{.data.visionQueueLog}' 2>/dev/null || echo "")
if [ -n "$vision_log" ]; then
  entry_count=$(echo "$vision_log" | tr ';' '\n' | wc -l)
  echo "  ✓ PASS: Found $entry_count entries in visionQueueLog"
  echo "    Sample: $(echo "$vision_log" | tr ';' '\n' | head -1)"
  ((criteria_met++))
else
  echo "  ✗ FAIL: visionQueueLog is empty"
  echo "    Hint: Agents must propose vision features via governance votes"
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
