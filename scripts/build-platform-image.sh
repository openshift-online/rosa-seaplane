#!/usr/bin/env bash
# Build and push the platform container image to public ECR
#
# The image is tagged with the SHA256 of the Dockerfile (first 12 chars).
# If an image with that tag already exists in ECR, the build is skipped.
#
# Public ECR repositories must be managed from us-east-1.
#
# Usage: PLATFORM_ECR_REPO must be set by the CodeBuild project.
#
# Set CONTAINER_RUNTIME=docker or CONTAINER_RUNTIME=podman to override auto-detection.

set -euo pipefail

echo "=========================================="
echo "Building Platform Image"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Detect container runtime: honor CONTAINER_RUNTIME env var, otherwise auto-detect
if [ -n "${CONTAINER_RUNTIME:-}" ]; then
  if ! command -v "$CONTAINER_RUNTIME" &>/dev/null; then
    echo "Error: CONTAINER_RUNTIME='$CONTAINER_RUNTIME' not found in PATH."
    exit 1
  fi
else
  if command -v docker &>/dev/null; then
    CONTAINER_RUNTIME="docker"
  elif command -v podman &>/dev/null; then
    CONTAINER_RUNTIME="podman"
  else
    echo "Error: Neither docker nor podman found. Install one or set CONTAINER_RUNTIME."
    exit 1
  fi
fi

echo "Using container runtime: $CONTAINER_RUNTIME"

DOCKERFILE_DIR="terraform/modules/platform-image"
DOCKERFILE="${DOCKERFILE_DIR}/Dockerfile"

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: Dockerfile not found: $DOCKERFILE"
  exit 1
fi

# Compute the image tag from the Dockerfile content (matches Terraform's sha256(), first 12 hex chars)
if command -v sha256sum &>/dev/null; then
  IMAGE_TAG=$(sha256sum "$DOCKERFILE" | cut -c1-12)
elif command -v shasum &>/dev/null; then
  IMAGE_TAG=$(shasum -a 256 "$DOCKERFILE" | cut -c1-12)
else
  echo "Error: Neither sha256sum nor shasum found."
  exit 1
fi

# The project always receives its exact repository URI from Terraform. Requiring
# it avoids account-wide repository discovery and keeps IAM scoped to one repo.
if [ -z "${PLATFORM_ECR_REPO:-}" ]; then
  echo "Error: PLATFORM_ECR_REPO must be set by the CodeBuild project."
  exit 1
fi
ECR_URL="${PLATFORM_ECR_REPO}"
echo "Using PLATFORM_ECR_REPO from environment: $ECR_URL"

echo "ECR Repository: $ECR_URL"
echo "Image tag:      $IMAGE_TAG"
echo ""

# Check if the image already exists in ECR
echo "Checking if image already exists in ECR..."
# Public ECR URI format: public.ecr.aws/<alias>/<repo-name>
# Extract the repository name by removing the "public.ecr.aws/<alias>/" prefix
ECR_REPO=$(echo "$ECR_URL" | sed 's|^public\.ecr\.aws/[^/]*/||')
if aws ecr-public describe-images \
    --region us-east-1 \
    --repository-name "$ECR_REPO" \
    --image-ids imageTag="$IMAGE_TAG" &>/dev/null; then
  echo "Image ${ECR_URL}:${IMAGE_TAG} already exists in ECR. Skipping build."
  exit 0
fi

echo "Image not found in ECR. Building..."
echo ""

# Authenticate with public ECR (required for pushing)
echo "Authenticating with public ECR..."
aws ecr-public get-login-password --region us-east-1 | $CONTAINER_RUNTIME login --username AWS --password-stdin public.ecr.aws
echo ""

# Build the image
echo "Building platform image from ${DOCKERFILE}..."
$CONTAINER_RUNTIME build --pull --platform linux/amd64 -t "${ECR_URL}:${IMAGE_TAG}" "$DOCKERFILE_DIR"
echo ""

# Push the image
echo "Pushing image to ECR..."
$CONTAINER_RUNTIME push "${ECR_URL}:${IMAGE_TAG}"
echo ""

echo "Done. Image pushed to: ${ECR_URL}:${IMAGE_TAG}"
