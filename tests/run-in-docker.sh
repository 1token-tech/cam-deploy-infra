#!/usr/bin/env bash
# Build the test image and run lint + bats inside a container.
# Usage: bash tests/run-in-docker.sh
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE=${IMAGE:-cam-check-auth-tests:latest}

docker build -t "$IMAGE" -f tests/Dockerfile tests/
docker run --rm -v "$PWD:/work" "$IMAGE"
