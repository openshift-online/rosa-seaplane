#!/usr/bin/env bash
# Unified cluster provisioning wrapper for RC and MC.
# Called from: combined buildspecs
#
# Usage: provision-cluster.sh <cluster-type>
#   cluster-type: regional-cluster | RC | rc | management-cluster | MC | mc
#
# Flow:
#   1. Call provision-infra-<type>.sh
#   2. Call bootstrap/register scripts per cluster type
set -euo pipefail

CLUSTER_TYPE_ARG="${1:?Usage: provision-cluster.sh <regional-cluster|RC|rc|management-cluster|MC|mc>}"

# Normalize cluster type (accept regional-cluster/RC/rc and management-cluster/MC/mc)
case "${CLUSTER_TYPE_ARG,,}" in  # ${var,,} = lowercase
    regional-cluster|rc)
        CLUSTER_TYPE="regional-cluster"
        ;;
    management-cluster|mc)
        CLUSTER_TYPE="management-cluster"
        ;;
    *)
        echo "ERROR: Unknown cluster type '${CLUSTER_TYPE_ARG}'. Expected: regional-cluster|RC|rc|management-cluster|MC|mc" >&2
        exit 1
        ;;
esac

# ── Phase 0: Initialize exported variables ───────────────────────────────────
# Set APPLIED=false first so an early exit/failure reports APPLIED=false.
# 66718's CI gate reads SUCCEEDED && APPLIED==true && APPLIED_SHA==<desired> to
# confirm the cluster reached its desired GitOps state (applied or destroyed).
export APPLIED=false
export APPLIED_SHA=""

# CodeBuild reports the outer BUILD phase. These markers expose the actual
# RC/MC operations performed inside that phase, including their durations.
run_timed_step() {
    local step_name="$1"
    shift
    local step_start=$SECONDS

    echo "provision-step: START ${step_name}"
    if "$@"; then
        echo "provision-step: SUCCEEDED ${step_name} duration=$((SECONDS - step_start))s"
    else
        local exit_code=$?
        echo "provision-step: FAILED ${step_name} duration=$((SECONDS - step_start))s exit_code=${exit_code}" >&2
        return "$exit_code"
    fi
}

# ── Phase 1: Provision infrastructure ────────────────────────────────────────
# Under CodePipeline + SUPERSEDED only one execution per pipeline reaches the
# build stage, so there is no build queue to de-duplicate here.
echo "provision-cluster: proceeding with ${CLUSTER_TYPE} provisioning"

case "$CLUSTER_TYPE" in
    regional-cluster)
        echo "provision-cluster: Regional Cluster (RC) pipeline"
        run_timed_step "RC Terraform infrastructure" ./scripts/buildspec/provision-infra-rc.sh
        run_timed_step "RC ArgoCD bootstrap" ./scripts/buildspec/bootstrap-argocd-rc.sh
        run_timed_step "RC Platform API live readiness" ./scripts/buildspec/wait-for-regional-api.sh
        ;;

    management-cluster)
        echo "provision-cluster: Management Cluster (MC) pipeline"
        run_timed_step "MC Terraform infrastructure" ./scripts/buildspec/provision-infra-mc.sh
        run_timed_step "MC ZOA target registration" ./scripts/buildspec/provision-mc-zoa-target-ssm.sh
        run_timed_step "MC kube-applier DynamoDB" ./scripts/buildspec/provision-kube-applier-dynamodb.sh
        run_timed_step "MC ArgoCD bootstrap" ./scripts/buildspec/bootstrap-argocd-mc.sh
        run_timed_step "MC API readiness and registration" ./scripts/buildspec/register.sh
        ;;

esac

echo "provision-cluster: ${CLUSTER_TYPE} provisioning complete"

# ── Phase 2: Mark as applied ──────────────────────────────────────────────────
# All phase scripts succeeded (terraform apply/destroy + bootstrap/register). Set
# APPLIED=true so the CI gate accepts this build. APPLIED_SHA is the git commit.
# Dual meaning: for provision builds APPLIED=true means "this SHA's config was
# applied"; for destroy builds (IS_DESTROY=true) it means "this SHA was fully
# processed (infra destroyed)". The phase scripts already honor IS_DESTROY.
export APPLIED=true
export APPLIED_SHA="${CODEBUILD_RESOLVED_SOURCE_VERSION}"
