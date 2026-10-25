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

use_mc_account
terraform_init_backend regional-cluster "${TARGET_REGION}" "${REGIONAL_ID}"
bootstrap_argocd regional-cluster "${TARGET_ACCOUNT_ID}"
