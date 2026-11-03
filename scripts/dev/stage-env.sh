#!/usr/bin/env bash
#
# Stage environment CLI for ROSA Seaplane.
#
# Provides interactive access to the standing stage environment.
# Uses AWS profiles with SAML authentication.
#
# Typically invoked via Makefile targets (make stage-shell, etc.)
#
# The script constructs a temporary AWS config with the stage profiles.
# Account IDs default to rosa-seaplane-internal; override with RRP_ACCOUNTS_STAGE.

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}"
CI_IMAGE="rosa-regional-ci"

STAGE_REGION="us-east-1"
RC_CLUSTER="regional"
MC_CLUSTER="mc01"

STAGE_API_URL="https://api.us-east-1.stg0.rosa.devshift.org"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env-common.sh"

# =============================================================================
# Helpers
# =============================================================================

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  shell           Interactive shell for Platform API access"
    echo "  bastion         Connect to RC/MC bastion"
    echo "  port-forward    Forward ports through RC/MC bastion"
    echo "  e2e             Run e2e tests"
    echo "  dump-env        Dump EKS must-gather and DB state from RC/MC"
}

usage_bastion() {
    echo "Usage: $0 bastion --cluster-type [value]"
    echo ""
    echo "Connect to RC/MC bastion in the stage environment"
    echo ""
    echo "Flags:"
    echo "  --cluster-type  Cluster type: \"regional\" or \"management\""
}

usage_port_forward() {
    echo "Usage: $0 port-forward --cluster-type [value] [--all | --service <name>]"
    echo ""
    echo "Opens port forwards to services running on a cluster"
    echo ""
    echo "Flags:"
    echo "  --all              Automatically open all port forwards"
    echo "  --service <name>   Forward a specific service (argocd, prometheus, loki, grafana)"
    echo "  --cluster-type     Cluster type: \"regional\" or \"management\""
}

cluster_id_for() {
    case "$1" in
        regional)   echo "$RC_CLUSTER" ;;
        management) echo "$MC_CLUSTER" ;;
        *)          die "Unknown cluster type: $1" ;;
    esac
}

profile_for() {
    case "$1" in
        regional)   echo "rrp-stage-rc" ;;
        management) echo "rrp-stage-mc" ;;
        *)          die "Unknown cluster type: $1" ;;
    esac
}

# Create temporary AWS config with stage profiles.
setup_aws_config() {
    local accounts_file="${RRP_ACCOUNTS_STAGE:-${REPO_ROOT}/../rosa-seaplane-internal/infra/accounts/stage/terragrunt-accounts.json}"
    [[ -f "$accounts_file" ]] \
        || die "Account IDs file not found: $accounts_file
    Either clone rosa-seaplane-internal as a sibling directory,
    or set RRP_ACCOUNTS_STAGE to point to your accounts JSON file.
    See docs/development-environment.md for details."

    # Stage accounts.json has a different structure than int:
    # - control_account_id (not "central")
    # - Account IDs are nested under region: us-east-1.rc_account_id, us-east-1.mc_account_ids.mc01
    CENTRAL_ACCOUNT=$(jq -r '.control_account_id' "$accounts_file") \
        || die "Failed to parse control_account_id from $accounts_file"
    [[ "$CENTRAL_ACCOUNT" != "null" ]] || die "Missing control_account_id in $accounts_file"

    RC_ACCOUNT=$(jq -r ".\"${STAGE_REGION}\".rc_account_id" "$accounts_file") \
        || die "Failed to parse ${STAGE_REGION}.rc_account_id from $accounts_file"
    [[ "$RC_ACCOUNT" != "null" ]] || die "Missing ${STAGE_REGION}.rc_account_id in $accounts_file"

    MC_ACCOUNT=$(jq -r ".\"${STAGE_REGION}\".mc_account_ids.${MC_CLUSTER}" "$accounts_file") \
        || die "Failed to parse ${STAGE_REGION}.mc_account_ids.${MC_CLUSTER} from $accounts_file"
    [[ "$MC_ACCOUNT" != "null" ]] || die "Missing ${STAGE_REGION}.mc_account_ids.${MC_CLUSTER} in $accounts_file"

    # The HCP account serves as the e2e customer account. It is optional so
    # bastion/port-forward work even before it is minted.
    CUSTOMER_ACCOUNT=$(jq -r ".\"${STAGE_REGION}\".hcp_account_id // empty" "$accounts_file")

    init_aws_config

    # Stage uses rosa-seaplane-account-admin role (minted by internal repo)
    # instead of OrganizationAccountAccessRole
    cat > "$AWS_CONFIG_FILE" <<AWSCFG
[profile rrp-stage-admin]
credential_process = uv run ${SCRIPT_DIR}/cached_saml_credentials_process.py ${CENTRAL_ACCOUNT} ${CENTRAL_ACCOUNT}-rosa-hyperfleet-stage-admin
region = ${STAGE_REGION}
duration_seconds = 3600

[profile rrp-stage-rc]
role_arn = arn:aws:iam::${RC_ACCOUNT}:role/rosa-seaplane-account-admin
source_profile = rrp-stage-admin
region = ${STAGE_REGION}
duration_seconds = 3600

[profile rrp-stage-mc]
role_arn = arn:aws:iam::${MC_ACCOUNT}:role/rosa-seaplane-account-admin
source_profile = rrp-stage-admin
region = ${STAGE_REGION}
duration_seconds = 3600
AWSCFG

    # Add customer profile only if customer account exists
    if [[ -n "$CUSTOMER_ACCOUNT" ]]; then
        cat >> "$AWS_CONFIG_FILE" <<AWSCFG

[profile rrp-stage-customer]
role_arn = arn:aws:iam::${CUSTOMER_ACCOUNT}:role/rosa-seaplane-account-admin
source_profile = rrp-stage-admin
region = ${STAGE_REGION}
duration_seconds = 3600
AWSCFG
    fi

    echo "AWS config written to: $AWS_CONFIG_FILE"
}

# Resolve stage profiles to static container credentials.
write_stage_container_config() {
    local profiles=(
        "rrp-stage-rc rrp-rc ${STAGE_REGION}"
        "rrp-stage-mc rrp-mc ${STAGE_REGION}"
    )
    # Add customer profile only if customer account exists
    if [[ -n "${CUSTOMER_ACCOUNT:-}" ]]; then
        profiles+=("rrp-stage-customer rrp-customer ${STAGE_REGION}")
    fi
    write_container_config "${profiles[@]}"
}

# =============================================================================
# Bastion helpers (shared by bastion + port-forward)
# =============================================================================

bastion_setup() {
    local cluster_type="$1"
    local cluster_id

    cluster_id=$(cluster_id_for "$cluster_type")

    setup_aws_config
    export AWS_PROFILE="$(profile_for "$cluster_type")"
    export AWS_DEFAULT_REGION="$STAGE_REGION"
    export AWS_REGION="$STAGE_REGION"

    echo "Connecting to stage bastion..."
    echo "  Cluster type: $cluster_type"
    echo "  Cluster ID:   $cluster_id"
    echo "  Region:       $STAGE_REGION"
    echo ""

    bastion_run_task "$cluster_id"
}

# =============================================================================
# Commands
# =============================================================================

cmd_shell() {
    setup_aws_config
    write_stage_container_config

    local api_url="${API_URL:-$STAGE_API_URL}"

    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm -it \
        $_CONTAINER_AWS_FLAGS \
        -e "AWS_PROFILE=rrp-rc" \
        -e "AWS_DEFAULT_REGION=$STAGE_REGION" \
        -e "AWS_REGION=$STAGE_REGION" \
        -e "API_URL=$api_url" \
        "$CI_IMAGE" \
        bash -c '
            echo ""
            echo "ROSA Seaplane — Stage Environment"
            echo ""
            echo "Region:      $AWS_DEFAULT_REGION"
            echo "API Gateway: $API_URL"
            echo ""
            echo "Example commands:"
            echo "  awscurl --service execute-api \$API_URL/api/v0/live"
            exec bash'
}

cmd_bastion() {
    local cluster_type

    while [ "${1:-}" != "" ]; do
        case $1 in
            --cluster-type )    cluster_type=${2:-}
                                shift
                                ;;
            --help )            usage_bastion
                                exit 0
                                ;;
            * ) echo "Unexpected parameter $1"
                usage_bastion
                exit 1
        esac
        shift
    done

    case "$cluster_type" in
      regional|management) ;;
      *) echo "Error: invalid cluster type '${cluster_type:-}'"; echo ""; usage_bastion; exit 1 ;;
    esac

    bastion_setup "$cluster_type"

    echo ""
    echo "==> Bastion task ready"
    echo "    ECS cluster: $ecs_cluster"
    echo "    Task ID:     $task_id"
    echo ""
    echo "==> Connecting to bastion..."
    echo ""

    aws ecs execute-command \
        --cluster "$ecs_cluster" \
        --task "$task_id" \
        --container bastion \
        --interactive \
        --command '/bin/bash'
}

cmd_port_forward() {
    local all_svcs=false
    local cluster_type
    local SERVICE=""

    while [ "${1:-}" != "" ]; do
    case $1 in
        --all )                 all_svcs=true
                                ;;
        --service )             SERVICE="${2:-}"
                                shift
                                ;;
        --cluster-type )        cluster_type=${2:-}
                                shift
                                ;;
        --help )                usage_port_forward
                                exit 0
                                ;;
        * ) echo "Unexpected parameter $1"
            usage_port_forward
            exit 1
    esac
    shift
    done

    case "$cluster_type" in
      regional|management) ;;
      *) echo "Error: invalid cluster type '${cluster_type:-}'"; echo ""; usage_port_forward; exit 1 ;;
    esac

    local argocd="argocd    - ArgoCD server HTTPS"
    local prometheus="prometheus  - Prometheus Monitoring Dashboard"
    local loki="loki      - Loki Query Frontend (platform logs)"
    local grafana="grafana   - Grafana Dashboard"

    local regional_svc_list=("$argocd" "$prometheus" "$loki" "$grafana")
    local management_svc_list=("$argocd" "$prometheus")

    local services

    if [ $all_svcs == true ]; then
        case "$cluster_type" in
            regional )      services=$(printf '%s\n' "${regional_svc_list[@]}") ;;
            management )    services=$(printf '%s\n' "${management_svc_list[@]}") ;;
        esac
    elif [[ -n "$SERVICE" ]]; then
        services="$SERVICE"
    elif command -v fzf >/dev/null 2>&1; then
        if [ "$cluster_type" = "regional" ]; then
            services=$(printf '%s\n' "${regional_svc_list[@]}" \
                | fzf --multi --height=10 --layout=reverse --header="Select service (${cluster_type}):" --no-info)
        else
            services=$(printf '%s\n' "${management_svc_list[@]}" \
                | fzf --multi --height=10 --layout=reverse --header="Select service (${cluster_type}):" --no-info)
        fi
        [[ -n "$services" ]] || { echo "Aborted."; exit 1; }
    else
        die "Use --all, --service <name>, or install fzf for interactive selection."
    fi
    services=$(awk '{print $1}' <<< "$services" | tr '\n' ' ')

    local forwards=()
    for service in $services
    do
        case "$service" in
        argocd)
            forwards+=(
            "ArgoCD-Server 8443 8443 argocd-server argocd 443"
            )
            ;;
        prometheus)
            forwards+=(
            "Prometheus 9090 9090 monitoring-prometheus monitoring 9090"
            )
            ;;
        loki)
            forwards+=(
            "Loki-Query 13100 13100 loki-query-frontend loki 3100"
            )
            ;;
        grafana)
            forwards+=(
            "Grafana 3000 3000 grafana grafana 80"
            )
            ;;
        *) echo "Error: unknown service '$service'"; exit 1 ;;
        esac
    done

    # Check local ports are free
    for entry in "${forwards[@]}"; do
        local local_port
        read -r label _ local_port _ _ _ <<< "$entry"
        if lsof -iTCP:"$local_port" -sTCP:LISTEN -t &>/dev/null; then
            echo "Error: Local port ${local_port} (${label}) is already in use."
            echo "Kill the process using it first: lsof -iTCP:${local_port} -sTCP:LISTEN"
            exit 1
        fi
    done

    bastion_setup "$cluster_type"

    local runtime_id
    runtime_id=$(aws ecs describe-tasks \
      --cluster "$ecs_cluster" \
      --tasks "$task_id" \
      --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' \
      --output text)

    if [[ -z "$runtime_id" || "$runtime_id" == "None" ]]; then
      echo "Error: runtime_id not found for task '$task_id' in cluster '$ecs_cluster'"
      exit 1
    fi

    echo ""
    echo "==> Bastion task ready"
    echo "    ECS cluster: $ecs_cluster"
    echo "    Task ID:     $task_id"
    echo ""
    echo "==> Connecting to bastion..."
    echo ""

    ssm_pids=()
    bastion_pids=()

    # Chain with the existing EXIT trap (setup_aws_config cleanup)
    _prev_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    cleanup() {
    echo ""
    echo "Stopping all port-forward sessions..."
    for pid in "${ssm_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${bastion_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    eval "$_prev_trap"
    }
    trap cleanup EXIT

    target="ecs:${ecs_cluster}_${task_id}_${runtime_id}"

    # Kill stale port-forwards on bastion
    echo "==> Cleaning up stale port-forwards on bastion..."
    aws ecs execute-command \
    --cluster "$ecs_cluster" \
    --task "$task_id" \
    --container bastion \
    --interactive \
    --command "pkill -f kubectl.port-forward || true" &>/dev/null || true
    sleep 2

    # Start kubectl port-forward(s) inside the bastion
    for entry in "${forwards[@]}"; do
        read -r label remote_port local_port k8s_svc k8s_ns k8s_svc_port <<< "$entry"

        echo "==> [bastion] kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns}"
        aws ecs execute-command \
            --cluster "$ecs_cluster" \
            --task "$task_id" \
            --container bastion \
            --interactive \
            --command "kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns} --address 0.0.0.0" &
        bastion_pids+=($!)
    done

    echo ""
    echo "==> Waiting for kubectl port-forward(s) to be ready..."
    sleep 5

    # SSM port forward from laptop to bastion
    for entry in "${forwards[@]}"; do
        read -r label remote_port local_port _ _ _ <<< "$entry"

        echo "==> [local] SSM forwarding ${label} (localhost:${local_port} -> bastion:${remote_port})..."
        aws ssm start-session \
            --target "$target" \
            --document-name AWS-StartPortForwardingSession \
            --parameters "{\"portNumber\":[\"${remote_port}\"],\"localPortNumber\":[\"${local_port}\"]}" &
        ssm_pids+=($!)
    done

    echo ""
    echo "==> Port forwarding active. Forwarded ports:"
    for entry in "${forwards[@]}"; do
        read -r label _ local_port _ _ _ <<< "$entry"
        echo "    ${label}: http://localhost:${local_port}"
    done

    # For ArgoCD, fetch and display the admin password from the bastion.
    if [[ " $services " =~ " argocd " ]]; then
        echo ""
        echo "==> Fetching ArgoCD admin password..."
        argocd_get_password=$(aws ecs execute-command \
            --cluster "$ecs_cluster" \
            --task "$task_id" \
            --container bastion \
            --interactive \
            --command "sh -c \"echo ARGOCD_PW=\$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d)\"" 2>/dev/null || true)
        argocd_password=$(echo "$argocd_get_password" | grep -o 'ARGOCD_PW=.*' | cut -d= -f2 | tr -d '[:space:]')
        echo ""
        echo "    ArgoCD UI:       https://localhost:8443"
        echo "    Username:        admin"
        if [ -n "$argocd_password" ]; then
            echo "    Password:        ${argocd_password}"
        else
            echo "    Password:        (could not retrieve - run on bastion manually):"
            echo "                     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d"
        fi
    fi

    echo ""
    echo "Press Ctrl+C to stop."

    while true; do
    for pid in "${ssm_pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        echo ""
        echo "Error: SSM port-forward session (PID $pid) exited unexpectedly."
        exit 1
        fi
    done
    sleep 2
    done
}

cmd_e2e() {
    local e2e_ref="${E2E_REF:-main}"
    local e2e_repo="${E2E_REPO:-https://github.com/openshift-online/rosa-seaplane-api.git}"

    setup_aws_config
    write_stage_container_config

    local api_url="${API_URL:-$STAGE_API_URL}"

    echo "Running e2e tests..."
    echo "  API_URL:    $api_url"
    echo "  REGION:     $STAGE_REGION"
    echo "  E2E_REF:    $e2e_ref"
    echo "  E2E_REPO:   $e2e_repo"

    $CONTAINER_ENGINE run --rm \
        $_CONTAINER_AWS_FLAGS \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -w /workspace \
        -e "BASE_URL=$api_url" \
        -e "AWS_DEFAULT_REGION=$STAGE_REGION" \
        -e "AWS_REGION=$STAGE_REGION" \
        -e "E2E_REF=$e2e_ref" \
        -e "E2E_REPO=$e2e_repo" \
        "$CI_IMAGE" \
        bash ci/e2e-tests.sh
}

cmd_dump_env() {
    local cluster_type="${1:-all}"
    case "$cluster_type" in
        rc) cluster_type="regional" ;;
        mc) cluster_type="management" ;;
    esac

    setup_aws_config
    write_stage_container_config

    # dump-env.sh runs on the host (not in a container) but needs the
    # standardized profile names (rrp-rc, rrp-mc). Point it at the resolved
    # container config which has those profiles with static credentials.
    export AWS_CONFIG_FILE="$_CONTAINER_CONFIG"
    export AWS_SHARED_CREDENTIALS_FILE=/dev/null
    export AWS_REGION="$STAGE_REGION"
    export CLUSTER_PREFIX=""
    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
        export LOG_OUTPUT_DIR="$ARTIFACT_DIR"
    fi

    "${REPO_ROOT}/scripts/dev/dump-env.sh" "$cluster_type"
}

# =============================================================================
# Main
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

case "${1:-help}" in
    bastion|dump-env)
        for tool in jq uv aws; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
    port-forward)
        for tool in jq uv aws lsof; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
    shell|e2e)
        for tool in jq uv aws; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ensure_image
        ;;
esac

case "${1:-help}" in
    shell)          cmd_shell ;;
    bastion)        shift; cmd_bastion "$@" ;;
    port-forward)   shift; cmd_port_forward "$@" ;;
    e2e)            cmd_e2e ;;
    dump-env)       shift; cmd_dump_env "$@" ;;
    help|*)
        usage
        ;;
esac
