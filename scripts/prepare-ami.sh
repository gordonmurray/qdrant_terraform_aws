#!/usr/bin/env bash
# Run as root on a clean AL2023 image-builder instance, before creating its AMI.
set -euo pipefail
: "${QDRANT_IMAGE:?Set the full repository@sha256:digest image reference}"
[[ "$QDRANT_IMAGE" =~ ^[a-zA-Z0-9./:_-]+@sha256:[a-f0-9]{64}$ ]] || {
  echo "QDRANT_IMAGE must use an immutable sha256 digest" >&2; exit 2;
}
[ "$(id -u)" -eq 0 ] || { echo "Run this script as root on the image builder" >&2; exit 2; }
[ ! -d /qdrant/data ] || { echo "Refusing to bake an instance with a Qdrant data directory" >&2; exit 2; }

dnf install -y docker jq xfsprogs amazon-cloudwatch-agent
command -v aws >/dev/null
systemctl enable --now docker
# A temporary Docker configuration prevents registry credentials entering the AMI.
export DOCKER_CONFIG
DOCKER_CONFIG=$(mktemp -d)
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
if [ "${ECR_LOGIN:-0}" = 1 ]; then
  : "${AWS_REGION:?Set AWS_REGION for private ECR login}"
  registry="${QDRANT_IMAGE%%/*}"
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$registry"
fi
docker pull "$QDRANT_IMAGE"
docker image inspect "$QDRANT_IMAGE" >/dev/null
docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges:true "$QDRANT_IMAGE" ./qdrant --version
printf 'Image cached. Create and test an AMI from this builder: %s\n' "$QDRANT_IMAGE"
