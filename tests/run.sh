#!/usr/bin/env bash
# Entrypoint for the test container (also runnable on host if deps installed).
# Runs shellcheck and bats independently, prints a summary, exits non-zero
# if either failed.
set -uo pipefail

cd "$(dirname "$0")/.."

lint_rc=0
bats_rc=0

echo "==> shellcheck"
bash tests/lint.sh || lint_rc=$?

echo
echo "==> bats"
bats tests/check_auth.bats || bats_rc=$?

echo
echo "==> summary"
[ "$lint_rc" -eq 0 ] && echo "  lint:  PASS" || echo "  lint:  FAIL (rc=$lint_rc)"
[ "$bats_rc" -eq 0 ] && echo "  bats:  PASS" || echo "  bats:  FAIL (rc=$bats_rc)"

if [ "$lint_rc" -ne 0 ] || [ "$bats_rc" -ne 0 ]; then
    exit 1
fi
