#!/usr/bin/env bash
# Install kro v0.8.5 via Helm into the agentex EKS cluster.
# Run once after the cluster is provisioned with Terraform.
# Requires: helm, kubectl (configured for the agentex cluster)
set -euo pipefail

KRO_VERSION="0.8.5"
CLUSTER="agentex"
REGION="us-west-2"

echo "[kro-install] Updating kubeconfig for cluster $CLUSTER..."
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo "[kro-install] Installing kro v$KRO_VERSION via Helm..."
# Issue #714: Increase resource requests to prevent EKS Auto Mode eviction
# and add PodDisruptionBudget to prevent dynamic controller failure after restart
# NOTE: kro Helm chart creates namespace 'kro-system' by default (not 'kro')
helm install kro oci://public.ecr.aws/kro/kro \
  --namespace kro-system \
  --create-namespace \
  --version "$KRO_VERSION" \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=512Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=1Gi \
  --set podDisruptionBudget.enabled=true \
  --set podDisruptionBudget.minAvailable=1 \
  --wait \
  --timeout 5m

echo "[kro-install] Waiting for kro controller to be ready..."
kubectl rollout status deployment/kro -n kro-system --timeout=120s

echo "[kro-install] Applying agentex CRDs..."
kubectl apply -f manifests/crds/

echo "[kro-install] Applying agentex RBAC..."
kubectl apply -f manifests/rbac/

echo "[kro-install] Applying kro RGDs..."
kubectl apply -f manifests/rgds/

echo "[kro-install] Waiting for RGDs to become Active..."
for rgd in agent-graph task-graph message-graph thought-graph swarm-graph; do
  echo -n "  Waiting for $rgd ..."
  for i in $(seq 1 30); do
    STATE=$(kubectl get resourcegraphdefinition "$rgd" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$STATE" = "True" ]; then
      echo " Active"
      break
    fi
    echo -n "."
    sleep 5
  done
done

echo "[kro-install] Applying system policies..."
kubectl apply -f manifests/system/network-policy.yaml
kubectl apply -f manifests/system/pod-security.yaml

echo "[kro-install] kro installation complete."
echo ""
echo "Next steps:"
echo "  1. Create the agentex-github-token secret:"
echo "     kubectl create secret generic agentex-github-token \\"
echo "       --from-literal=token=<your-github-pat> -n agentex"
echo "  2. Apply the bootstrap seed job:"
echo "     kubectl apply -f manifests/bootstrap/seed-agent.yaml"
echo "  3. Watch the seed agent:"
echo "     kubectl logs -f job/bootstrap-seed -n agentex"
