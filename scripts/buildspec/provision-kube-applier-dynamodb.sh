#!/usr/bin/env bash
# Provision kube-applier DynamoDB tables and seaplane-operator IAM policy
# in the RC account for this Management Cluster.
# Called from: scripts/buildspec/provision-cluster.sh
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

# Determine terraform action
DELETE_FLAG="${IS_DESTROY:-false}"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

echo "MC ${MANAGEMENT_ID}: kube-applier-dynamodb terraform ${TERRAFORM_ACTION} in RC account ${RESOLVED_REGIONAL_ACCOUNT_ID}/${TARGET_REGION}"

# Read RC regional_id from RC deploy config
_RC_CONFIG_FILE=$(config_path_for_mode regional)
if [ ! -f "$_RC_CONFIG_FILE" ]; then
    echo "ERROR: RC config not found: $_RC_CONFIG_FILE" >&2
    exit 1
fi
_RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "$_RC_CONFIG_FILE")

# ── Switch to RC account ────────────────────────────────────────────────────
use_rc_account

# ── Terraform apply ────────────────────────────────────────────────────────
_RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_BUCKET="${_RC_STATE_BUCKET}"
export TF_STATE_KEY="kube-applier-dynamodb/${CLUSTER_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_mc_name="${CLUSTER_ID}"
export TF_VAR_mc_aws_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_rc_id="${_RC_REGIONAL_ID}"
TF_VAR_enable_pitr=$(parseBool '.kube_applier_dynamodb_enable_pitr' false "$DEPLOY_CONFIG_FILE")
export TF_VAR_enable_pitr
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"
export TF_VAR_environment="${ENVIRONMENT:-staging}"

cd terraform/config/kube-applier-dynamodb-provisioning
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
