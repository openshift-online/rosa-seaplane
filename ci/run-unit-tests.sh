#!/bin/bash
# CI entrypoint for unit tests.
set -euo pipefail

export UV_NO_CACHE=1

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== Running render.py unit tests ==="
uv run scripts/test_render.py

echo ""
echo "=== Running API Gateway account ownership tests ==="
uv run scripts/test_api_gateway_account_ownership.py

echo ""
echo "=== Running promtool rule tests ==="
./ci/promtool-test.sh

# Last on purpose: this guard is about a future PR's checkout, never this run's,
# so a problem here must not mask the test results above.
echo ""
echo "=== Running submodule fetch-recursion check ==="
./ci/check-submodule-fetch-config.sh

echo ""
echo "=== Running Helm lock / vendored tgz check ==="
./ci/check-helm-locks.sh
