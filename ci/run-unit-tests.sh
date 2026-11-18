#!/bin/bash
# CI entrypoint for unit tests.
set -euo pipefail

export UV_NO_CACHE=1

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== Running render.py unit tests ==="
uv run scripts/test_render.py

echo ""
echo "=== Running promtool rule tests ==="
./ci/promtool-test.sh

echo ""
echo "=== Running Helm lock / vendored tgz check ==="
./ci/check-helm-locks.sh
