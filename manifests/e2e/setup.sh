#!/usr/bin/env bash
# manifests/e2e/setup.sh
# One-time setup for the agentex-e2e staging environment on the main EKS cluster.
#
# What this does:
#   1. Create the agentex-e2e namespace + RBAC
#   2. Create an EKS Pod Identity association for agentex-agent-sa in agentex-e2e
#      (so mock agent Jobs can assume the same IAM role as production agents)
#   3. Apply the agentex-constitution ConfigMap with e2e defaults
#   4. Apply the killswitch ConfigMap (enabled=false — e2e tests need agents to run)
#   5. Create the coordinator-state ConfigMap seed
#
# Run once:
#   ./manifests/e2e/setup.sh
#
# Prerequisites:
#   - kubectl configured to the agentex EKS cluster
#   - aws CLI with sufficient permissions (eks:CreatePodIdentityAssociation, iam:*)
#   - Constitution values in agentex-constitution already set (read from there)

set -euo pipefail

NAMESPACE="agentex-e2e"
CLUSTER_NAME="${CLUSTER_NAME:-agentex}"
REGION="${AWS_REGION:-us-west-2}"
IAM_ROLE_ARN="arn:aws:iam::569190534191:role/agentex-agent-role"

# Always target the agentex EKS cluster explicitly.
# There may be multiple kubeconfig contexts (e.g. krombat) — omitting --context
# silently targets the wrong cluster.
KUBE_CONTEXT="arn:aws:eks:${REGION}:569190534191:cluster/${CLUSTER_NAME}"
KUBECTL="kubectl --context ${KUBE_CONTEXT}"

echo "=== Setting up agentex-e2e staging environment ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region:  $REGION"
echo "IAM role: $IAM_ROLE_ARN"
echo ""

# Step 1: Namespace + RBAC
echo "[1/5] Applying namespace and RBAC..."
$KUBECTL apply -f "$(dirname "$0")/namespace.yaml"
$KUBECTL apply -f "$(dirname "$0")/rbac.yaml"
echo "      Done."

# Step 2: EKS Pod Identity association
# This allows agentex-agent-sa in agentex-e2e to assume the same IAM role
# as the production agents, giving them ECR pull and S3 access.
echo "[2/5] Creating EKS Pod Identity association..."
EXISTING=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --service-account agentex-agent-sa \
  --region "$REGION" \
  --query 'associations[0].associationId' \
  --output text 2>/dev/null || echo "None")

if [ "$EXISTING" = "None" ] || [ -z "$EXISTING" ]; then
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" \
    --service-account agentex-agent-sa \
    --role-arn "$IAM_ROLE_ARN" \
    --region "$REGION"
  echo "      Created Pod Identity association."
else
  echo "      Pod Identity association already exists ($EXISTING). Skipping."
fi

# Step 3: Read constitution values from production and mirror them into e2e namespace.
echo "[3/5] Applying agentex-constitution ConfigMap..."
GITHUB_REPO=$($KUBECTL get configmap agentex-constitution -n agentex \
  -o jsonpath='{.data.githubRepo}' 2>/dev/null || echo "pnz1990/agentex")
ECR_REGISTRY=$($KUBECTL get configmap agentex-constitution -n agentex \
  -o jsonpath='{.data.ecrRegistry}' 2>/dev/null || echo "569190534191.dkr.ecr.us-west-2.amazonaws.com")
S3_BUCKET=$($KUBECTL get configmap agentex-constitution -n agentex \
  -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo "agentex-thoughts")

$KUBECTL apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: agentex-constitution
  namespace: $NAMESPACE
  labels:
    agentex/env: staging
data:
  circuitBreakerLimit: "5"
  vision: "e2e staging environment — flight tests only"
  civilizationGeneration: "0"
  githubRepo: "$GITHUB_REPO"
  ecrRegistry: "$ECR_REGISTRY"
  awsRegion: "$REGION"
  clusterName: "$CLUSTER_NAME"
  s3Bucket: "$S3_BUCKET"
  lastDirective: "flight test mode — no real work"
  voteThreshold: "3"
  minimumVisionScore: "1"
  jobTTLSeconds: "300"
  dailyCostBudgetUSD: "5"
EOF
echo "      Done."

# Step 4: Killswitch — OFF for e2e (agents must be able to run)
echo "[4/5] Applying killswitch (disabled for e2e)..."
$KUBECTL apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: agentex-killswitch
  namespace: $NAMESPACE
  labels:
    agentex/env: staging
data:
  enabled: "false"
  reason: ""
EOF
echo "      Done."

# Step 5: Coordinator state seed
echo "[5/5] Seeding coordinator-state ConfigMap..."
$KUBECTL apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coordinator-state
  namespace: $NAMESPACE
  labels:
    agentex/component: coordinator
    agentex/env: staging
data:
  bootstrapped: "true"
  taskQueue: ""
  activeAssignments: ""
  spawnSlots: "5"
  visionQueue: ""
  activeAgents: ""
  lastHeartbeat: ""
  decisionLog: ""
  enactedDecisions: ""
EOF
echo "      Done."

echo ""
echo "=== agentex-e2e staging environment ready ==="
echo ""
echo "Run e2e tests:"
echo "  go test -v -tags e2e -timeout 20m ./e2e/... -run TestBasicDispatch"
echo ""
echo "Use image: $ECR_REGISTRY/agentex/runner:e2e"
echo "Set env:   FLIGHT_TEST_IMAGE=$ECR_REGISTRY/agentex/runner:e2e"
echo "           E2E_NAMESPACE=$NAMESPACE"
