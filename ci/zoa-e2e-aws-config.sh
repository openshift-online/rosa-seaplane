#!/usr/bin/env bash
#
# ZOA Access e2e: copy the Prow-mounted aws_config and add role_session_name on
# rrp-central. Go aws-sdk-go-v2 honors that profile field (not AWS_ROLE_SESSION_NAME).
# Does not touch Vault/GCP — only the runtime copy in this pod.

prepare_zoa_e2e_aws_config() {
  [[ -n "${ZOA_E2E_AWS_CONFIG_READY:-}" ]] && return 0
  [[ -r "${AWS_CONFIG_FILE:-}" ]] || return 0

  local session="${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e}"
  if aws configure get role_session_name --profile rrp-central 2>/dev/null | grep -q .; then
    export ZOA_E2E_AWS_CONFIG_READY=1
    return 0
  fi

  local dir out
  dir=$(mktemp -d)
  out="${dir}/config"
  cp "${AWS_CONFIG_FILE}" "$out"
  sed -i "/^\[profile rrp-central\]/a role_session_name = ${session}" "$out"
  export AWS_CONFIG_FILE="$out"
  export ZOA_E2E_AWS_CONFIG_READY=1
}
