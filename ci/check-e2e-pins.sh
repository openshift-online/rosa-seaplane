#!/bin/bash
# CI entrypoint for the e2e suite pin registry check (ROSAENG-75286).
#
# Escape hatch: add the "skip-pin-ancestry" label to the PR to bypass
# the P2 ancestry check.  This is intended for rollback PRs during
# incidents — the label makes the override visible in the PR timeline.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

E2E_PIN_ARGS=""

# When running in a Prow PR job, PULL_NUMBER is set.  Check for the
# "skip-pin-ancestry" label to bypass the P2 ancestry check (rollback
# escape hatch).
if [[ -n "${PULL_NUMBER:-}" && -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
  # Prow injects these vars; use the GitHub API (unauthenticated —
  # public repo, label list is small).
  labels=$(curl -fsSL \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/issues/${PULL_NUMBER}/labels" \
    2>/dev/null | python3 -c "import json,sys; print(' '.join(l['name'] for l in json.load(sys.stdin)))" \
    2>/dev/null || true)
  if echo "$labels" | grep -qw "skip-pin-ancestry"; then
    echo "⚠️  skip-pin-ancestry label detected — skipping P2 ancestry check"
    E2E_PIN_ARGS="--skip-ancestry"
  fi
fi

make check-e2e-pins E2E_PIN_ARGS="${E2E_PIN_ARGS}"
