#!/usr/bin/env bash
#
# Resolve Vault/Prow aws_config assume-role profiles to static credentials with a
# stable STS RoleSessionName (same mechanism as scripts/dev/env-common.sh
# write_container_config). Required for Go aws-sdk-go-v2 consumers (ZOA CLI e2e):
# the SDK does not apply AWS_ROLE_SESSION_NAME to shared-config assume-role chains
# and otherwise generates a unique session name per process.
#
# Sourced by ci/setup-aws-profiles.sh and scripts/dev/env-common.sh — not executed directly.

# Resolve the base credentials from a profile (credential_process or static keys).
# Args: $1 = base profile name
# Sets: _BASE_AK, _BASE_SK, _BASE_ST
resolve_base_creds() {
    local base_profile="$1"
    if [[ "${_BASE_RESOLVED_PROFILE:-}" == "$base_profile" ]]; then
        return 0
    fi
    echo "Resolving base credentials for profile ${base_profile}..."
    local creds creds_err
    creds_err=$(mktemp)
    creds=$(aws configure export-credentials --profile "$base_profile" --format process 2>"$creds_err") \
        || {
            local err
            err=$(<"$creds_err")
            rm -f "$creds_err"
            echo "Failed to resolve base credentials (${base_profile}): ${err}" >&2
            return 1
        }
    rm -f "$creds_err"
    _BASE_AK=$(echo "$creds" | jq -r '.AccessKeyId')
    _BASE_SK=$(echo "$creds" | jq -r '.SecretAccessKey')
    _BASE_ST=$(echo "$creds" | jq -r '.SessionToken // empty')
    _BASE_RESOLVED_PROFILE="$base_profile"
}

# Assume role_arn from profile using base source_profile credentials.
# Args: $1 = profile name (must define role_arn + source_profile)
# Sets: _CRED_AK, _CRED_SK, _CRED_ST
resolve_creds() {
    local profile="$1"
    echo "Resolving credentials for profile ${profile}..."

    local role_arn base_profile
    role_arn=$(aws configure get role_arn --profile "$profile" 2>/dev/null) \
        || {
            echo "No role_arn found for profile ${profile}" >&2
            return 1
        }
    base_profile=$(aws configure get source_profile --profile "$profile" 2>/dev/null) \
        || {
            echo "No source_profile found for profile ${profile}" >&2
            return 1
        }

    resolve_base_creds "$base_profile" || return 1

    local creds creds_err session_name
    creds_err=$(mktemp)
    session_name="${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e}"
    creds=$(AWS_ACCESS_KEY_ID="$_BASE_AK" AWS_SECRET_ACCESS_KEY="$_BASE_SK" AWS_SESSION_TOKEN="$_BASE_ST" \
        aws sts assume-role --role-arn "$role_arn" --role-session-name "$session_name" \
        --duration-seconds 3600 --output json 2>"$creds_err") \
        || {
            local err
            err=$(<"$creds_err")
            rm -f "$creds_err"
            echo "Failed to assume role ${role_arn} for profile ${profile}: ${err}" >&2
            return 1
        }
    rm -f "$creds_err"
    _CRED_AK=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
    _CRED_SK=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
    _CRED_ST=$(echo "$creds" | jq -r '.Credentials.SessionToken')
}

# Export a profile's effective credentials (static profile or already-assumed keys).
# Sets: _CRED_AK, _CRED_SK, _CRED_ST
resolve_profile_to_static() {
    local profile="$1"
    local role_arn
    role_arn=$(aws configure get role_arn --profile "$profile" 2>/dev/null || true)
    if [[ -n "$role_arn" ]]; then
        resolve_creds "$profile"
        return $?
    fi

    echo "Exporting static credentials for profile ${profile}..."
    local creds creds_err
    creds_err=$(mktemp)
    creds=$(aws configure export-credentials --profile "$profile" --format process 2>"$creds_err") \
        || {
            local err
            err=$(<"$creds_err")
            rm -f "$creds_err"
            echo "Failed to export credentials for profile ${profile}: ${err}" >&2
            return 1
        }
    rm -f "$creds_err"
    _CRED_AK=$(echo "$creds" | jq -r '.AccessKeyId')
    _CRED_SK=$(echo "$creds" | jq -r '.SecretAccessKey')
    _CRED_ST=$(echo "$creds" | jq -r '.SessionToken // empty')
}

# Rewrite AWS_CONFIG_FILE with static keys per profile so Go SDK subprocesses share
# the same assumed-role session name (ZOA Access operator / identity bridge).
#
# Opt out: CI_MATERIALIZE_AWS_PROFILES=false
materialize_aws_profiles_for_go_sdk() {
    [[ "${CI_MATERIALIZE_AWS_PROFILES:-true}" == "true" ]] || return 0
    [[ -n "${AWS_CONFIG_FILE_MATERIALIZED:-}" ]] && return 0
    [[ -n "${AWS_CONFIG_FILE:-}" && -r "${AWS_CONFIG_FILE}" ]] || return 0

    local profile
    local -a profiles=()
    while IFS= read -r profile; do
        [[ -n "$profile" ]] && profiles+=("$profile")
    done < <(aws configure list-profiles 2>/dev/null)

    if [[ ${#profiles[@]} -eq 0 ]]; then
        echo "WARNING: no AWS profiles to materialize in ${AWS_CONFIG_FILE}" >&2
        return 0
    fi

    local materialized_dir out first region
    materialized_dir=$(mktemp -d)
    out="${materialized_dir}/config"
    first=true

    for profile in "${profiles[@]}"; do
        resolve_profile_to_static "$profile" || {
            rm -rf "$materialized_dir"
            return 1
        }
        region=$(aws configure get region --profile "$profile" 2>/dev/null || true)
        region="${region:-${AWS_DEFAULT_REGION:-us-east-1}}"

        [[ "$first" == "true" ]] || echo "" >>"$out"
        first=false

        cat >>"$out" <<EOF
[profile ${profile}]
aws_access_key_id = ${_CRED_AK}
aws_secret_access_key = ${_CRED_SK}
aws_session_token = ${_CRED_ST}
region = ${region}
EOF
    done

    export AWS_CONFIG_FILE_ORIGINAL="${AWS_CONFIG_FILE}"
    export AWS_CONFIG_FILE="$out"
    export AWS_SHARED_CREDENTIALS_FILE=/dev/null
    export AWS_CONFIG_FILE_MATERIALIZED=1

    if [[ -z "${AWS_MATERIALIZED_CONFIG_CLEANUP_REGISTERED:-}" ]]; then
        AWS_MATERIALIZED_CONFIG_CLEANUP_REGISTERED=1
        # shellcheck disable=SC2064
        trap 'rm -rf "${_aws_materialized_config_dir:-}"' EXIT
    fi
    _aws_materialized_config_dir="$materialized_dir"

    echo "Materialized AWS profiles for Go SDK e2e (${#profiles[@]} profiles, session ${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e})"
}
