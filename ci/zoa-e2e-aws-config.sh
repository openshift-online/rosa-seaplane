#!/usr/bin/env bash
#
# ZOA Access e2e only: materialize rrp-central (and sibling rrp-rc / rrp-mc when
# present) into static keys so the Go ZOA CLI sees a stable assumed-role session
# name across subprocesses. Dev already does this via write_container_config;
# Vault aws_config cannot gain role_session_name until GCP secret read is fixed.
#
# Sourced from ci/e2e-tests.sh immediately before make test-e2e* in rosa-seaplane-zoa.
# Does not change setup-aws-profiles or other CI jobs.

_zoa_e2e_resolve_base_creds() {
    local base_profile="$1"
    if [[ "${_ZOA_E2E_BASE_PROFILE:-}" == "$base_profile" ]]; then
        return 0
    fi
    local creds creds_err
    creds_err=$(mktemp)
    creds=$(aws configure export-credentials --profile "$base_profile" --format process 2>"$creds_err") \
        || {
            cat "$creds_err" >&2
            rm -f "$creds_err"
            return 1
        }
    rm -f "$creds_err"
    _ZOA_E2E_AK=$(echo "$creds" | jq -r '.AccessKeyId')
    _ZOA_E2E_SK=$(echo "$creds" | jq -r '.SecretAccessKey')
    _ZOA_E2E_ST=$(echo "$creds" | jq -r '.SessionToken // empty')
    _ZOA_E2E_BASE_PROFILE="$base_profile"
}

_zoa_e2e_assume_profile() {
    local profile="$1"
    local role_arn base_profile session_name creds creds_err
    role_arn=$(aws configure get role_arn --profile "$profile")
    base_profile=$(aws configure get source_profile --profile "$profile")
    _zoa_e2e_resolve_base_creds "$base_profile" || return 1
    session_name="${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e}"
    creds_err=$(mktemp)
    creds=$(AWS_ACCESS_KEY_ID="$_ZOA_E2E_AK" AWS_SECRET_ACCESS_KEY="$_ZOA_E2E_SK" AWS_SESSION_TOKEN="$_ZOA_E2E_ST" \
        aws sts assume-role --role-arn "$role_arn" --role-session-name "$session_name" \
        --duration-seconds 3600 --output json 2>"$creds_err") \
        || {
            cat "$creds_err" >&2
            rm -f "$creds_err"
            return 1
        }
    rm -f "$creds_err"
    _ZOA_E2E_AK=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
    _ZOA_E2E_SK=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
    _ZOA_E2E_ST=$(echo "$creds" | jq -r '.Credentials.SessionToken')
}

_zoa_e2e_export_profile() {
    local profile="$1"
    local creds creds_err
    creds_err=$(mktemp)
    creds=$(aws configure export-credentials --profile "$profile" --format process 2>"$creds_err") \
        || {
            cat "$creds_err" >&2
            rm -f "$creds_err"
            return 1
        }
    rm -f "$creds_err"
    _ZOA_E2E_AK=$(echo "$creds" | jq -r '.AccessKeyId')
    _ZOA_E2E_SK=$(echo "$creds" | jq -r '.SecretAccessKey')
    _ZOA_E2E_ST=$(echo "$creds" | jq -r '.SessionToken // empty')
}

# Args: profile names to include in the temp config (defaults: ephemeral set).
prepare_zoa_e2e_aws_config() {
    [[ -n "${ZOA_E2E_AWS_CONFIG_READY:-}" ]] && return 0
    [[ -n "${AWS_CONFIG_FILE:-}" && -r "${AWS_CONFIG_FILE}" ]] || {
        echo "ERROR: AWS_CONFIG_FILE not set for ZOA e2e AWS prep" >&2
        return 1
    }

    local -a want=(rrp-central rrp-rc rrp-mc)
    if [[ $# -gt 0 ]]; then
        want=("$@")
    fi

    local materialized_dir out first profile region role_arn
    materialized_dir=$(mktemp -d)
    out="${materialized_dir}/config"
    first=true

    for profile in "${want[@]}"; do
        if ! aws configure list-profiles 2>/dev/null | grep -qx "$profile"; then
            continue
        fi
        role_arn=$(aws configure get role_arn --profile "$profile" 2>/dev/null || true)
        if [[ "$profile" == "rrp-central" && -n "$role_arn" ]]; then
            _zoa_e2e_assume_profile "$profile" || {
                rm -rf "$materialized_dir"
                return 1
            }
        else
            _zoa_e2e_export_profile "$profile" || {
                rm -rf "$materialized_dir"
                return 1
            }
        fi
        region=$(aws configure get region --profile "$profile" 2>/dev/null || true)
        region="${region:-${AWS_DEFAULT_REGION:-us-east-1}}"

        [[ "$first" == "true" ]] || echo "" >>"$out"
        first=false
        cat >>"$out" <<EOF
[profile ${profile}]
aws_access_key_id = ${_ZOA_E2E_AK}
aws_secret_access_key = ${_ZOA_E2E_SK}
aws_session_token = ${_ZOA_E2E_ST}
region = ${region}
EOF
    done

    if [[ ! -s "$out" ]]; then
        rm -rf "$materialized_dir"
        echo "WARNING: no ZOA e2e AWS profiles materialized — using vault config" >&2
        return 0
    fi

    export AWS_CONFIG_FILE_BEFORE_ZOA_E2E="${AWS_CONFIG_FILE}"
    export AWS_CONFIG_FILE="$out"
    export AWS_SHARED_CREDENTIALS_FILE=/dev/null
    export ZOA_E2E_AWS_CONFIG_READY=1
    _zoa_e2e_aws_config_dir="$materialized_dir"
    echo "ZOA e2e AWS config ready (rrp-central session ${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e})"
}
