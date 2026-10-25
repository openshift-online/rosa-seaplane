#!/usr/bin/env bash
# Provision or destroy Management Cluster infrastructure.
# Called from: scripts/buildspec/provision-cluster.sh
set -euo pipefail

source scripts/pipeline-common/lib.sh
source scripts/pipeline-common/terraform-lib.sh

preflight_check
config_load management

_REPO_BRANCH="${REPOSITORY_BRANCH:-main}"
_ZOA_LAMBDA_IMAGE_TAG=$(jq -r '.zoa_lambda_image_tag // empty' "$DEPLOY_CONFIG_FILE")

require_nonempty_vars "MC core runtime" \
    TARGET_ACCOUNT_ID TARGET_REGION MANAGEMENT_ID REGIONAL_AWS_ACCOUNT_ID \
    REPOSITORY_URL PLATFORM_IMAGE
validate_aws_account_id "TARGET_ACCOUNT_ID" "${TARGET_ACCOUNT_ID}"
validate_aws_account_id "REGIONAL_AWS_ACCOUNT_ID" "${REGIONAL_AWS_ACCOUNT_ID}"
tf_require_nonempty_json_vars "${DEPLOY_CONFIG_FILE}" "MC core" \
    management_id app_code service_phase cost_center zoa_deployment_name \
    zoa_boundary_image_tag zoa_boundary_source_image
tf_require_json_vars "${DEPLOY_CONFIG_FILE}" "MC" \
    zoa_lambda_image_tag zoa_runner_image_tag zoa_runner_source_image \
    worker_node_ami_id worker_node_root_volume_size \
    zoa_boundary_session_idle_timeout_seconds zoa_boundary_session_stale_creating_seconds \
    zoa_lambda_api_concurrency zoa_lambda_worker_concurrency

_CONFIG_MANAGEMENT_ID=$(jq -r '.management_id // empty' "${DEPLOY_CONFIG_FILE}")
if [[ "${_CONFIG_MANAGEMENT_ID}" != "${MANAGEMENT_ID}" ]]; then
    echo "ERROR: MC management_id mismatch: config=${_CONFIG_MANAGEMENT_ID}, runtime=${MANAGEMENT_ID}" >&2
    exit 1
fi
if [[ "${IS_DESTROY:-false}" != "true" ]]; then
    tf_require_nonempty_json_vars "${DEPLOY_CONFIG_FILE}" "MC ZOA" \
        zoa_lambda_image_tag zoa_runner_image_tag zoa_runner_source_image
fi

# Terraform configuration values come from the rendered deployment JSON.
tf_export_json_vars "${DEPLOY_CONFIG_FILE}" \
    app_code service_phase cost_center management_id enable_bastion \
    zoa_lambda_image_tag zoa_runner_image_tag zoa_runner_source_image \
    zoa_boundary_session_idle_timeout_seconds zoa_boundary_session_stale_creating_seconds \
    zoa_lambda_api_concurrency zoa_lambda_worker_concurrency zoa_deployment_name \
    worker_node_ami_id worker_node_root_volume_size
_zoa_boundary_image_tag=$(jq -r '.zoa_boundary_image_tag // ""' "$DEPLOY_CONFIG_FILE")
_zoa_boundary_source_image=$(jq -r '.zoa_boundary_source_image // ""' "$DEPLOY_CONFIG_FILE")
export TF_VAR_zoa_boundary_image="${_zoa_boundary_source_image}:${_zoa_boundary_image_tag}"

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

# Determine terraform action
DELETE_FLAG="${IS_DESTROY:-false}"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

echo "MC ${MANAGEMENT_ID}: terraform ${TERRAFORM_ACTION} in ${TARGET_ACCOUNT_ID}/${TARGET_REGION}"

# ── Phase 1: Read OIDC outputs from RC account ─────────────────────────────
if [ "${DELETE_FLAG}" == "true" ]; then
    # Provide placeholders so terraform destroy can pass the planning phase.
    export TF_VAR_oidc_cloudfront_domain="placeholder"
    export TF_VAR_oidc_bucket_name="placeholder"
    export TF_VAR_oidc_bucket_arn="arn:aws:s3:::placeholder"
    export TF_VAR_oidc_bucket_region="us-east-1"
    export TF_VAR_zoa_lambda_ecr_url="000000000000.dkr.ecr.us-east-1.amazonaws.com/placeholder"
    export TF_VAR_zoa_access_lambda_role_arn="arn:aws:iam::000000000000:role/destroy-placeholder"
else
    # Assume child admin role in RC account to access state bucket (scoped access instead of org-wide).
    _resolve_rc_account
    RESOLVED_REGIONAL_ACCOUNT_ID="${_RESOLVED_RC_ACCOUNT_ID}"
    echo "Assuming ${CHILD_ADMIN_ROLE_NAME} in RC account ${RESOLVED_REGIONAL_ACCOUNT_ID} for state access..."
    _rc_creds=$(aws sts assume-role \
        --role-arn "arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${CHILD_ADMIN_ROLE_NAME}" \
        --role-session-name "mc-read-rc-state-${MANAGEMENT_ID}" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text)

    _RC_CONFIG_FILE=$(config_path_for_mode regional)
    _RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "$_RC_CONFIG_FILE" 2>/dev/null || echo "regional")
    wait_for_rc_outputs() {
        local tf_dir="$1" max_attempts="$2" retry_delay="$3"
        shift 3
        local output_names=("$@")
        local attempt

        echo "Waiting for ${#output_names[@]} required RC Terraform outputs..."
        echo "  Max wait: $((max_attempts * retry_delay / 60)) minutes (${max_attempts} attempts * ${retry_delay}s)"

        for ((attempt = 1; attempt <= max_attempts; attempt++)); do
            if tf_wait_for_outputs "${tf_dir}" 1 0 "${output_names[@]}"; then
                echo "✓ Required RC outputs are ready; MC will continue while RC finishes"
                return 0
            fi

            if [[ ${attempt} -lt ${max_attempts} ]]; then
                echo "  RC dependency/output not ready (attempt ${attempt}/${max_attempts}); retrying in ${retry_delay}s..."
                sleep "${retry_delay}"
            fi
        done

        echo "ERROR: Required RC outputs were not ready after $((max_attempts * retry_delay / 60))+ minutes" >&2
        return 1
    }

    export DNS_ZONE_OPERATOR_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-dns-zone-operator"
    export OIDC_WRITER_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-oidc-writer"
    export OIDC_KEY_READER_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-oidc-key-reader"

    # Read OIDC outputs from RC terraform state. RC and MC pipelines run in
    # parallel — retry until the outputs appear or we timeout (45 min).
    _RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
    _RC_STATE_KEY="regional-cluster/${_RC_REGIONAL_ID}.tfstate"
    _RC_TF_DIR="terraform/config/regional-cluster"
    AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') \
    AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') \
    AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') \
    terraform -chdir="$_RC_TF_DIR" init -reconfigure \
        -backend-config="bucket=${_RC_STATE_BUCKET}" \
        -backend-config="key=${_RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true" >/dev/null 2>&1

    # RC and MC pipelines run in parallel — wait for all outputs consumed by MC
    # Terraform to appear. Seaplane always deploys the full ZOA stack, so its
    # RC outputs are required for every MC apply.
    # rhobs_api_url is NOT consumed by MC terraform (only re-emitted at outputs.tf);
    # bootstrap-argocd-mc.sh already polls it before ArgoCD bootstrap.

    # Set RC credentials for tf_wait_for_outputs (library reads terraform state)
    export AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}')

    _RC_REQUIRED_OUTPUTS=(
        oidc_cloudfront_domain
        oidc_bucket_name
        oidc_bucket_arn
        oidc_bucket_region
        zoa_bucket_arn
        zoa_kms_key_arn
        zoa_table_name
        zoa_audit_table_name
        zoa_sessions_table_name
        zoa_uploader_role_arn
        zoa_data_access_role_arn
        zoa_access_lambda_role_arn
        zoa_lambda_ecr_url
    )

    # Wait up to 45 minutes (90 attempts * 30s) for all required RC outputs.
    # MC starts consuming them as soon as they are available; RC may continue
    # with its remaining bootstrap/readiness steps in parallel. If RC fails
    # before the outputs are ready, the output wait expires and the MC build
    # reports the missing outputs.
    wait_for_rc_outputs \
        "$_RC_TF_DIR" \
        90 \
        30 \
        "${_RC_REQUIRED_OUTPUTS[@]}" || {
        echo "ERROR: Failed to read required RC outputs for MC provisioning" >&2
        exit 1
    }
    # TF_VAR_* variables auto-exported by tf_wait_for_outputs

    # Read ZOA outputs with validation after the wait above. These values
    # are required by the MC Lambda module and must not be silently empty.
    TF_VAR_zoa_outputs_bucket_arn=$(tf_read_output "$_RC_TF_DIR" zoa_bucket_arn '^arn:')
    export TF_VAR_zoa_outputs_bucket_arn

    TF_VAR_zoa_kms_key_arn=$(tf_read_output "$_RC_TF_DIR" zoa_kms_key_arn '^arn:')
    export TF_VAR_zoa_kms_key_arn

    # ZOA Lambda data-layer outputs (DynamoDB tables + uploader role in RC account)
    TF_VAR_zoa_table_name=$(tf_read_output "$_RC_TF_DIR" zoa_table_name)
    export TF_VAR_zoa_table_name

    TF_VAR_zoa_audit_table_name=$(tf_read_output "$_RC_TF_DIR" zoa_audit_table_name)
    export TF_VAR_zoa_audit_table_name

    TF_VAR_zoa_sessions_table_name=$(tf_read_output "$_RC_TF_DIR" zoa_sessions_table_name)
    export TF_VAR_zoa_sessions_table_name

    TF_VAR_zoa_access_lambda_role_arn=$(tf_read_output "$_RC_TF_DIR" zoa_access_lambda_role_arn '^arn:')
    export TF_VAR_zoa_access_lambda_role_arn

    TF_VAR_zoa_uploader_role_arn=$(tf_read_output "$_RC_TF_DIR" zoa_uploader_role_arn '^arn:')
    export TF_VAR_zoa_uploader_role_arn

    TF_VAR_zoa_data_access_role_arn=$(tf_read_output "$_RC_TF_DIR" zoa_data_access_role_arn '^arn:')
    export TF_VAR_zoa_data_access_role_arn

    # Lambda image lives in RC's ECR (cross-account pull via OU policy).
    TF_VAR_zoa_lambda_ecr_url=$(tf_read_output "$_RC_TF_DIR" zoa_lambda_ecr_url)
    export TF_VAR_zoa_lambda_ecr_url

    require_nonempty_vars "MC RC dependency" \
        TF_VAR_oidc_cloudfront_domain TF_VAR_oidc_bucket_name \
        TF_VAR_oidc_bucket_arn TF_VAR_oidc_bucket_region \
        DNS_ZONE_OPERATOR_ROLE_ARN OIDC_WRITER_ROLE_ARN OIDC_KEY_READER_ROLE_ARN
    validate_arn_account "DNS_ZONE_OPERATOR_ROLE_ARN" \
        "${DNS_ZONE_OPERATOR_ROLE_ARN}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    validate_arn_account "OIDC_WRITER_ROLE_ARN" \
        "${OIDC_WRITER_ROLE_ARN}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    validate_arn_account "OIDC_KEY_READER_ROLE_ARN" \
        "${OIDC_KEY_READER_ROLE_ARN}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    require_nonempty_vars "MC ZOA RC dependency" \
        TF_VAR_zoa_outputs_bucket_arn TF_VAR_zoa_kms_key_arn \
        TF_VAR_zoa_table_name TF_VAR_zoa_audit_table_name TF_VAR_zoa_sessions_table_name \
        TF_VAR_zoa_uploader_role_arn TF_VAR_zoa_data_access_role_arn \
        TF_VAR_zoa_access_lambda_role_arn TF_VAR_zoa_lambda_ecr_url
    validate_arn_account "TF_VAR_zoa_kms_key_arn" \
        "${TF_VAR_zoa_kms_key_arn}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    validate_arn_account "TF_VAR_zoa_access_lambda_role_arn" \
        "${TF_VAR_zoa_access_lambda_role_arn}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    validate_arn_account "TF_VAR_zoa_uploader_role_arn" \
        "${TF_VAR_zoa_uploader_role_arn}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
    validate_arn_account "TF_VAR_zoa_data_access_role_arn" \
        "${TF_VAR_zoa_data_access_role_arn}" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
fi

# Image and timeout Terraform values were exported from the rendered config above.

# ── Phase 2: Apply/Destroy MC infrastructure ─────────────────────────────────
# provision-cluster.sh registers the MC ZOA target after this step.
use_mc_account

export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="management-cluster/${MANAGEMENT_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

# Configured Terraform values are exported from the rendered deployment JSON.
export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_environment="${ENVIRONMENT:-staging}"
export TF_VAR_regional_aws_account_id="${RESOLVED_REGIONAL_ACCOUNT_ID}"

export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

export TF_VAR_container_image="${PLATFORM_IMAGE}"

if [ -n "${DNS_ZONE_OPERATOR_ROLE_ARN:-}" ]; then
    export TF_VAR_dns_zone_operator_role_arn="${DNS_ZONE_OPERATOR_ROLE_ARN}"
fi
if [ -n "${OIDC_WRITER_ROLE_ARN:-}" ]; then
    export TF_VAR_oidc_writer_role_arn="${OIDC_WRITER_ROLE_ARN}"
fi
if [ -n "${OIDC_KEY_READER_ROLE_ARN:-}" ]; then
    export TF_VAR_oidc_key_reader_role_arn="${OIDC_KEY_READER_ROLE_ARN}"
fi

export REGION_DEPLOYMENT=$(jq -r '.region' "$DEPLOY_CONFIG_FILE")
export ENVIRONMENT="${ENVIRONMENT:-staging}"

validate_aws_account_id "RESOLVED_REGIONAL_ACCOUNT_ID" "${RESOLVED_REGIONAL_ACCOUNT_ID}"
require_nonempty_vars "MC Terraform runtime" \
    TF_VAR_region TF_VAR_environment TF_VAR_regional_aws_account_id \
    TF_VAR_repository_url TF_VAR_repository_branch TF_VAR_container_image \
    TF_STATE_BUCKET TF_STATE_KEY

print_provision_param_summary "MC" \
    "management_id" "config" "${_CONFIG_MANAGEMENT_ID}" \
    "MANAGEMENT_ID" "runtime" "${MANAGEMENT_ID}" \
    "TARGET_ACCOUNT_ID" "runtime" "${TARGET_ACCOUNT_ID}" \
    "REGIONAL_AWS_ACCOUNT_ID" "runtime" "${RESOLVED_REGIONAL_ACCOUNT_ID}" \
    "TARGET_REGION" "runtime" "${TARGET_REGION}" \
    "REPOSITORY_URL" "runtime" "${REPOSITORY_URL}" \
    "REPOSITORY_BRANCH" "runtime" "${_REPO_BRANCH}" \
    "PLATFORM_IMAGE" "runtime" "${PLATFORM_IMAGE}" \
    "RC_STATE_BUCKET" "RC state" "${_RC_STATE_BUCKET:-<destroy-placeholder>}" \
    "RC_STATE_KEY" "RC state" "${_RC_STATE_KEY:-<destroy-placeholder>}" \
    "oidc_cloudfront_domain" "RC state" "${TF_VAR_oidc_cloudfront_domain:-}" \
    "oidc_bucket_arn" "RC state" "${TF_VAR_oidc_bucket_arn:-}" \
    "zoa_lambda_ecr_url" "RC state" "${TF_VAR_zoa_lambda_ecr_url:-}" \
    "zoa_lambda_image_tag" "config" "${_ZOA_LAMBDA_IMAGE_TAG}" \
    "TF_STATE_BUCKET" "runtime" "${TF_STATE_BUCKET}" \
    "TF_STATE_KEY" "runtime" "${TF_STATE_KEY}"

# Initialize backend
tf_init_backend \
    terraform/config/management-cluster \
    "${TF_STATE_BUCKET}" \
    "${TF_STATE_KEY}" \
    "${TF_STATE_REGION}"

# Apply or destroy
tf_apply terraform/config/management-cluster "${TERRAFORM_ACTION}"

if [[ "${TERRAFORM_ACTION}" == "apply" ]]; then
    _MC_REQUIRED_OUTPUTS=(
        "cluster_name"
        "cluster_endpoint|^https://"
        "vpc_id|^vpc-"
        "oidc_bucket_name"
        "oidc_cloudfront_domain"
        "zoa_api_function_url|^https://"
    )
    tf_validate_outputs terraform/config/management-cluster "MC" "${_MC_REQUIRED_OUTPUTS[@]}" || exit 1
fi
