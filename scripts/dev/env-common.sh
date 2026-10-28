#!/usr/bin/env bash
#
# Shared utilities for ROSA Seaplane dev environment scripts.
#
# Sourced by ephemeral-env.sh and int-env.sh. Not executable on its own.
#
# Functions provided:
#   die                   — Print error and exit
#   resolve_creds         — Resolve AWS profile to static credentials
#   ensure_image          — Build CI container image if not present
#   load_accounts         — Load account IDs from a JSON file (legacy flat format)
#   load_accounts_stage   — Load account IDs from stage nested JSON format
#   init_aws_config       — Create temp AWS config dir + EXIT trap
#   container_aws_role_session_name_flags — podman -e for AWS_ROLE_SESSION_NAME in e2e containers
#   write_container_config — Resolve profiles to static creds for container mount
#   write_e2e_host_aws_config — CI e2e host: resolve assume-role profiles (stable session name)
#   bastion_run_task      — Core ECS bastion task launch and readiness logic
#   chain_exit_trap       — Chain a new EXIT handler with any existing trap
#   bastion_port_forward  — kubectl port-forward on bastion + SSM to localhost
#   bastion_port_forward_cleanup — Tear down forwards; stop owned ECS tasks only
#   require_session_manager_plugin — fail if session-manager-plugin is not on PATH

# Sourcing scripts should set these before sourcing:
#   CONTAINER_ENGINE, CI_IMAGE

die() {
    echo "Error: $*" >&2
    if [[ "${BASTION_SOFT_FAIL:-}" == "1" ]]; then
        return 1
    fi
    exit 1
}

# Resolve the base SAML credentials from a credential_process profile.
# The credential_process is not cached by the AWS CLI, so this always returns
# fresh credentials. Results are cached in-process for the given profile.
# Args: $1 = base profile name (the one with credential_process)
# Sets: _BASE_AK, _BASE_SK, _BASE_ST
resolve_base_creds() {
    local base_profile="$1"
    if [[ "${_BASE_RESOLVED_PROFILE:-}" == "$base_profile" ]]; then
        return 0
    fi
    echo "Resolving base credentials..."
    local creds creds_err
    creds_err=$(mktemp)
    creds=$(aws configure export-credentials --profile "$base_profile" --format process 2>"$creds_err") \
        || { local err; err=$(<"$creds_err"); rm -f "$creds_err"; die "Failed to resolve base credentials ($base_profile):\n$err"; }
    rm -f "$creds_err"
    _BASE_AK=$(echo "$creds" | jq -r '.AccessKeyId')
    _BASE_SK=$(echo "$creds" | jq -r '.SecretAccessKey')
    _BASE_ST=$(echo "$creds" | jq -r '.SessionToken // empty')
    _BASE_RESOLVED_PROFILE="$base_profile"
}

# Assume a role using the base SAML credentials, bypassing the CLI's profile cache.
# Reads source_profile and role_arn from the given profile config.
# Sets: _CRED_AK, _CRED_SK, _CRED_ST
resolve_creds() {
    local profile="$1"
    local session_name="${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e}"
    echo "Resolving credentials for profile ${profile} (RoleSessionName=${session_name})..."

    local role_arn base_profile
    role_arn=$(aws configure get role_arn --profile "$profile" 2>/dev/null) \
        || die "No role_arn found for profile $profile"
    base_profile=$(aws configure get source_profile --profile "$profile" 2>/dev/null) \
        || die "No source_profile found for profile $profile"

    resolve_base_creds "$base_profile"

    local creds creds_err
    creds_err=$(mktemp)
    local session_name="${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e}"
    creds=$(AWS_ACCESS_KEY_ID="$_BASE_AK" AWS_SECRET_ACCESS_KEY="$_BASE_SK" AWS_SESSION_TOKEN="$_BASE_ST" \
        aws sts assume-role --role-arn "$role_arn" --role-session-name "$session_name" \
        --duration-seconds 3600 --output json 2>"$creds_err") \
        || { local err; err=$(<"$creds_err"); rm -f "$creds_err"; die "Failed to assume role $role_arn:\n$err"; }
    rm -f "$creds_err"
    _CRED_AK=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
    _CRED_SK=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
    _CRED_ST=$(echo "$creds" | jq -r '.Credentials.SessionToken')
}

# Build the CI container image if not already present.
ensure_image() {
    [[ -n "$CONTAINER_ENGINE" ]] \
        || die "No container engine found. Install podman or docker."

    if ! $CONTAINER_ENGINE image inspect "$CI_IMAGE" >/dev/null 2>&1; then
        echo "Building CI image..."
        local -a build_args=()
        [[ -n "${PROXY_CA_CERT:-}" ]] && build_args=("--build-arg" "PROXY_CA_CERT=${PROXY_CA_CERT}")
        local build_output
        if ! build_output=$($CONTAINER_ENGINE build -t "$CI_IMAGE" -f ci/Containerfile "${build_args[@]}" ci 2>&1); then
            echo "$build_output"
            die "Failed to build CI image."
        fi
    fi
}

# Load account IDs from a JSON file (legacy flat format: dev/int).
# Args: $1 = path to accounts.json, $2... = keys to extract
# Each key sets an uppercase variable: e.g. "rc" → RC_ACCOUNT
load_accounts() {
    local json_file="$1"
    shift

    [[ -f "$json_file" ]] || die "Account IDs file not found: $json_file"

    local key upper_key val
    for key in "$@"; do
        upper_key=$(echo "$key" | tr 'a-z' 'A-Z')
        val=$(jq -r ".$key" "$json_file") \
            || die "Failed to parse '$key' from $json_file"
        [[ "$val" != "null" ]] || die "Missing '$key' in $json_file"
        printf -v "${upper_key}_ACCOUNT" '%s' "$val"
    done
}

# Load account IDs from stage nested JSON format (Terragrunt multi-region structure).
# Args: $1 = path to accounts.json, $2 = region (default: us-east-1)
# Sets: CENTRAL_ACCOUNT, RC_ACCOUNT, MC01_ACCOUNT, MC02_ACCOUNT, DR_ACCOUNT, LOG_ACCOUNT
load_accounts_stage() {
    local json_file="$1"
    local region="${2:-us-east-1}"

    [[ -f "$json_file" ]] || die "Account IDs file not found: $json_file"

    local val
    val=$(jq -r ".control_account_id" "$json_file") \
        || die "Failed to parse control_account_id from $json_file"
    [[ "$val" != "null" ]] || die "Missing control_account_id in $json_file"
    CENTRAL_ACCOUNT="$val"

    val=$(jq -r ".[\"$region\"].rc_account_id" "$json_file") \
        || die "Failed to parse region '$region' from $json_file"
    [[ "$val" != "null" ]] || die "Missing RC account ID for region '$region' in $json_file"
    RC_ACCOUNT="$val"

    val=$(jq -r ".[\"$region\"].mc_account_ids.mc01" "$json_file") \
        || die "Failed to parse mc01 from $json_file"
    [[ "$val" != "null" ]] || die "Missing MC01 account ID in $json_file"
    MC01_ACCOUNT="$val"

    val=$(jq -r ".[\"$region\"].mc_account_ids.mc02" "$json_file") \
        || die "Failed to parse mc02 from $json_file"
    [[ "$val" != "null" ]] || die "Missing MC02 account ID in $json_file"
    MC02_ACCOUNT="$val"

    val=$(jq -r ".[\"$region\"].dr_account_id" "$json_file") \
        || die "Failed to parse DR from $json_file"
    [[ "$val" != "null" ]] || die "Missing DR account ID in $json_file"
    DR_ACCOUNT="$val"

    val=$(jq -r ".[\"$region\"].log_account_id" "$json_file") \
        || die "Failed to parse log from $json_file"
    [[ "$val" != "null" ]] || die "Missing log account ID in $json_file"
    LOG_ACCOUNT="$val"
}

# Create temporary AWS config directory and set up EXIT trap.
# Sets: AWS_CONFIG_FILE, AWS_SHARED_CREDENTIALS_FILE, _aws_config_dir
# Caller should write profile heredoc to $AWS_CONFIG_FILE after calling this.
init_aws_config() {
    unset AWS_PROFILE AWS_DEFAULT_PROFILE

    _aws_config_dir=$(mktemp -d)
    export AWS_CONFIG_FILE="$_aws_config_dir/config"
    export AWS_SHARED_CREDENTIALS_FILE="$_aws_config_dir/credentials"
    touch "$AWS_SHARED_CREDENTIALS_FILE"

    trap 'rm -rf "${_aws_config_dir:-}" "${_CONTAINER_CONFIG:-}"' EXIT
}

# Podman/Docker -e flags so in-container e2e (including ephemeral-zoa-e2e) use the
# same stable RoleSessionName as CI (source ci/setup-aws-profiles.sh).
container_aws_role_session_name_flags() {
    local name="${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e}"
    echo "-e AWS_ROLE_SESSION_NAME=${name}"
}

# Build a container-safe AWS config file with resolved static credentials.
# credential_process won't work inside containers, so we resolve creds on the
# host and write them as static keys into a temp config file for mounting.
#
# Args: triplets of "host-profile container-profile region"
#   e.g.: write_container_config "rrp-ephemeral-rc rrp-rc us-east-1" "rrp-ephemeral-mc rrp-mc us-east-1"
#
# Sets: _CONTAINER_CONFIG, _CONTAINER_AWS_FLAGS
write_container_config() {
    _CONTAINER_CONFIG=$(mktemp)
    local first=true

    local spec host_profile container_profile region
    for spec in "$@"; do
        read -r host_profile container_profile region <<< "$spec"
        resolve_creds "$host_profile" || die "Failed to resolve profile ${host_profile}"

        [[ "$first" == "true" ]] || echo "" >> "$_CONTAINER_CONFIG"
        first=false

        cat >> "$_CONTAINER_CONFIG" <<EOF
[profile ${container_profile}]
aws_access_key_id = ${_CRED_AK}
aws_secret_access_key = ${_CRED_SK}
aws_session_token = ${_CRED_ST}
region = ${region}
EOF
    done

    _CONTAINER_AWS_FLAGS="-v ${_CONTAINER_CONFIG}:/tmp/aws-config:ro,z -e AWS_CONFIG_FILE=/tmp/aws-config -e AWS_SHARED_CREDENTIALS_FILE=/dev/null $(container_aws_role_session_name_flags)"
}

# Last path segment of an STS assumed-role ARN (RoleSessionName); empty if not assumed-role.
aws_sts_session_name_from_arn() {
    local arn="$1"
    if [[ "$arn" != *":assumed-role/"* ]]; then
        echo ""
        return 0
    fi
    echo "${arn##*/}"
}

# Print caller identity per profile so CI/dev e2e logs show the active RoleSessionName.
# Args: optional profile names; default all profiles in AWS_CONFIG_FILE.
log_aws_profile_caller_identities() {
    local expected="${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e}"
    echo ""
    echo "=== AWS caller identity (RoleSessionName check) ==="
    echo "Expected session name: ${expected}"
    echo "AWS_CONFIG_FILE: ${AWS_CONFIG_FILE:-<unset>}"
    local -a profiles=("$@")
    if [[ ${#profiles[@]} -eq 0 ]]; then
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] && profiles+=("$p")
        done < <(aws configure list-profiles 2>/dev/null)
    fi
    local p arn session verdict
    for p in "${profiles[@]}"; do
        arn=$(aws sts get-caller-identity --profile "$p" --query Arn --output text 2>/dev/null) || {
            echo "  profile ${p}: get-caller-identity failed"
            continue
        }
        session=$(aws_sts_session_name_from_arn "$arn")
        if [[ "$session" == "$expected" ]]; then
            verdict="OK"
        elif [[ -z "$session" ]]; then
            verdict="not assumed-role"
        else
            verdict="MISMATCH"
        fi
        echo "  profile ${p}: ${arn}"
        echo "    RoleSessionName: ${session:-n/a} [${verdict}]"
    done
    echo "=== End AWS caller identity ==="
    echo ""
}

# ci/e2e-tests.sh on Prow: resolve assume-role profiles from the mounted aws_config
# with resolve_creds (same RoleSessionName as dev write_container_config). Go SDK and
# multi-process e2e need static keys; AWS CLI-only jobs can keep setup-aws-profiles alone.
write_e2e_host_aws_config() {
    [[ "${E2E_HOST_AWS_CONFIG_READY:-}" == "1" ]] && return 0
    [[ -r "${AWS_CONFIG_FILE:-}" ]] || return 0

    local region="${AWS_DEFAULT_REGION:-us-east-1}"
    local -a specs=()
    local p role_arn
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        role_arn=$(aws configure get role_arn --profile "$p" 2>/dev/null || true)
        [[ -n "$role_arn" ]] || continue
        specs+=("${p} ${p} ${region}")
    done < <(aws configure list-profiles 2>/dev/null)

    [[ ${#specs[@]} -eq 0 ]] && {
        echo "WARNING: write_e2e_host_aws_config: no assume-role profiles in ${AWS_CONFIG_FILE}" >&2
        log_aws_profile_caller_identities
        return 0
    }

    write_container_config "${specs[@]}"
    export AWS_CONFIG_FILE="$_CONTAINER_CONFIG"
    export AWS_SHARED_CREDENTIALS_FILE=/dev/null
    export E2E_HOST_AWS_CONFIG_READY=1
    echo "E2e host AWS config: ${#specs[@]} assume-role profile(s), target session ${AWS_CI_ROLE_SESSION_NAME:-seaplane-e2e}"
    log_aws_profile_caller_identities
}

# Core ECS bastion task launch and readiness logic.
# Finds or launches a bastion ECS task, then waits for the exec agent.
#
# Args: $1 = cluster_id (e.g. "eph-abc-regional" or "regional")
# Sets: ecs_cluster, task_id (exported)
bastion_run_task() {
    local cluster_id="$1"
    export ecs_cluster="${cluster_id}-bastion"
    export bastion_task_owned=false

    echo "==> Checking for running bastion tasks..."
    local existing_task
    existing_task=$(aws ecs list-tasks --cluster "$ecs_cluster" \
        --desired-status RUNNING --query 'taskArns[0]' --output text 2>/dev/null || true)

    if [[ -n "$existing_task" && "$existing_task" != "None" ]]; then
        export task_id=$(echo "$existing_task" | awk -F'/' '{print $NF}')
        echo "==> Found existing running task: $task_id"
    else
        export bastion_task_owned=true
        echo "==> No running task found, starting a new one..."

        local task_def="${cluster_id}-bastion"
        local sg_id subnets vpc_id

        sg_id=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${cluster_id}-bastion" \
            --query 'SecurityGroups[0].GroupId' --output text) \
            || die "Could not find security group '${cluster_id}-bastion'."
        [[ "$sg_id" != "None" ]] \
            || die "Security group '${cluster_id}-bastion' not found."

        vpc_id=$(aws ec2 describe-security-groups \
            --group-ids "$sg_id" \
            --query 'SecurityGroups[0].VpcId' --output text)

        subnets=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=*private*" \
            --query 'Subnets[].SubnetId' --output text \
            | tr '\t' ',') \
            || die "Could not find private subnets in VPC $vpc_id."

        echo "    Task def:  $task_def"
        echo "    SG:        $sg_id"
        echo "    Subnets:   $subnets"

        local run_output
        run_output=$(AWS_PAGER="" aws ecs run-task \
            --cluster "$ecs_cluster" \
            --task-definition "$task_def" \
            --launch-type FARGATE \
            --enable-execute-command \
            --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg_id],assignPublicIp=DISABLED}") \
            || die "aws ecs run-task failed."

        local failures
        failures=$(echo "$run_output" | jq -r '.failures | length')
        [[ "$failures" == "0" ]] \
            || die "run-task returned failures: $(echo "$run_output" | jq -c '.failures')"

        export task_id=$(echo "$run_output" | jq -r '.tasks[0].taskArn' | awk -F'/' '{print $NF}')
    fi

    echo "==> Waiting for task to be running..."
    aws ecs wait tasks-running --cluster "$ecs_cluster" --tasks "$task_id"

    echo "==> Waiting for execute command agent..."
    local agent_status=""
    for i in $(seq 1 30); do
        agent_status=$(aws ecs describe-tasks \
            --cluster "$ecs_cluster" --tasks "$task_id" --output json \
            | jq -r '.tasks[0].containers[] | select(.name=="bastion") | .managedAgents[] | select(.name=="ExecuteCommandAgent") | .lastStatus' 2>/dev/null || true)
        if [[ "$agent_status" == "RUNNING" ]]; then
            break
        fi
        sleep 2
    done
    [[ "$agent_status" == "RUNNING" ]] \
        || die "Execute command agent did not become ready (status: ${agent_status:-unknown})"
}

# CI image installs the plugin in ci/Containerfile; local dev should use `make check-session-manager-plugin`.
require_session_manager_plugin() {
    if command -v session-manager-plugin >/dev/null 2>&1; then
        return 0
    fi
    local dir
    for dir in /usr/local/sessionmanagerplugin/bin /usr/bin /usr/local/bin; do
        if [[ -n "${dir}" && -x "${dir}/session-manager-plugin" ]]; then
            export PATH="${dir}:${PATH}"
            return 0
        fi
    done
    die "session-manager-plugin not found (required for SSM port-forward; see ci/Containerfile or https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)"
}

# Register cleanup_fn as the EXIT handler and chain the previously-registered trap.
chain_exit_trap() {
    local fn="$1"
    _chain_exit_prev=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    trap "${fn}; eval \"\$_chain_exit_prev\"" EXIT
}

# PIDs and ECS context set by bastion_port_forward (read by bastion_port_forward_cleanup).
BASTION_PF_SSM_PID=""
BASTION_PF_BASTION_PIDS=()

# Stop SSM/kubectl port-forwards and stop the bastion task only when this caller launched it.
bastion_port_forward_cleanup() {
    if [[ -n "${BASTION_PF_SSM_PID}" ]]; then
        kill "${BASTION_PF_SSM_PID}" 2>/dev/null || true
        wait "${BASTION_PF_SSM_PID}" 2>/dev/null || true
        BASTION_PF_SSM_PID=""
    fi
    local pid
    for pid in "${BASTION_PF_BASTION_PIDS[@]}"; do
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done
    BASTION_PF_BASTION_PIDS=()

    if [[ -n "${ecs_cluster:-}" && -n "${task_id:-}" ]]; then
        aws ecs execute-command --cluster "${ecs_cluster}" --task "${task_id}" --container bastion \
            --interactive --command "pkill -f 'kubectl.port-forward' || true" &>/dev/null || true
        if [[ "${bastion_task_owned:-false}" == "true" ]]; then
            aws ecs stop-task --cluster "${ecs_cluster}" --task "${task_id}" &>/dev/null || true
            bastion_task_owned=false
        fi
    fi
}

# Bastion kubectl port-forward + SSM tunnel to localhost.
# Args: cluster_id k8s_namespace k8s_service k8s_service_port remote_port local_port
bastion_port_forward() {
    local cluster_id="$1" k8s_ns="$2" k8s_svc="$3" k8s_svc_port="$4" remote_port="$5" local_port="$6"

    require_session_manager_plugin

    BASTION_PF_SSM_PID=""
    BASTION_PF_BASTION_PIDS=()

    bastion_run_task "${cluster_id}"

    local runtime_id target
    runtime_id=$(aws ecs describe-tasks --cluster "${ecs_cluster}" --tasks "${task_id}" \
        --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' --output text)
    if [[ -z "${runtime_id}" || "${runtime_id}" == "None" ]]; then
        die "runtime_id not found for bastion task ${task_id} in cluster ${ecs_cluster}"
    fi
    target="ecs:${ecs_cluster}_${task_id}_${runtime_id}"

    echo "==> Cleaning up stale port-forwards on bastion..."
    aws ecs execute-command --cluster "${ecs_cluster}" --task "${task_id}" --container bastion \
        --interactive --command "pkill -f 'kubectl.port-forward' || true" &>/dev/null || true
    sleep 2

    echo "==> [bastion] kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns}"
    aws ecs execute-command --cluster "${ecs_cluster}" --task "${task_id}" --container bastion \
        --interactive \
        --command "kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns} --address 0.0.0.0" &
    BASTION_PF_BASTION_PIDS+=($!)

    echo "==> Waiting for kubectl port-forward to be ready..."
    sleep 5

    echo "==> [local] SSM forwarding localhost:${local_port} -> bastion:${remote_port}"
    aws ssm start-session \
        --target "${target}" \
        --document-name AWS-StartPortForwardingSession \
        --parameters "{\"portNumber\":[\"${remote_port}\"],\"localPortNumber\":[\"${local_port}\"]}" &
    BASTION_PF_SSM_PID=$!
}
