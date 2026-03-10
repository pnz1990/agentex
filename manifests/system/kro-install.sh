#!/usr/bin/env bash
# Install kro v0.8.5 via Helm into the agentex EKS cluster.
# Run once after the cluster is provisioned with Terraform.
# Requires: helm, kubectl (configured for the agentex cluster)
#
# Usage:
#   CLUSTER=my-cluster REGION=eu-west-1 ./kro-install.sh
#   OR:
#   ./kro-install.sh --cluster my-cluster --region eu-west-1
#
# Defaults to the original agentex installation values if not set.
# Run install-configure.sh first to update all manifests for your environment.
set -euo pipefail

KRO_VERSION="0.8.5"

# Allow override via CLI args or env vars (set by install-configure.sh)
CLUSTER="${CLUSTER:-agentex}"
REGION="${REGION:-us-west-2}"

# Parse optional command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster)
      CLUSTER="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [--cluster CLUSTER_NAME] [--region AWS_REGION]"
      echo ""
      echo "Environment variables (alternative to flags):"
      echo "  CLUSTER   EKS cluster name (default: agentex)"
      echo "  REGION    AWS region (default: us-west-2)"
      echo ""
      echo "Tip: Run manifests/system/install-configure.sh first to configure"
      echo "     all manifests for your environment."
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Run with --help for usage."
      exit 1
      ;;
  esac
done

echo "[kro-install] Updating kubeconfig for cluster $CLUSTER..."
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo "[kro-install] Installing kro v$KRO_VERSION via Helm..."
helm install kro oci://public.ecr.aws/kro/kro \
  --namespace kro \
  --create-namespace \
  --version "$KRO_VERSION" \
  --wait \
  --timeout 5m

echo "[kro-install] Waiting for kro controller to be ready..."
kubectl rollout status deployment/kro-controller-manager -n kro --timeout=120s

echo "[kro-install] Applying kro stability fixes (PDB + PriorityClass)..."
kubectl apply -f manifests/system/kro-stability.yaml

echo "[kro-install] Patching kro deployment with higher memory and PriorityClass..."
kubectl patch deployment kro-controller-manager -n kro --type=strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "priorityClassName": "system-cluster-critical-kro",
        "containers": [
          {
            "name": "manager",
            "resources": {
              "requests": {
                "memory": "512Mi",
                "cpu": "100m"
              },
              "limits": {
                "memory": "1Gi"
              }
            }
          }
        ]
      }
    }
  }
}'

echo "[kro-install] Waiting for kro controller to roll out with new configuration..."
kubectl rollout status deployment/kro-controller-manager -n kro --timeout=120s

echo "[kro-install] Applying agentex CRDs..."
kubectl apply -f manifests/crds/

echo "[kro-install] Applying agentex RBAC..."
kubectl apply -f manifests/rbac/

echo "[kro-install] Applying kro RGDs..."
kubectl apply -f manifests/rgds/

echo "[kro-install] Waiting for RGDs to become Active..."
for rgd in agent-graph task-graph message-graph thought-graph swarm-graph coordinator-graph planner-loop-graph report-graph; do
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
