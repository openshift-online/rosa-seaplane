#!/bin/bash
# Bootstrap ArgoCD - run from terraform/config/{cluster-type} after terraform apply as it uses the output
set -euo pipefail

CLUSTER_TYPE="${1:-}"

# Set defaults from environment variables
ENVIRONMENT="${ENVIRONMENT:-integration}"
# Prefer existing REGION_DEPLOYMENT, then AWS CLI, then default (handles empty CLI output)
AWS_CLI_REGION=$(aws configure get region 2>/dev/null || true)
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "$CLUSTER_TYPE" != "management-cluster" && "$CLUSTER_TYPE" != "regional-cluster" ]]; then
    echo "ERROR: cluster-type must be 'management-cluster' or 'regional-cluster', got '${CLUSTER_TYPE}'" >&2
    exit 1
fi

TERRAFORM_DIR="terraform/config/${CLUSTER_TYPE}"

# Read terraform outputs BEFORE assuming role
# (terraform state is in central account, so we need central account creds to read it)
cd ${TERRAFORM_DIR}/

OUTPUTS=$(terraform output -json)

# Handle cross-account role assumption if ASSUME_ROLE_ARN is set
# This is used when the script runs in CodeBuild to bootstrap a cluster in a different account
# We assume the role AFTER reading terraform outputs because:
# - Terraform state is in central account S3, needs central account creds
# - ECS cluster/logs are in target account, need target account creds
if [[ -n "${ASSUME_ROLE_ARN:-}" ]]; then
    if ! CREDS=$(aws sts assume-role \
        --role-arn "$ASSUME_ROLE_ARN" \
        --role-session-name "bootstrap-argocd" \
        --output json 2>&1); then
        echo "ERROR: Failed to assume role: $ASSUME_ROLE_ARN" >&2
        echo "$CREDS" >&2
        exit 1
    fi

    if ! echo "$CREDS" | jq -e '.Credentials' >/dev/null 2>&1; then
        echo "ERROR: No credentials in assume-role response for $ASSUME_ROLE_ARN" >&2
        exit 1
    fi

    _ak=$(echo "$CREDS" | jq -er '.Credentials.AccessKeyId') || { echo "ERROR: Failed to extract AccessKeyId" >&2; exit 1; }
    _sk=$(echo "$CREDS" | jq -er '.Credentials.SecretAccessKey') || { echo "ERROR: Failed to extract SecretAccessKey" >&2; exit 1; }
    _st=$(echo "$CREDS" | jq -er '.Credentials.SessionToken') || { echo "ERROR: Failed to extract SessionToken" >&2; exit 1; }
    export AWS_ACCESS_KEY_ID="$_ak"
    export AWS_SECRET_ACCESS_KEY="$_sk"
    export AWS_SESSION_TOKEN="$_st"
fi

ECS_CLUSTER_ARN=$(echo "$OUTPUTS" | jq -r '.ecs_cluster_arn.value')
TASK_DEFINITION_ARN=$(echo "$OUTPUTS" | jq -r '.ecs_task_definition_arn.value')
CLUSTER_NAME=$(echo "$OUTPUTS" | jq -r '.cluster_name.value')
PRIVATE_SUBNETS=$(echo "$OUTPUTS" | jq -r '.private_subnets.value[]' | tr '\n' ',' | sed 's/,$//')
BOOTSTRAP_SECURITY_GROUP=$(echo "$OUTPUTS" | jq -r '.bootstrap_security_group_id.value')
LOG_GROUP=$(echo "$OUTPUTS" | jq -r '.bootstrap_log_group_name.value')
REPOSITORY_URL=$(echo "$OUTPUTS" | jq -r '.repository_url.value')
REPOSITORY_BRANCH=$(echo "$OUTPUTS" | jq -r '.repository_branch.value')

# Static values
APPLICATIONSET_PATH="deploy/$ENVIRONMENT/$REGION_DEPLOYMENT/argocd-bootstrap-${CLUSTER_TYPE}"

# Extract cluster-type specific outputs
if [[ "$CLUSTER_TYPE" == "regional-cluster" ]]; then
    API_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.api_target_group_arn.value // ""')
    THANOS_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.thanos_target_group_arn.value // ""')
    THANOS_QUERY_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.thanos_query_target_group_arn.value // ""')
    LOKI_KMS_KEY_ARN=$(echo "$OUTPUTS" | jq -r '.loki_kms_key_arn.value // ""')
    LOKI_DISTRIBUTOR_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.loki_distributor_target_group_arn.value // ""')
    LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.loki_query_frontend_target_group_arn.value // ""')
    OIDC_BUCKET_NAME=$(echo "$OUTPUTS" | jq -r '.oidc_bucket_name.value // ""')
    OIDC_CLOUDFRONT_DOMAIN=$(echo "$OUTPUTS" | jq -r '.oidc_cloudfront_domain.value // ""')
    SRE_GRAFANA_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.sre_grafana_target_group_arn.value // ""')
    SRE_ARGOCD_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.sre_argocd_target_group_arn.value // ""')
    SRE_PROMETHEUS_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.sre_prometheus_target_group_arn.value // ""')
    SRE_THANOS_TARGET_GROUP_ARN=$(echo "$OUTPUTS" | jq -r '.sre_thanos_target_group_arn.value // ""')
    SRE_ALB_DNS_NAME=$(echo "$OUTPUTS" | jq -r '.sre_alb_dns_name.value // ""')
    SRE_DOMAIN=$(echo "$OUTPUTS" | jq -r '.sre_domain.value // ""')
    _REDIS_HOST=$(echo "$OUTPUTS" | jq -r '.seaplane_redis_endpoint.value // ""')
    _REDIS_PORT=$(echo "$OUTPUTS" | jq -r '.seaplane_redis_port.value // ""')
    if [[ -n "$_REDIS_HOST" && -n "$_REDIS_PORT" ]]; then
        REDIS_ENDPOINT="${_REDIS_HOST}:${_REDIS_PORT}"
    else
        REDIS_ENDPOINT=""
    fi
else
    API_TARGET_GROUP_ARN=""
    THANOS_TARGET_GROUP_ARN=""
    THANOS_QUERY_TARGET_GROUP_ARN=""
    LOKI_KMS_KEY_ARN=""
    LOKI_DISTRIBUTOR_TARGET_GROUP_ARN=""
    LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN=""
    OIDC_BUCKET_NAME=""
    OIDC_CLOUDFRONT_DOMAIN=""
    SRE_GRAFANA_TARGET_GROUP_ARN=""
    SRE_ARGOCD_TARGET_GROUP_ARN=""
    SRE_PROMETHEUS_TARGET_GROUP_ARN=""
    SRE_THANOS_TARGET_GROUP_ARN=""
    SRE_ALB_DNS_NAME=""
    SRE_DOMAIN=""
    REDIS_ENDPOINT=""
fi

RHOBS_API_URL="${RHOBS_API_URL:-}"
DNS_ZONE_OPERATOR_ROLE_ARN="${DNS_ZONE_OPERATOR_ROLE_ARN:-}"
OIDC_KEY_READER_ROLE_ARN="${OIDC_KEY_READER_ROLE_ARN:-}"

OVERRIDES_JSON=$(jq -nc \
  --arg cluster_name "$CLUSTER_NAME" \
  --arg cluster_type "$CLUSTER_TYPE" \
  --arg repository_url "$REPOSITORY_URL" \
  --arg repository_path "$APPLICATIONSET_PATH" \
  --arg repository_branch "$REPOSITORY_BRANCH" \
  --arg environment "$ENVIRONMENT" \
  --arg aws_region "$AWS_REGION" \
  --arg image_registry_account_id "${IMAGE_REGISTRY_ACCOUNT_ID:-}" \
  --arg region_deployment "$REGION_DEPLOYMENT" \
  --arg api_target_group_arn "$API_TARGET_GROUP_ARN" \
  --arg thanos_target_group_arn "$THANOS_TARGET_GROUP_ARN" \
  --arg thanos_query_target_group_arn "$THANOS_QUERY_TARGET_GROUP_ARN" \
  --arg loki_kms_key_arn "$LOKI_KMS_KEY_ARN" \
  --arg loki_distributor_target_group_arn "$LOKI_DISTRIBUTOR_TARGET_GROUP_ARN" \
  --arg loki_query_frontend_target_group_arn "$LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN" \
  --arg rhobs_api_url "$RHOBS_API_URL" \
  --arg dns_zone_operator_role_arn "$DNS_ZONE_OPERATOR_ROLE_ARN" \
  --arg oidc_key_reader_role_arn "$OIDC_KEY_READER_ROLE_ARN" \
  --arg oidc_bucket_name "$OIDC_BUCKET_NAME" \
  --arg oidc_cloudfront_domain "$OIDC_CLOUDFRONT_DOMAIN" \
  --arg sre_grafana_target_group_arn "$SRE_GRAFANA_TARGET_GROUP_ARN" \
  --arg sre_argocd_target_group_arn "$SRE_ARGOCD_TARGET_GROUP_ARN" \
  --arg sre_prometheus_target_group_arn "$SRE_PROMETHEUS_TARGET_GROUP_ARN" \
  --arg sre_thanos_target_group_arn "$SRE_THANOS_TARGET_GROUP_ARN" \
  --arg sre_alb_dns_name "$SRE_ALB_DNS_NAME" \
  --arg sre_domain "$SRE_DOMAIN" \
  --arg redis_endpoint "$REDIS_ENDPOINT" \
  '{
    containerOverrides: [{
      name: "bootstrap",
      environment: [
        {name: "CLUSTER_NAME", value: $cluster_name},
        {name: "CLUSTER_TYPE", value: $cluster_type},
        {name: "REPOSITORY_URL", value: $repository_url},
        {name: "REPOSITORY_PATH", value: $repository_path},
        {name: "REPOSITORY_BRANCH", value: $repository_branch},
        {name: "ENVIRONMENT", value: $environment},
        {name: "AWS_REGION", value: $aws_region},
        {name: "IMAGE_REGISTRY_ACCOUNT_ID", value: $image_registry_account_id},
        {name: "REGION_DEPLOYMENT", value: $region_deployment},
        {name: "API_TARGET_GROUP_ARN", value: $api_target_group_arn},
        {name: "THANOS_TARGET_GROUP_ARN", value: $thanos_target_group_arn},
        {name: "THANOS_QUERY_TARGET_GROUP_ARN", value: $thanos_query_target_group_arn},
        {name: "LOKI_KMS_KEY_ARN", value: $loki_kms_key_arn},
        {name: "LOKI_DISTRIBUTOR_TARGET_GROUP_ARN", value: $loki_distributor_target_group_arn},
        {name: "LOKI_QUERY_FRONTEND_TARGET_GROUP_ARN", value: $loki_query_frontend_target_group_arn},
        {name: "RHOBS_API_URL", value: $rhobs_api_url},
        {name: "DNS_ZONE_OPERATOR_ROLE_ARN", value: $dns_zone_operator_role_arn},
        {name: "OIDC_KEY_READER_ROLE_ARN", value: $oidc_key_reader_role_arn},
        {name: "OIDC_BUCKET_NAME", value: $oidc_bucket_name},
        {name: "OIDC_CLOUDFRONT_DOMAIN", value: $oidc_cloudfront_domain},
        {name: "SRE_GRAFANA_TARGET_GROUP_ARN", value: $sre_grafana_target_group_arn},
        {name: "SRE_ARGOCD_TARGET_GROUP_ARN", value: $sre_argocd_target_group_arn},
        {name: "SRE_PROMETHEUS_TARGET_GROUP_ARN", value: $sre_prometheus_target_group_arn},
        {name: "SRE_THANOS_TARGET_GROUP_ARN", value: $sre_thanos_target_group_arn},
        {name: "SRE_ALB_DNS_NAME", value: $sre_alb_dns_name},
        {name: "SRE_DOMAIN", value: $sre_domain},
        {name: "REDIS_ENDPOINT", value: $redis_endpoint}
      ]
    }]
  }')

# ECS RunTask enforces an 8192-character limit on the serialized --overrides value.
if [[ ${#OVERRIDES_JSON} -gt 8192 ]]; then
    echo "ERROR: --overrides payload is ${#OVERRIDES_JSON} characters, over the ECS 8192-character limit" >&2
    exit 1
fi

echo "Bootstrapping ArgoCD on $CLUSTER_NAME"
set +e
RUN_TASK_OUTPUT=$(aws ecs run-task \
  --cluster "$ECS_CLUSTER_ARN" \
  --task-definition "$TASK_DEFINITION_ARN" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNETS],securityGroups=[$BOOTSTRAP_SECURITY_GROUP],assignPublicIp=DISABLED}" \
  --overrides "$OVERRIDES_JSON" 2>&1)
RUN_TASK_EXIT_CODE=$?
set -e

# Check if run-task succeeded
if [[ $RUN_TASK_EXIT_CODE -eq 0 ]] && echo "$RUN_TASK_OUTPUT" | grep -q '"failures":\s*\[\]'; then
  TASK_ARN=$(echo "$RUN_TASK_OUTPUT" | jq -r '.task.taskArn // .tasks[0].taskArn // empty')
  if [[ -z "$TASK_ARN" || "$TASK_ARN" == "null" ]]; then
    echo "ERROR: Could not extract task ARN from response" >&2
    exit 1
  fi
else
  echo "ERROR: Failed to start ECS task" >&2
  echo "$RUN_TASK_OUTPUT" >&2
  exit 1
fi

LAST_EVENT_TIME=0

# Monitor task status
while true; do
    # Fetch recent log events (last 30 seconds worth)
    START_TIME=$(($(date +%s) * 1000 - 30000))
    if [[ $LAST_EVENT_TIME -gt 0 ]]; then
        START_TIME=$LAST_EVENT_TIME
    fi

    LOG_EVENTS=$(aws logs filter-log-events \
        --log-group-name "$LOG_GROUP" \
        --start-time "$START_TIME" \
        --output json 2>/dev/null || echo '{"events":[]}')

    # Print new log events
    echo "$LOG_EVENTS" | jq -r '.events[] | .message' 2>/dev/null || true

    # Update last event timestamp (add 1 to exclude already-seen events on next poll)
    NEW_LAST_TIME=$(echo "$LOG_EVENTS" | jq -r '[.events[].timestamp] | max // 0' 2>/dev/null || echo "0")
    if [[ "$NEW_LAST_TIME" != "null" && "$NEW_LAST_TIME" != "0" ]]; then
        LAST_EVENT_TIME=$((NEW_LAST_TIME + 1))
    fi

    TASK_STATUS=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER_ARN" --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text)

    if [[ "$TASK_STATUS" == "STOPPED" ]]; then
        # Fetch any remaining logs after task stopped
        sleep 2
        FINAL_LOGS=$(aws logs filter-log-events \
            --log-group-name "$LOG_GROUP" \
            --start-time "$LAST_EVENT_TIME" \
            --output json 2>/dev/null || echo '{"events":[]}')
        echo "$FINAL_LOGS" | jq -r '.events[] | .message' 2>/dev/null || true
        TASK_DETAILS=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER_ARN" --tasks "$TASK_ARN")
        EXIT_CODE=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].containers[0].exitCode // "null"')

        if [[ "$EXIT_CODE" == "0" ]]; then
            exit 0
        fi

        STOP_REASON=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].stoppedReason // "unknown"')
        CONTAINER_REASON=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].containers[0].reason // "unknown"')
        echo "ERROR: Bootstrap failed (exit=$EXIT_CODE, stop=$STOP_REASON, container=$CONTAINER_REASON)" >&2
        if [[ "$EXIT_CODE" == "null" || -z "$EXIT_CODE" ]]; then
            echo "$TASK_DETAILS" | jq '.tasks[0] | {lastStatus, stoppedReason, stopCode, containers: [.containers[] | {name, exitCode, reason, lastStatus}]}' >&2
        fi
        exit 1
    fi

    # Poll every 5 seconds for log updates
    sleep 5
done
