#!/usr/bin/env bash
# Terraform workflow helpers for rosa-seaplane provision scripts.
#
# Usage:
#   source scripts/pipeline-common/lib.sh
#   source scripts/pipeline-common/terraform-lib.sh
#
# This library provides reusable functions for common Terraform operations:
# - Backend initialization
# - Apply/destroy with static tfvars
# - Output polling and reading
# - AWS Secrets Manager and SSM helpers
#
# All functions follow error-first design: return non-zero on failure,
# print errors to stderr, allow caller to decide whether to exit.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Function: tf_init_backend
# Initialize Terraform backend with S3 remote state.
#
# Args:
#   $1 - Terraform directory (relative or absolute path)
#   $2 - S3 bucket name for state
#   $3 - S3 key (path within bucket)
#   $4 - AWS region for state bucket
#
# Returns:
#   0 on success, non-zero on failure
#
# Example:
#   tf_init_backend \
#       terraform/config/regional-cluster \
#       "terraform-state-123456789012-us-east-1" \
#       "regional-cluster/use1.tfstate" \
#       "us-east-1"
# ──────────────────────────────────────────────────────────────────────────────
tf_init_backend() {
    local tf_dir=$1
    local state_bucket=$2
    local state_key=$3
    local state_region=$4

    if [ ! -d "${tf_dir}" ]; then
        echo "ERROR: Terraform directory not found: ${tf_dir}" >&2
        return 1
    fi

    echo "Initializing Terraform backend in ${tf_dir}..."
    echo "  State: s3://${state_bucket}/${state_key}"

    terraform -chdir="${tf_dir}" init -reconfigure \
        -backend-config="bucket=${state_bucket}" \
        -backend-config="key=${state_key}" \
        -backend-config="region=${state_region}" \
        -backend-config="use_lockfile=true"
}

# ──────────────────────────────────────────────────────────────────────────────
# Function: tf_apply_with_static_vars
# Run terraform apply or destroy with static.tfvars.json.
# Sources imports.sh if present (apply only).
#
# Args:
#   $1 - Terraform directory
#   $2 - Action (apply or destroy)
#   $3 - Path to static.tfvars.json
#   $@ - Additional terraform arguments (passed through)
#
# Returns:
#   0 on success, non-zero on failure
#
# Example:
#   tf_apply_with_static_vars \
#       terraform/config/regional-cluster \
#       apply \
#       deploy/integration/us-east-1/pipeline-regional-cluster-inputs/static.tfvars.json
# ──────────────────────────────────────────────────────────────────────────────
tf_apply_with_static_vars() {
    local tf_dir=$1
    local action=$2
    local static_tfvars=$3
    shift 3
    local extra_args=("$@")

    if [ ! -d "${tf_dir}" ]; then
        echo "ERROR: Terraform directory not found: ${tf_dir}" >&2
        return 1
    fi

    if [ ! -f "${static_tfvars}" ]; then
        echo "ERROR: Static tfvars file not found: ${static_tfvars}" >&2
        return 1
    fi

    # Terraform resolves -var-file relative to the -chdir directory. Convert
    # the repository-relative path to an absolute path before invoking it.
    local static_tfvars_abs
    static_tfvars_abs="$(cd "$(dirname "${static_tfvars}")" && pwd -P)/$(basename "${static_tfvars}")"

    echo "Running terraform ${action} in ${tf_dir}..."
    echo "  Static vars: ${static_tfvars}"

    # Source imports if present (for apply only)
    if [ "${action}" == "apply" ] && [ -f "${tf_dir}/imports.sh" ]; then
        echo "  Sourcing ${tf_dir}/imports.sh for state imports"
        (
            cd "${tf_dir}"
            # Imports evaluate the same configuration as apply, including its
            # required static variables. Scope the flag to this subshell.
            export TF_CLI_ARGS_import="${TF_CLI_ARGS_import:-} -var-file=\"${static_tfvars_abs}\""
            source imports.sh
        )
    fi

    terraform -chdir="${tf_dir}" "${action}" \
        -var-file="${static_tfvars_abs}" \
        "${extra_args[@]}" \
        -auto-approve
}

# Validate that a generated static tfvars file contains the named keys. This
# catches stale/incomplete rendered config before dynamic runtime values are
# layered on by the buildspec.
tf_require_static_keys() {
    local static_tfvars="$1"
    local context="$2"
    shift 2
    local missing=()
    local name

    if [ ! -f "${static_tfvars}" ]; then
        echo "ERROR: Static tfvars file not found for ${context}: ${static_tfvars}" >&2
        return 1
    fi

    for name in "$@"; do
        if ! jq -e --arg name "$name" \
            'has($name) and .[$name] != null' "${static_tfvars}" >/dev/null; then
            missing+=("$name")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing ${context} static parameters in ${static_tfvars}: ${missing[*]}" >&2
        return 1
    fi
}

# Validate that the named static tfvars are present and non-empty. Booleans and
# numbers are accepted as valid values; only empty strings are rejected.
tf_require_static_vars() {
    local static_tfvars="$1"
    local context="$2"
    shift 2
    local missing=()
    local name

    if [ ! -f "${static_tfvars}" ]; then
        echo "ERROR: Static tfvars file not found for ${context}: ${static_tfvars}" >&2
        return 1
    fi

    for name in "$@"; do
        if ! jq -e --arg name "$name" \
            'has($name) and .[$name] != null and
             (if (.[$name] | type) == "string" then (.[$name] | length) > 0 else true end)' \
            "${static_tfvars}" >/dev/null; then
            missing+=("$name")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required ${context} static parameters in ${static_tfvars}: ${missing[*]}" >&2
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Function: tf_wait_for_outputs
# Poll terraform outputs until all required outputs are non-empty.
# Automatically exports outputs as TF_VAR_<name> environment variables.
#
# Args:
#   $1 - Terraform directory to read outputs from
#   $2 - Maximum number of retry attempts
#   $3 - Retry delay in seconds
#   $@ - List of output names to wait for
#
# Returns:
#   0 if all outputs found within max attempts, 1 if timeout
#
# Side effects:
#   Sets TF_VAR_<output_name> environment variables for each output
#
# Example:
#   # Wait up to 45 minutes (90 attempts * 30s) for RC OIDC outputs
#   tf_wait_for_outputs \
#       terraform/config/regional-cluster \
#       90 \
#       30 \
#       oidc_cloudfront_domain \
#       oidc_bucket_name \
#       oidc_bucket_arn \
#       oidc_bucket_region
#
#   # Now TF_VAR_oidc_cloudfront_domain etc are exported
# ──────────────────────────────────────────────────────────────────────────────
tf_wait_for_outputs() {
    local tf_dir=$1
    local max_attempts=$2
    local retry_delay=$3
    shift 3
    local output_names=("$@")

    if [ ! -d "${tf_dir}" ]; then
        echo "ERROR: Terraform directory not found: ${tf_dir}" >&2
        return 1
    fi

    if [ ${#output_names[@]} -eq 0 ]; then
        echo "ERROR: No output names provided to tf_wait_for_outputs" >&2
        return 1
    fi

    local attempt=0
    local total_wait_min=$((max_attempts * retry_delay / 60))

    echo "Waiting for ${#output_names[@]} Terraform outputs from ${tf_dir}..."
    echo "  Outputs: ${output_names[*]}"
    echo "  Max wait: ${total_wait_min} minutes (${max_attempts} attempts * ${retry_delay}s)"

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        local all_present=true
        local missing_outputs=()
        local outputs_json

        outputs_json=$(terraform -chdir="${tf_dir}" output -json 2>/dev/null || true)

        for output_name in "${output_names[@]}"; do
            local value
            value=$(jq -r --arg name "${output_name}" '.[$name].value // empty' <<<"${outputs_json}" 2>/dev/null || true)

            if [ -z "${value}" ]; then
                all_present=false
                missing_outputs+=("${output_name}")
            else
                # Export as TF_VAR_<name> for terraform consumption
                export "TF_VAR_${output_name}=${value}"
            fi
        done

        if [ "${all_present}" == "true" ]; then
            echo "✓ All outputs ready (attempt ${attempt}/${max_attempts})"
            return 0
        fi

        echo "  Outputs not ready (attempt ${attempt}/${max_attempts}), missing: ${missing_outputs[*]}"
        echo "  Retrying in ${retry_delay}s..."
        sleep "${retry_delay}"
    done

    # Timeout - list what's still missing
    echo "ERROR: Terraform outputs missing after ${total_wait_min}+ minutes" >&2
    echo "  Terraform directory: ${tf_dir}" >&2
    echo "  Expected outputs: ${output_names[*]}" >&2

    local outputs_json
    outputs_json=$(terraform -chdir="${tf_dir}" output -json 2>/dev/null || true)
    for output_name in "${output_names[@]}"; do
        local value
        value=$(jq -r --arg name "${output_name}" '.[$name].value // empty' <<<"${outputs_json}" 2>/dev/null || true)
        if [ -z "${value}" ]; then
            echo "    ✗ ${output_name}: NOT FOUND" >&2
        else
            echo "    ✓ ${output_name}: available" >&2
        fi
    done

    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Function: tf_read_output
# Read a single terraform output (no polling, immediate read).
# Optionally validate with a grep pattern (e.g., ARN format check).
#
# Args:
#   $1 - Terraform directory
#   $2 - Output name
#   $3 - (Optional) Grep pattern to validate output (e.g., '^arn:')
#
# Returns:
#   0 on success (prints output value to stdout), 1 if not found or pattern mismatch
#
# Example:
#   # Read ZOA bucket ARN, validate it looks like an ARN
#   arn=$(tf_read_output terraform/config/regional-cluster zoa_bucket_arn '^arn:')
#   export TF_VAR_zoa_bucket_arn="${arn}"
#
#   # Read without validation
#   domain=$(tf_read_output terraform/config/regional-cluster oidc_cloudfront_domain)
# ──────────────────────────────────────────────────────────────────────────────
tf_read_output() {
    local tf_dir=$1
    local output_name=$2
    local grep_pattern=${3:-}

    if [ ! -d "${tf_dir}" ]; then
        echo "ERROR: Terraform directory not found: ${tf_dir}" >&2
        return 1
    fi

    local outputs_json
    outputs_json=$(terraform -chdir="${tf_dir}" output -json 2>/dev/null || true)
    local value
    value=$(jq -r --arg name "${output_name}" '.[$name].value // empty' <<<"${outputs_json}" 2>/dev/null || true)

    if [ -z "${value}" ]; then
        return 1  # Output not found, return empty (not an error - caller decides)
    fi

    # Optional pattern validation (e.g., validate ARN format)
    if [ -n "${grep_pattern}" ]; then
        if ! echo "${value}" | grep -qE "${grep_pattern}"; then
            echo "WARN: Output '${output_name}' does not match pattern '${grep_pattern}'" >&2
            return 1
        fi
    fi

    echo "${value}"
}

# Validate required Terraform outputs after apply. Each output spec is either
# name or name|grep-pattern. Values are intentionally not printed because some
# Terraform outputs may contain sensitive material.
tf_validate_outputs() {
    local tf_dir="$1"
    local context="$2"
    shift 2
    local missing=()
    local spec output_name pattern value

    for spec in "$@"; do
        output_name="${spec%%|*}"
        pattern=""
        [[ "$spec" == *"|"* ]] && pattern="${spec#*|}"

        if [[ -n "$pattern" ]]; then
            if ! value=$(tf_read_output "${tf_dir}" "${output_name}" "${pattern}"); then
                missing+=("${output_name}")
                continue
            fi
        elif ! value=$(tf_read_output "${tf_dir}" "${output_name}"); then
            missing+=("${output_name}")
            continue
        fi
        echo "  ✓ ${context} output: ${output_name}"
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Required ${context} Terraform outputs are missing or invalid: ${missing[*]}" >&2
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Function: ssm_get_param
# Get an SSM parameter value.
#
# Args:
#   $1 - SSM parameter name (path)
#   $2 - AWS region
#   $3 - (Optional) "required" to exit on failure (default: return empty)
#
# Returns:
#   0 on success (prints value to stdout), 1 if not found
#
# Example:
#   # Required parameter (exit if not found)
#   ou_path=$(ssm_get_param "/infra/region-ou-path" "${TARGET_REGION}" required)
#
#   # Optional parameter (return empty if not found, caller checks)
#   cidrs=$(ssm_get_param "/infra/sre-ui-alb/allowed-cidrs" "${TARGET_REGION}")
#   if [ -z "${cidrs}" ]; then
#       echo "Using default CIDRs"
#   fi
# ──────────────────────────────────────────────────────────────────────────────
ssm_get_param() {
    local param_name=$1
    local region=$2
    local required=${3:-}

    local value=$(aws ssm get-parameter \
        --name "${param_name}" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --region "${region}" 2>/dev/null || true)

    if [ -z "${value}" ]; then
        if [ "${required}" == "required" ]; then
            echo "ERROR: Required SSM parameter not found: ${param_name} (region: ${region})" >&2
            return 1
        fi
        return 1  # Not found, but not required - caller decides
    fi

    echo "${value}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Function: ssm_get_param_with_fallback
# Get SSM parameter, trying multiple paths in order (new → legacy).
# First successful path wins.
#
# Args:
#   $1 - AWS region
#   $@ - SSM parameter paths to try (in order of preference)
#
# Returns:
#   0 on success (prints value to stdout), 1 if none found
#
# Example:
#   # Try new nested path, fall back to legacy flat path
#   mc_ou_path=$(ssm_get_param_with_fallback \
#       "${TARGET_REGION}" \
#       "/infra/${ENVIRONMENT}/${TARGET_REGION}/ou-path" \
#       "/infra/region-ou-path") || {
#       echo "ERROR: MC OU path not found in SSM" >&2
#       exit 1
#   }
#   export TF_VAR_mc_ou_path="${mc_ou_path}"
# ──────────────────────────────────────────────────────────────────────────────
ssm_get_param_with_fallback() {
    local region=$1
    shift
    local paths=("$@")

    if [ ${#paths[@]} -eq 0 ]; then
        echo "ERROR: No SSM parameter paths provided" >&2
        return 1
    fi

    for path in "${paths[@]}"; do
        local value=$(ssm_get_param "${path}" "${region}")

        if [ -n "${value}" ]; then
            echo "INFO: SSM parameter found at ${path}" >&2
            echo "${value}"
            return 0
        fi
    done

    # None found - report all attempted paths
    echo "ERROR: SSM parameter not found at any of these paths (region: ${region}):" >&2
    printf '  - %s\n' "${paths[@]}" >&2
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Function: secrets_manager_get
# Get a Secrets Manager secret value.
#
# Args:
#   $1 - Secret ID (name or ARN)
#   $2 - AWS region
#   $3 - (Optional) "required" to exit on failure (default: return error)
#
# Returns:
#   0 on success (prints secret value to stdout), 1 if not found
#
# Example:
#   # Fetch OIDC client secrets for SRE UI
#   for svc in grafana argocd prometheus thanos; do
#       secret=$(secrets_manager_get "sre-ui-alb/${svc}/oidc-client-secret" "${TARGET_REGION}" required)
#       export "TF_VAR_sre_${svc}_oidc_client_secret=${secret}"
#   done
# ──────────────────────────────────────────────────────────────────────────────
secrets_manager_get() {
    local secret_id=$1
    local region=$2
    local required=${3:-}

    local value=$(aws secretsmanager get-secret-value \
        --secret-id "${secret_id}" \
        --region "${region}" \
        --query SecretString \
        --output text 2>/dev/null || true)

    if [ -z "${value}" ]; then
        if [ "${required}" == "required" ]; then
            echo "ERROR: Required Secrets Manager secret not found: ${secret_id} (region: ${region})" >&2
            return 1
        fi
        return 1  # Not found, but not required - caller decides
    fi

    echo "${value}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Function: tf_read_multiple_outputs
# Read multiple terraform outputs at once (no polling, immediate).
# Exports as TF_VAR_<name> environment variables.
#
# Args:
#   $1 - Terraform directory
#   $2 - (Optional) Grep pattern to validate all outputs (e.g., '^arn:' for ARNs)
#   $@ - Output names to read
#
# Returns:
#   0 if all outputs found, 1 if any missing or pattern mismatch
#
# Side effects:
#   Sets TF_VAR_<output_name> environment variables
#
# Example:
#   # Read all ZOA outputs from RC, validate ARN format
#   tf_read_multiple_outputs \
#       terraform/config/regional-cluster \
#       '^arn:' \
#       zoa_lambda_role_arn \
#       zoa_runner_ecr_url \
#       zoa_garbage_collector_role_arn || {
#       echo "ERROR: Failed to read ZOA outputs" >&2
#       exit 1
#   }
# ──────────────────────────────────────────────────────────────────────────────
tf_read_multiple_outputs() {
    local tf_dir=$1
    shift

    # Check if first arg is a grep pattern (starts with ^ or contains regex chars)
    local grep_pattern=""
    if [[ "$1" =~ ^[\^.*+?\[\]{}()|\\] ]]; then
        grep_pattern=$1
        shift
    fi

    local output_names=("$@")

    if [ ! -d "${tf_dir}" ]; then
        echo "ERROR: Terraform directory not found: ${tf_dir}" >&2
        return 1
    fi

    if [ ${#output_names[@]} -eq 0 ]; then
        echo "ERROR: No output names provided" >&2
        return 1
    fi

    local failed=false

    for output_name in "${output_names[@]}"; do
        local value
        if [ -n "${grep_pattern}" ]; then
            value=$(tf_read_output "${tf_dir}" "${output_name}" "${grep_pattern}") || failed=true
        else
            value=$(tf_read_output "${tf_dir}" "${output_name}") || failed=true
        fi

        if [ -n "${value}" ]; then
            export "TF_VAR_${output_name}=${value}"
        else
            echo "ERROR: Output '${output_name}' not found or validation failed" >&2
            failed=true
        fi
    done

    if [ "${failed}" == "true" ]; then
        return 1
    fi

    return 0
}
