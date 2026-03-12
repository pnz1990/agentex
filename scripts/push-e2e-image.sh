#!/usr/bin/env bash
# scripts/push-e2e-image.sh
# Builds and pushes agentex/runner:e2e to ECR.
# This image is used by mock agent Jobs in the agentex-e2e staging namespace.
#
# Usage:
#   ./scripts/push-e2e-image.sh
#
# Prerequisites:
#   - Docker logged in to ECR: aws ecr get-login-password | docker login ...
#   - Go 1.25+ installed (for binary compilation check)
#   - AWS CLI configured

set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
ACCOUNT="${AWS_ACCOUNT:-569190534191}"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
REPO="agentex/runner"
TAG="e2e"
FULL_IMAGE="${REGISTRY}/${REPO}:${TAG}"

echo "=== Building and pushing e2e image ==="
echo "Image: $FULL_IMAGE"
echo ""

# ECR login
echo "[1/3] Logging in to ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

# Build
echo "[2/3] Building image..."
docker build \
  --platform linux/amd64 \
  -f images/runner/Dockerfile \
  -t "${FULL_IMAGE}" \
  -t "agentex/runner:e2e" \
  .

# Push
echo "[3/3] Pushing to ECR..."
docker push "${FULL_IMAGE}"

echo ""
echo "=== Done ==="
echo "Image pushed: $FULL_IMAGE"
echo ""
echo "Use in e2e tests:"
echo "  export FLIGHT_TEST_IMAGE=$FULL_IMAGE"
echo "  go test -v -tags e2e -timeout 20m ./e2e/..."
