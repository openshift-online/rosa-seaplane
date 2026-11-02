#!/usr/bin/env bash
# Bootstrap ArgoCD on a Regional Cluster.
# Called from: scripts/buildspec/provision-cluster.sh
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check

ENVIRONMENT="${ENVIRONMENT:-staging}"
RC_CONFIG_FILE=$(config_path_for_mode regional)
if [ ! -f "$RC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $RC_CONFIG_FILE" >&2
    exit 1
fi

DELETE_FLAG="${IS_DESTROY:-false}"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "delete=true — skipping ArgoCD bootstrap"
    exit 0
fi

# Switch to the RC account before reading its local registry-account parameter.
switch_to_target_account_and_resolve_image_registry_account_id \
    "$(jq -r '.image_registry_account_id // empty' "$RC_CONFIG_FILE")"
terraform_init_backend regional-cluster "${TARGET_REGION}" "${REGIONAL_ID}"
bootstrap_argocd regional-cluster "${TARGET_ACCOUNT_ID}"
