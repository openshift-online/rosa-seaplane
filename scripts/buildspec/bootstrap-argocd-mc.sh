#!/usr/bin/env bash
# Bootstrap ArgoCD on a Management Cluster.
# Called from: terraform/config/pipeline-management-cluster/buildspec-bootstrap-argocd.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "delete=true — skipping ArgoCD bootstrap"
    exit 0
fi

# Resolve the shared registry account from central SSM before switching accounts.
IMAGE_REGISTRY_ACCOUNT_ID=$(resolve_central_ssm_value \
    "$(jq -r '.image_registry_account_id // empty' "$DEPLOY_CONFIG_FILE")" \
    "us-east-1")
if [[ ! "$IMAGE_REGISTRY_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "ERROR: image_registry_account_id must resolve to a 12-digit AWS account ID" >&2
    exit 1
fi
export IMAGE_REGISTRY_ACCOUNT_ID

# Read RHOBS API URL from RC terraform state.
# The RC pipeline runs in parallel — wait for the output to appear.
_resolve_rc_account
RESOLVED_REGIONAL_ACCOUNT_ID="${_RESOLVED_RC_ACCOUNT_ID}"
_RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
_RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "regional")
_RC_STATE_KEY="regional-cluster/${_RC_REGIONAL_ID}.tfstate"
_RC_TF_DIR="terraform/config/regional-cluster"

# Assume child admin role in RC account to access state bucket (scoped access instead of org-wide).
echo "Assuming ${CHILD_ADMIN_ROLE_NAME} in RC account ${RESOLVED_REGIONAL_ACCOUNT_ID} for state access..."
_rc_creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${CHILD_ADMIN_ROLE_NAME}" \
    --role-session-name "mc-read-rc-state-${MANAGEMENT_ID}" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)
AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') \
AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') \
AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') \
terraform -chdir="$_RC_TF_DIR" init -reconfigure \
    -backend-config="bucket=${_RC_STATE_BUCKET}" \
    -backend-config="key=${_RC_STATE_KEY}" \
    -backend-config="region=${TARGET_REGION}" \
    -backend-config="use_lockfile=true" >/dev/null 2>&1

_RC_TIMEOUT=1800
_RC_START=$(date +%s)
export RHOBS_API_URL=""
while [ -z "$RHOBS_API_URL" ]; do
    RHOBS_API_URL=$(
        AWS_ACCESS_KEY_ID=$(echo "$_rc_creds" | awk '{print $1}') \
        AWS_SECRET_ACCESS_KEY=$(echo "$_rc_creds" | awk '{print $2}') \
        AWS_SESSION_TOKEN=$(echo "$_rc_creds" | awk '{print $3}') \
        terraform -chdir="$_RC_TF_DIR" output -raw rhobs_api_url 2>/dev/null || echo ""
    )
    if [ -n "$RHOBS_API_URL" ]; then
        break
    fi
    _ELAPSED=$(( $(date +%s) - _RC_START ))
    if [ "$_ELAPSED" -ge "$_RC_TIMEOUT" ]; then
        echo "ERROR: rhobs_api_url not available after $((_ELAPSED / 60))m" >&2
        exit 1
    fi
    echo "Waiting for RC rhobs_api_url (${_ELAPSED}s elapsed)..."
    sleep 30
done

export DNS_ZONE_OPERATOR_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-dns-zone-operator"
export OIDC_KEY_READER_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-oidc-key-reader"

use_mc_account
terraform_init_backend management-cluster "${TARGET_REGION}" "${MANAGEMENT_ID}"
bootstrap_argocd management-cluster "${TARGET_ACCOUNT_ID}"
