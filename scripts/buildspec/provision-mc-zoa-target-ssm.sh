#!/usr/bin/env bash
# Register or deregister this MC as a ZOA boundary target in RC SSM
# (/zoa/targets/<deployment>/<cluster>).
#
# RC-account Terraform only (use_rc_account + CHILD_ADMIN_ROLE), called by
# provision-cluster.sh after MC infrastructure, like kube-applier DynamoDB.
# Does not use zoa-data-access; MC Lambdas use that role for DynamoDB/S3 only.
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

_resolve_rc_account
RESOLVED_REGIONAL_ACCOUNT_ID="${_RESOLVED_RC_ACCOUNT_ID}"

DELETE_FLAG="${IS_DESTROY:-false}"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

_zoa_deployment_name=$(jq -r '.zoa_deployment_name // empty' "$DEPLOY_CONFIG_FILE")
if [ -z "${_zoa_deployment_name}" ]; then
    _zoa_deployment_name=$(jq -r '.deployment_name // empty' "$(config_path_for_mode regional)" 2>/dev/null || echo "")
fi
if [ -z "${_zoa_deployment_name}" ]; then
    echo "ERROR: zoa_deployment_name not set in MC deploy config or RC deployment_name" >&2
    exit 1
fi

_eph_prefix=$(jq -r '.eph_prefix // empty' "$DEPLOY_CONFIG_FILE")
_targets_ssm_prefix="/zoa/targets/${_zoa_deployment_name}"
_MC_TF_DIR="terraform/config/management-cluster"

echo "MC ${MANAGEMENT_ID}: mc-zoa-target-ssm terraform ${TERRAFORM_ACTION} in RC account ${RESOLVED_REGIONAL_ACCOUNT_ID}/${TARGET_REGION}"

export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_cluster_id="${CLUSTER_ID}"
export TF_VAR_deployment_name="${_zoa_deployment_name}"
export TF_VAR_targets_ssm_prefix="${_targets_ssm_prefix}"
export TF_VAR_mc_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"
export TF_VAR_environment="${ENVIRONMENT:-staging}"
export TF_VAR_eph_prefix="${_eph_prefix}"

if [ "${TERRAFORM_ACTION}" == "apply" ]; then
    use_mc_account
    _MC_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
    _MC_STATE_KEY="management-cluster/${MANAGEMENT_ID}.tfstate"
    terraform -chdir="${_MC_TF_DIR}" init -reconfigure \
        -backend-config="bucket=${_MC_STATE_BUCKET}" \
        -backend-config="key=${_MC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true" >/dev/null

    export TF_VAR_vpc_id
    TF_VAR_vpc_id=$(terraform -chdir="${_MC_TF_DIR}" output -raw vpc_id)
    export TF_VAR_private_subnet_ids
    TF_VAR_private_subnet_ids=$(terraform -chdir="${_MC_TF_DIR}" output -json private_subnets | jq -r 'join(",")')
    export TF_VAR_security_group_id
    TF_VAR_security_group_id=$(terraform -chdir="${_MC_TF_DIR}" output -raw zoa_boundary_security_group_id)
    export TF_VAR_ecs_cluster_arn
    TF_VAR_ecs_cluster_arn=$(terraform -chdir="${_MC_TF_DIR}" output -raw zoa_boundary_ecs_cluster_arn)
    export TF_VAR_task_definition_arn
    TF_VAR_task_definition_arn=$(terraform -chdir="${_MC_TF_DIR}" output -raw zoa_boundary_task_definition_arn)
    export TF_VAR_function_url
    TF_VAR_function_url=$(terraform -chdir="${_MC_TF_DIR}" output -raw zoa_api_function_url)
else
    export TF_VAR_vpc_id="destroy-placeholder"
    export TF_VAR_private_subnet_ids="subnet-placeholder"
    export TF_VAR_security_group_id="sg-placeholder"
    export TF_VAR_ecs_cluster_arn="arn:aws:ecs:${TARGET_REGION}:${TARGET_ACCOUNT_ID}:cluster/placeholder"
    export TF_VAR_task_definition_arn="arn:aws:ecs:${TARGET_REGION}:${TARGET_ACCOUNT_ID}:task-definition/placeholder:1"
    export TF_VAR_function_url="https://placeholder.lambda-url.${TARGET_REGION}.on.aws/"
fi

use_rc_account

export TF_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="mc-zoa-target-ssm/${CLUSTER_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

cd terraform/config/mc-zoa-target-ssm-provisioning
terraform init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${TF_STATE_REGION}" \
    -backend-config="use_lockfile=true"

set +e
terraform "${TERRAFORM_ACTION}" -auto-approve
TERRAFORM_STATUS=$?
set -e

if [ $TERRAFORM_STATUS -ne 0 ]; then
    exit $TERRAFORM_STATUS
fi
