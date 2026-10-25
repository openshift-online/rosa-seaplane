#!/usr/bin/env bash
# Provision or destroy Regional Cluster infrastructure.
# Called from: scripts/buildspec/provision-cluster.sh
set -euo pipefail

source scripts/pipeline-common/lib.sh
source scripts/pipeline-common/terraform-lib.sh

preflight_check
config_load regional

DEPLOY_DIR=$(dirname "$DEPLOY_CONFIG_FILE")
STATIC_TFVARS="${DEPLOY_DIR}/static.tfvars.json"
_REPO_BRANCH="${REPOSITORY_BRANCH:-main}"

require_nonempty_vars "RC core runtime" \
    TARGET_ACCOUNT_ID TARGET_REGION REGIONAL_ID REPOSITORY_URL PLATFORM_IMAGE
validate_aws_account_id "TARGET_ACCOUNT_ID" "${TARGET_ACCOUNT_ID}"
tf_require_static_vars "${STATIC_TFVARS}" "RC core" \
    regional_id environment deployment_name app_code service_phase cost_center
tf_require_static_keys "${STATIC_TFVARS}" "RC" \
    zoa_lambda_image_tag zoa_runner_image_tag \
    zoa_lambda_source_image zoa_runner_source_image worker_node_ami_id eph_prefix \
    enable_rate_limit_redis seaplane_db_instance_class \
    seaplane_db_skip_final_snapshot seaplane_db_performance_insights_enabled \
    seaplane_db_monitoring_interval worker_node_root_volume_size \
    zoa_boundary_session_idle_timeout_seconds zoa_boundary_session_max_duration_hours \
    zoa_lambda_api_concurrency zoa_lambda_worker_concurrency zoa_lambda_access_concurrency \
    zoa_access_trusted_assumer_role_names zoa_access_trusted_assumer_role_name_suffixes
tf_require_static_vars "${STATIC_TFVARS}" "RC ZOA boundary" zoa_boundary_image

_STATIC_REGIONAL_ID=$(jq -r '.regional_id // empty' "${STATIC_TFVARS}")
_STATIC_ENVIRONMENT=$(jq -r '.environment // empty' "${STATIC_TFVARS}")
if [[ "${_STATIC_REGIONAL_ID}" != "${REGIONAL_ID}" ]]; then
    echo "ERROR: RC regional_id mismatch: static=${_STATIC_REGIONAL_ID}, runtime=${REGIONAL_ID}" >&2
    exit 1
fi
if [[ "${_STATIC_ENVIRONMENT}" != "${ENVIRONMENT}" ]]; then
    echo "ERROR: RC environment mismatch: static=${_STATIC_ENVIRONMENT}, runtime=${ENVIRONMENT}" >&2
    exit 1
fi

_ZOA_LAMBDA_IMAGE_TAG=$(jq -r '.zoa_lambda_image_tag // empty' "$STATIC_TFVARS")
if [[ "${IS_DESTROY:-false}" != "true" ]]; then
    tf_require_static_vars "${STATIC_TFVARS}" "RC ZOA" \
        zoa_lambda_image_tag zoa_runner_image_tag \
        zoa_lambda_source_image zoa_runner_source_image
fi

# Save central credentials as a named AWS profile so Terraform's aws.central
# provider can access the central account after use_mc_account switches
# ambient creds to the target account.
aws configure set aws_access_key_id     "$_CENTRAL_AWS_ACCESS_KEY_ID"     --profile central
aws configure set aws_secret_access_key "$_CENTRAL_AWS_SECRET_ACCESS_KEY" --profile central
aws configure set aws_session_token     "$_CENTRAL_AWS_SESSION_TOKEN"     --profile central
aws configure set region                "${TARGET_REGION}"                --profile central
export TF_VAR_central_aws_profile="central"

# Fetch PagerDuty token if enabled (config moved to static.tfvars.json)
_RAW_PD=$(jq -r '.enable_pagerduty // false' "$DEPLOY_CONFIG_FILE")
if [ "$_RAW_PD" == "true" ] || [ "$_RAW_PD" == "1" ]; then
    PAGERDUTY_TOKEN=$(secrets_manager_get "pagerduty/service-account" "us-east-1" required)
    export PAGERDUTY_TOKEN
fi

# Resolve MC account IDs from central /infra/* while ambient creds are still the CodeBuild (central) role.
export TF_VAR_management_clusters
TF_VAR_management_clusters=$(build_management_clusters_tf_var "$DEPLOY_CONFIG_FILE")

use_mc_account

# Configure Terraform backend (state in target account)
export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="regional-cluster/${REGIONAL_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

# Set dynamic Terraform variables (static vars in static.tfvars.json)
export TF_VAR_region="${TARGET_REGION}"

export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

export TF_VAR_container_image="${PLATFORM_IMAGE}"

# Static config vars (enable_bastion, seaplane_db_*, enable_cloudtrail, etc)
# moved to static.tfvars.json

TF_VAR_enable_sre_public_access=$(parseBool '.enable_sre_public_access' false "$DEPLOY_CONFIG_FILE")
# SRE UI ALB allowed source CIDRs from SSM (public mode only; not committed to the repo)
if [ "$TF_VAR_enable_sre_public_access" = "true" ]; then
    TF_VAR_sre_allowed_source_cidrs=$(aws ssm get-parameter \
        --name "/infra/sre-ui-alb/allowed-source-cidrs" \
        --query 'Parameter.Value' \
        --output text \
        --region "${TARGET_REGION}" 2>/dev/null || true)
    if [ -z "${TF_VAR_sre_allowed_source_cidrs}" ]; then
        echo "ERROR: SSM parameter /infra/sre-ui-alb/allowed-source-cidrs not found in account ${TARGET_ACCOUNT_ID} region ${TARGET_REGION}" >&2
        exit 1
    fi
else
    TF_VAR_sre_allowed_source_cidrs=$(jq -c '.sre_allowed_source_cidrs // []' "$DEPLOY_CONFIG_FILE")
fi
export TF_VAR_sre_allowed_source_cidrs

# SRE OIDC config (enable_sre_oidc_auth, sre_oidc_issuer_url, sre_*_oidc_client_id)
# moved to static.tfvars.json; only secrets remain dynamic
TF_VAR_enable_sre_oidc_auth=$(parseBool '.enable_sre_oidc_auth' false "$DEPLOY_CONFIG_FILE")
if [ "$TF_VAR_enable_sre_oidc_auth" = "true" ]; then
    for svc in grafana argocd prometheus thanos; do
        secret=$(secrets_manager_get "sre-ui-alb/${svc}/oidc-client-secret" "${TARGET_REGION}" required)
        export "TF_VAR_sre_${svc}_oidc_client_secret=${secret}"
    done
fi

# MC OU path from SSM - backward-compatible: try new nested path first, fall back to legacy flat path
TF_VAR_mc_ou_path=$(ssm_get_param_with_fallback \
    "${TARGET_REGION}" \
    "/infra/${ENVIRONMENT}/${TARGET_REGION}/ou-path" \
    "/infra/region-ou-path") || TF_VAR_mc_ou_path=""

if [ -z "${TF_VAR_mc_ou_path}" ]; then
    echo "ERROR: MC OU path not found in SSM" >&2
    echo "For stage: parameter is created by rosa-seaplane-internal/infra/modules/account-config" >&2
    echo "For ephemeral/integration: manually create at /infra/region-ou-path (legacy) or /infra/${ENVIRONMENT}/${TARGET_REGION}/ou-path (new)" >&2
    exit 1
fi
export TF_VAR_mc_ou_path
export TF_VAR_region_ou_path="${TF_VAR_mc_ou_path}"  # Pass through to terraform

if [ -n "${ENVIRONMENT_DOMAIN:-}" ]; then
    export TF_VAR_environment_domain="${ENVIRONMENT_DOMAIN}"
fi
if [ -n "${ENVIRONMENT_HOSTED_ZONE_ID:-}" ]; then
    export TF_VAR_environment_hosted_zone_id="${ENVIRONMENT_HOSTED_ZONE_ID}"
fi

# Static vars (regional_id, environment, zoa_*, worker_node_ami_id, eph_prefix)
# moved to static.tfvars.json
export ENVIRONMENT="${ENVIRONMENT:-staging}"

# Determine terraform action
DELETE_FLAG="${IS_DESTROY:-false}"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

echo "RC ${REGIONAL_ID}: terraform ${TERRAFORM_ACTION} in ${TARGET_ACCOUNT_ID}/${TARGET_REGION}"

print_provision_param_summary "RC" \
    "regional_id" "static" "${_STATIC_REGIONAL_ID}" \
    "REGIONAL_ID" "runtime" "${REGIONAL_ID}" \
    "TARGET_ACCOUNT_ID" "runtime" "${TARGET_ACCOUNT_ID}" \
    "TARGET_REGION" "runtime" "${TARGET_REGION}" \
    "REPOSITORY_URL" "runtime" "${REPOSITORY_URL}" \
    "REPOSITORY_BRANCH" "runtime" "${_REPO_BRANCH}" \
    "PLATFORM_IMAGE" "runtime" "${PLATFORM_IMAGE}" \
    "TF_VAR_management_clusters" "derived" "${TF_VAR_management_clusters}" \
    "TF_VAR_region_ou_path" "SSM" "${TF_VAR_region_ou_path}" \
    "zoa_lambda_image_tag" "static" "${_ZOA_LAMBDA_IMAGE_TAG}" \
    "zoa_runner_image_tag" "static" "$(jq -r '.zoa_runner_image_tag // empty' "${STATIC_TFVARS}")" \
    "TF_STATE_BUCKET" "runtime" "${TF_STATE_BUCKET}" \
    "TF_STATE_KEY" "runtime" "${TF_STATE_KEY}"

# Initialize backend
tf_init_backend \
    terraform/config/regional-cluster \
    "${TF_STATE_BUCKET}" \
    "${TF_STATE_KEY}" \
    "${TF_STATE_REGION}"

# Apply or destroy
tf_apply_with_static_vars \
    terraform/config/regional-cluster \
    "${TERRAFORM_ACTION}" \
    "${DEPLOY_DIR}/static.tfvars.json"

if [[ "${TERRAFORM_ACTION}" == "apply" ]]; then
    _RC_REQUIRED_OUTPUTS=(
        "cluster_name"
        "cluster_endpoint|^https://"
        "vpc_id|^vpc-"
        "api_gateway_invoke_url|^https://"
        "rhobs_api_url|^https://"
    )
    if [[ -n "${TF_VAR_management_clusters}" ]]; then
        _RC_REQUIRED_OUTPUTS+=(
            "oidc_cloudfront_domain"
            "oidc_bucket_name"
            "oidc_bucket_arn|^arn:"
            "oidc_bucket_region"
        )
    fi
    _RC_REQUIRED_OUTPUTS+=(
        "zoa_bucket_arn|^arn:"
        "zoa_kms_key_arn|^arn:"
        "zoa_table_name"
        "zoa_audit_table_name"
        "zoa_sessions_table_name"
        "zoa_uploader_role_arn|^arn:"
        "zoa_data_access_role_arn|^arn:"
        "zoa_access_lambda_role_arn|^arn:"
        "zoa_lambda_ecr_url"
        "zoa_api_function_url|^https://"
    )
    tf_validate_outputs terraform/config/regional-cluster "RC" "${_RC_REQUIRED_OUTPUTS[@]}" || exit 1
fi
