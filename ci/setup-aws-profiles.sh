#!/usr/bin/env bash
#
# Configure AWS profiles from a pre-built config file in CI credentials.
#
# In CI (Prow), credentials are mounted under CREDS_DIR (default:
# /var/run/rosa-credentials/). This script expects an "aws_config" file
# containing named AWS CLI profiles. It sets AWS_CONFIG_FILE so all
# downstream consumers (aws.py, e2e-tests.sh, load tests) pick them up.
#
# Usage:
#   source ci/setup-aws-profiles.sh

set -euo pipefail

# Stable STS RoleSessionName for host-side aws sts assume-role (materialization below
# and scripts/dev/env-common.sh resolve_creds). AWS CLI honors AWS_ROLE_SESSION_NAME
# for profile assume-role; Go aws-sdk-go-v2 does not — see materialize step.
export AWS_ROLE_SESSION_NAME="${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e}"

_SETUP_AWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aws-profile-resolve.sh
source "${_SETUP_AWS_DIR}/aws-profile-resolve.sh"

_finish_setup_aws_profiles() {
  materialize_aws_profiles_for_go_sdk || return 1
}

CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"

# Already configured (e.g. local dev container mount) — skip path setup only.
if [[ -n "${AWS_CONFIG_FILE:-}" ]]; then
  _finish_setup_aws_profiles
  return 0 2>/dev/null || exit 0
fi

if [[ ! -r "${CREDS_DIR}/aws_config" ]]; then
  echo "Error: ${CREDS_DIR}/aws_config not found or not readable" >&2
  return 1 2>/dev/null || exit 1
fi

export AWS_CONFIG_FILE="${CREDS_DIR}/aws_config"
echo "AWS profiles configured (config: ${AWS_CONFIG_FILE})"
_finish_setup_aws_profiles
