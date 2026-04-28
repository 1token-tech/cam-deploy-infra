#!/usr/bin/env bash
# Run shellcheck across check_auth.sh and the helper scripts in tests/.
set -euo pipefail

cd "$(dirname "$0")/.."

shellcheck check_auth.sh
shellcheck tests/run.sh tests/lint.sh tests/run-in-docker.sh
# helpers.bash relies on bats-injected globals (BATS_TEST_TMPDIR,
# BATS_TEST_DIRNAME). Tell shellcheck it's bash and ignore those.
shellcheck --shell=bash --exclude=SC2154 tests/helpers.bash

echo "shellcheck OK"
