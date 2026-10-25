#!/usr/bin/env bash
# Wait for the Regional Cluster Platform API to become healthy.
# Called from: scripts/buildspec/provision-cluster.sh
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load regional

DELETE_FLAG="${IS_DESTROY:-false}"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "delete=true — skipping Regional Cluster API readiness"
    exit 0
fi

use_mc_account
terraform_init_backend regional-cluster "${TARGET_REGION}" "${REGIONAL_ID}"

API_GATEWAY_URL=$(cd terraform/config/regional-cluster && \
    terraform output -raw api_gateway_invoke_url 2>/dev/null || true)
if [ -z "$API_GATEWAY_URL" ]; then
    echo "ERROR: api_gateway_invoke_url is unavailable after RC Terraform apply" >&2
    exit 1
fi

_log_live_response() {
    local http_code="$1"
    local response=""
    if [ -s /tmp/rc-live-response.json ]; then
        response=$(tr '\r\n' '  ' < /tmp/rc-live-response.json | cut -c1-300)
    fi
    if [ -n "$response" ]; then
        echo "${LIVE_URL} returned ${http_code} (attempt ${RETRY_COUNT}/${LIVE_MAX_RETRIES}), response: ${response}, retrying in ${LIVE_RETRY_DELAY}s..."
    else
        echo "${LIVE_URL} returned ${http_code} (attempt ${RETRY_COUNT}/${LIVE_MAX_RETRIES}), retrying in ${LIVE_RETRY_DELAY}s..."
    fi
}

_log_target_health() {
    local target_group_arn
    target_group_arn=$(cd terraform/config/regional-cluster && \
        terraform output -raw api_target_group_arn 2>/dev/null || true)
    if [ -z "$target_group_arn" ]; then
        return
    fi

    echo "RC API target health:"
    aws elbv2 describe-target-health \
        --region "${TARGET_REGION}" \
        --target-group-arn "$target_group_arn" \
        --query 'TargetHealthDescriptions[].{target:Target.Id,state:TargetHealth.State,reason:TargetHealth.Reason,description:TargetHealth.Description}' \
        --output table 2>&1 || echo "Unable to read RC API target health"
}

set +e
LIVE_MAX_RETRIES="${RC_LIVE_MAX_RETRIES:-30}"
LIVE_RETRY_DELAY="${RC_LIVE_RETRY_DELAY:-30}"
if ! [[ "$LIVE_MAX_RETRIES" =~ ^[1-9][0-9]*$ ]] || \
    ! [[ "$LIVE_RETRY_DELAY" =~ ^[0-9]+$ ]]; then
    echo "ERROR: RC_LIVE_MAX_RETRIES must be positive and RC_LIVE_RETRY_DELAY must be non-negative" >&2
    exit 1
fi

LIVE_URL="${API_GATEWAY_URL}${PLATFORM_API_LIVE_PATH}"
echo "Checking Regional Cluster Platform API live endpoint: ${LIVE_URL}"
rm -f /tmp/rc-live-response.json
RETRY_COUNT=0
LIVE_OK=false

while [ $RETRY_COUNT -lt "$LIVE_MAX_RETRIES" ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))

    SECURITY_TOKEN_HEADER=()
    if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
        SECURITY_TOKEN_HEADER=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
    fi

    HTTP_CODE=$(curl -sS -o /tmp/rc-live-response.json -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        --aws-sigv4 "aws:amz:${TARGET_REGION}:execute-api" \
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
        "${SECURITY_TOKEN_HEADER[@]}" \
        -X GET "${LIVE_URL}")

    if [ "$HTTP_CODE" = "200" ]; then
        LIVE_OK=true
        break
    fi
    _log_live_response "$HTTP_CODE"
    sleep "$LIVE_RETRY_DELAY"
done
set -e

if [ "$LIVE_OK" != "true" ]; then
    echo "ERROR: ${LIVE_URL} did not return 200 after ${LIVE_MAX_RETRIES} attempts" >&2
    if [ -s /tmp/rc-live-response.json ]; then
        echo "Last live endpoint checked (${LIVE_URL}) response: $(tr '\r\n' '  ' < /tmp/rc-live-response.json | cut -c1-300)" >&2
    fi
    _log_target_health
    exit 1
fi

echo "Regional Cluster Platform API is healthy"
