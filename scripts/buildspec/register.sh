#!/usr/bin/env bash
# Register a Management Cluster with the Regional Cluster API.
# Called from: scripts/buildspec/provision-cluster.sh
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

require_nonempty_vars "MC registration core" \
    TARGET_ACCOUNT_ID TARGET_REGION MANAGEMENT_ID REGIONAL_AWS_ACCOUNT_ID
validate_aws_account_id "TARGET_ACCOUNT_ID" "${TARGET_ACCOUNT_ID}"
validate_aws_account_id "REGIONAL_AWS_ACCOUNT_ID" "${REGIONAL_AWS_ACCOUNT_ID}"

ENVIRONMENT="${ENVIRONMENT:-staging}"
DELETE_FLAG="${IS_DESTROY:-false}"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "delete=true — skipping MC registration"
    exit 0
fi

echo "Registering MC ${CLUSTER_ID} with RC API"

_log_step_start() {
    _STEP_NAME="$1"
    _STEP_START=$SECONDS
    echo "provision-step: START ${_STEP_NAME}"
}

_log_step_success() {
    echo "provision-step: SUCCEEDED ${_STEP_NAME} duration=$((SECONDS - _STEP_START))s"
}

_log_step_failure() {
    local _exit_code="$1"
    echo "provision-step: FAILED ${_STEP_NAME} duration=$((SECONDS - _STEP_START))s exit_code=${_exit_code}" >&2
}

_log_live_response() {
    local _http_code="$1"
    local _response=""
    if [ -f /tmp/mc-live-response.json ]; then
        _response=$(tr '\r\n' '  ' < /tmp/mc-live-response.json | cut -c1-300)
    fi
    if [ -n "$_response" ]; then
        echo "${LIVE_URL} returned ${_http_code} (attempt ${RETRY_COUNT}/${LIVE_MAX_RETRIES}), response: ${_response}, retrying in ${LIVE_RETRY_DELAY}s..."
    else
        echo "${LIVE_URL} returned ${_http_code} (attempt ${RETRY_COUNT}/${LIVE_MAX_RETRIES}), retrying in ${LIVE_RETRY_DELAY}s..."
    fi
}

_log_target_health() {
    local _target_group_arn
    _target_group_arn=$(cd terraform/config/regional-cluster && \
        terraform output -raw api_target_group_arn 2>/dev/null || true)
    if [ -z "$_target_group_arn" ]; then
        return
    fi

    echo "RC API target health:"
    aws elbv2 describe-target-health \
        --region "${TARGET_REGION}" \
        --target-group-arn "$_target_group_arn" \
        --query 'TargetHealthDescriptions[].{target:Target.Id,state:TargetHealth.State,reason:TargetHealth.Reason,description:TargetHealth.Description}' \
        --output table 2>&1 || echo "Unable to read RC API target health"
}

# Read API Gateway URL and CloudFront domain from RC terraform state
RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

RC_CONFIG_FILE=$(config_path_for_mode regional)
if [ ! -f "$RC_CONFIG_FILE" ]; then
    echo "ERROR: RC config not found: $RC_CONFIG_FILE" >&2
    exit 1
fi
RC_REGIONAL_ID=$(jq -r '.regional_id' "$RC_CONFIG_FILE")

use_rc_account

RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
RC_STATE_KEY="regional-cluster/${RC_REGIONAL_ID}.tfstate"

(
    cd terraform/config/regional-cluster
    terraform init -reconfigure \
        -backend-config="bucket=${RC_STATE_BUCKET}" \
        -backend-config="key=${RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true"
)

# RC and MC pipelines run in parallel — retry until outputs appear (up to 45 min)
_log_step_start "MC API Gateway output discovery"
_REG_MAX_RETRIES=90
_REG_RETRY_DELAY=30
_REG_RETRY_COUNT=0
API_GATEWAY_URL=""

while [ $_REG_RETRY_COUNT -lt $_REG_MAX_RETRIES ]; do
    _REG_RETRY_COUNT=$((_REG_RETRY_COUNT + 1))
    API_GATEWAY_URL=$(cd terraform/config/regional-cluster && terraform output -raw api_gateway_invoke_url 2>/dev/null || true)
    if [ -n "$API_GATEWAY_URL" ]; then
        break
    fi
    echo "RC outputs not ready (attempt ${_REG_RETRY_COUNT}/${_REG_MAX_RETRIES}), retrying in ${_REG_RETRY_DELAY}s..."
    sleep "$_REG_RETRY_DELAY"
done

if [ -z "$API_GATEWAY_URL" ]; then
    _log_step_failure 1
    echo "ERROR: api_gateway_invoke_url not available after $((_REG_MAX_RETRIES * _REG_RETRY_DELAY / 60))+ minutes" >&2
    exit 1
fi
if [[ ! "$API_GATEWAY_URL" =~ ^https:// ]]; then
    _log_step_failure 1
    echo "ERROR: RC api_gateway_invoke_url is invalid: ${API_GATEWAY_URL}" >&2
    exit 1
fi
_log_step_success

print_provision_param_summary "MC registration" \
    "MANAGEMENT_ID" "runtime" "${MANAGEMENT_ID}" \
    "TARGET_ACCOUNT_ID" "runtime" "${TARGET_ACCOUNT_ID}" \
    "REGIONAL_AWS_ACCOUNT_ID" "RC state" "${RESOLVED_REGIONAL_ACCOUNT_ID}" \
    "RC_STATE_BUCKET" "RC state" "${RC_STATE_BUCKET}" \
    "RC_STATE_KEY" "RC state" "${RC_STATE_KEY}" \
    "API_GATEWAY_URL" "RC state" "${API_GATEWAY_URL}" \
    "PLATFORM_API_LIVE_PATH" "runtime" "${PLATFORM_API_LIVE_PATH}"

# Wait for API Gateway /live endpoint. RC ArgoCD can still be syncing after
# Terraform and bootstrap complete, so allow up to 30 minutes by default.
set +e
LIVE_MAX_RETRIES="${MC_LIVE_MAX_RETRIES:-30}"
LIVE_RETRY_DELAY="${MC_LIVE_RETRY_DELAY:-30}"
if ! [[ "$LIVE_MAX_RETRIES" =~ ^[1-9][0-9]*$ ]] || \
    ! [[ "$LIVE_RETRY_DELAY" =~ ^[0-9]+$ ]]; then
    echo "ERROR: MC_LIVE_MAX_RETRIES must be positive and MC_LIVE_RETRY_DELAY must be non-negative" >&2
    exit 1
fi
_log_step_start "MC API live readiness"
LIVE_URL="${API_GATEWAY_URL}${PLATFORM_API_LIVE_PATH}"
echo "Checking MC API live endpoint: ${LIVE_URL}"
rm -f /tmp/mc-live-response.json
RETRY_COUNT=0
LIVE_OK=false

while [ $RETRY_COUNT -lt "$LIVE_MAX_RETRIES" ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))

    SECURITY_TOKEN_HEADER=()
    if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
        SECURITY_TOKEN_HEADER=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
    fi

    HTTP_CODE=$(curl -sS -o /tmp/mc-live-response.json -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        --aws-sigv4 "aws:amz:${TARGET_REGION}:execute-api" \
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
        "${SECURITY_TOKEN_HEADER[@]}" \
        -X GET "$LIVE_URL")

    if [ "$HTTP_CODE" = "200" ]; then
        LIVE_OK=true
        break
    fi
    _log_live_response "$HTTP_CODE"
    sleep "$LIVE_RETRY_DELAY"
done
set -e

if [ "$LIVE_OK" != "true" ]; then
    _log_step_failure 1
    echo "ERROR: ${LIVE_URL} did not return 200 after $LIVE_MAX_RETRIES attempts" >&2
    if [ -s /tmp/mc-live-response.json ]; then
        echo "Last live endpoint checked (${LIVE_URL}) response: $(tr '\r\n' '  ' < /tmp/mc-live-response.json | cut -c1-300)" >&2
    fi
    _log_target_health
    exit 1
fi
_log_step_success

# Register management cluster
REGISTER_URL="${API_GATEWAY_URL}/api/v0/management_clusters"
PAYLOAD=$(cat <<EOJSON
{
  "id": "${CLUSTER_ID}",
  "region": "${TARGET_REGION}",
  "accountId": "${TARGET_ACCOUNT_ID}"
}
EOJSON
)

set +e
_log_step_start "MC API registration"
REG_MAX_RETRIES=10
REG_RETRY_DELAY=30
REG_RETRY_COUNT=0
REG_OK=false

while [ $REG_RETRY_COUNT -lt $REG_MAX_RETRIES ]; do
    REG_RETRY_COUNT=$((REG_RETRY_COUNT + 1))

    SECURITY_TOKEN_HEADER=()
    if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
        SECURITY_TOKEN_HEADER=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
    fi

    HTTP_CODE=$(curl -s -o /tmp/register-response.json -w "%{http_code}" \
        --aws-sigv4 "aws:amz:${TARGET_REGION}:execute-api" \
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
        "${SECURITY_TOKEN_HEADER[@]}" \
        -X POST "$REGISTER_URL" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    # 201 = created, 409 = already exists
    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
        REG_OK=true
        break
    fi
    # 502 may indicate "already exists" behind a gateway error — check response body
    if [ "$HTTP_CODE" = "502" ] && grep -qi "already exists" /tmp/register-response.json 2>/dev/null; then
        REG_OK=true
        break
    fi

    echo "Registration returned $HTTP_CODE (attempt $REG_RETRY_COUNT/$REG_MAX_RETRIES), retrying in ${REG_RETRY_DELAY}s..."
    sleep $REG_RETRY_DELAY
done
set -e

if [ "$REG_OK" != "true" ]; then
    _log_step_failure 1
    echo "ERROR: Registration failed after $REG_MAX_RETRIES attempts (HTTP $HTTP_CODE)" >&2
    cat /tmp/register-response.json >&2
    exit 1
fi
_log_step_success
