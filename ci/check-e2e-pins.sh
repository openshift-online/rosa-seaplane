#!/bin/bash
# CI entrypoint for the e2e suite pin registry check (ROSAENG-75286).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
make check-e2e-pins
