#!/usr/bin/env bash
# Agentex Installation Configuration Helper
# 
# This script helps a new god configure agentex for their own AWS account,
# GitHub repo, region, and cluster name. It updates the constitution ConfigMap
# and the two bootstrap files that must have hardcoded image URLs.
#
# Usage:
#   ./install-configure.sh \
#     --ecr-registry 123456789012.dkr.ecr.eu-west-1.amazonaws.com \
#     --aws-region eu-west-1 \
#     --cluster-name my-agentex-cluster \
#     --github-repo myorg/myrepo \
#     --s3-bucket my-agentex-thoughts

set -euo pipefail

# Default values (original agentex installation)
ECR_REGISTRY="569190534191.dkr.ecr.us-west-2.amazonaws.com"
AWS_REGION="us-west-2"
CLUSTER_NAME="agentex"
GITHUB_REPO="pnz1990/agentex"
S3_BUCKET="agentex-thoughts"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --ecr-registry)
      ECR_REGISTRY="$2"
      shift 2
      ;;
    --aws-region)
      AWS_REGION="$2"
      shift 2
      ;;
    --cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --github-repo)
      GITHUB_REPO="$2"
      shift 2
      ;;
    --s3-bucket)
      S3_BUCKET="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --ecr-registry REGISTRY   ECR registry URL (e.g., 123456789012.dkr.ecr.eu-west-1.amazonaws.com)"
      echo "  --aws-region REGION       AWS region (e.g., eu-west-1)"
      echo "  --cluster-name NAME       EKS cluster name (e.g., my-cluster)"
      echo "  --github-repo REPO        GitHub repo (e.g., myorg/myrepo)"
      echo "  --s3-bucket BUCKET        S3 bucket for agent memory (e.g., my-bucket)"
      echo ""
      echo "This script updates:"
      echo "  - manifests/system/constitution.yaml (ConfigMap data fields)"
      echo "  - manifests/bootstrap/seed-agent.yaml (image URL)"
      echo "  - manifests/system/constitution-validator.yaml (image URL)"
      echo "  - manifests/system/kro-install.sh (CLUSTER and REGION defaults)"
      echo ""
      echo "Run this BEFORE applying manifests to your cluster."
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Run with --help for usage."
      exit 1
      ;;
  esac
done

echo "Configuring agentex installation with:"
echo "  ECR Registry:  $ECR_REGISTRY"
echo "  AWS Region:    $AWS_REGION"
echo "  Cluster Name:  $CLUSTER_NAME"
echo "  GitHub Repo:   $GITHUB_REPO"
echo "  S3 Bucket:     $S3_BUCKET"
echo ""

# Confirm with user
read -p "Apply these changes to manifests? (y/N): " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Update constitution.yaml
echo "Updating manifests/system/constitution.yaml..."
sed -i.bak \
  -e "s|ecrRegistry: \".*\"|ecrRegistry: \"$ECR_REGISTRY\"|" \
  -e "s|awsRegion: \".*\"|awsRegion: \"$AWS_REGION\"|" \
  -e "s|clusterName: \".*\"|clusterName: \"$CLUSTER_NAME\"|" \
  -e "s|githubRepo: \".*\"|githubRepo: \"$GITHUB_REPO\"|" \
  -e "s|s3Bucket: \".*\"|s3Bucket: \"$S3_BUCKET\"|" \
  "$REPO_ROOT/manifests/system/constitution.yaml"

# Update seed-agent.yaml image URL
echo "Updating manifests/bootstrap/seed-agent.yaml..."
sed -i.bak \
  "s|image: .*\.dkr\.ecr\..*\.amazonaws\.com/agentex/runner:latest|image: $ECR_REGISTRY/agentex/runner:latest|" \
  "$REPO_ROOT/manifests/bootstrap/seed-agent.yaml"

# Update constitution-validator.yaml image URL
echo "Updating manifests/system/constitution-validator.yaml..."
sed -i.bak \
  "s|image: .*\.dkr\.ecr\..*\.amazonaws\.com/agentex/runner:latest|image: $ECR_REGISTRY/agentex/runner:latest|" \
  "$REPO_ROOT/manifests/system/constitution-validator.yaml"

# Update kro-install.sh CLUSTER and REGION defaults (issue #1081)
echo "Updating manifests/system/kro-install.sh..."
sed -i.bak \
  -e "s|CLUSTER=\"\${CLUSTER:-.*}\"|CLUSTER=\"\${CLUSTER:-$CLUSTER_NAME}\"|" \
  -e "s|REGION=\"\${REGION:-.*}\"|REGION=\"\${REGION:-$AWS_REGION}\"|" \
  "$REPO_ROOT/manifests/system/kro-install.sh"

echo ""
echo "✓ Configuration complete!"
echo ""
echo "Backup files created with .bak extension."
echo ""
echo "Next steps:"
echo "  1. Review the changes with: git diff"
echo "  2. Create S3 bucket: aws s3 mb s3://$S3_BUCKET --region $AWS_REGION"
echo "  3. Push runner image to your ECR: docker tag agentex/runner:latest $ECR_REGISTRY/agentex/runner:latest && docker push ..."
echo "  4. Apply manifests: kubectl apply -f manifests/system/ && kubectl apply -f manifests/bootstrap/"
echo ""
