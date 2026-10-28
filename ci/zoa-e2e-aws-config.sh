#!/usr/bin/env bash
#
# ZOA e2e on CI: build the same static AWS config as dev (write_container_config +
# resolve_creds / sts assume-role with seaplane-e2e). Go zoa still uses the SDK;
# it just reads fixed keys instead of re-assuming from Vault role chains each process.

prepare_zoa_e2e_aws_config() {
  [[ -n "${ZOA_E2E_AWS_CONFIG_READY:-}" ]] && return 0
  [[ -r "${AWS_CONFIG_FILE:-}" ]] || return 0

  local repo_root central region p
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  central="${ZOA_CENTRAL_AWS_PROFILE:-rrp-central}"
  region="${AWS_DEFAULT_REGION:-us-east-1}"

  # shellcheck source=../scripts/dev/env-common.sh
  source "${repo_root}/scripts/dev/env-common.sh"

  local -a specs=("${central} ${central} ${region}")
  for p in rrp-rc rrp-mc; do
    if aws configure list-profiles 2>/dev/null | grep -qx "$p"; then
      specs+=("${p} ${p} ${region}")
    fi
  done

  write_container_config "${specs[@]}"
  export AWS_CONFIG_FILE="$_CONTAINER_CONFIG"
  export AWS_SHARED_CREDENTIALS_FILE=/dev/null
  export ZOA_E2E_AWS_CONFIG_READY=1
  echo "ZOA e2e AWS config ready (static profiles, central=${central}, session ${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e})"
}
