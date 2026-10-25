#!/usr/bin/env bash
#
# Ephemeral environment CLI for ROSA Seaplane.
#
# Manages ephemeral developer environments in shared dev AWS accounts.
# Wraps the ephemeral provider (ci/ephemeral-provider/) with credential
# fetching, container execution, and local state tracking.
#
# Typically invoked via Makefile targets (make ephemeral-provision, etc.)
# but can be run directly: ./ci/ephemeral-env.sh provision --branch my-feature
#
# See docs/development-environment.md for full usage guide.

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}"
CI_IMAGE="rosa-regional-ci"
ENVS_FILE=".ephemeral-envs"

GITHUB_TOKEN_SECRET="/ephemeral-provider/github-token"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env-common.sh"

# =============================================================================
# Helpers
# =============================================================================

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  provision       Provision an ephemeral environment"
    echo "  provision-resume Resume a failed provisioning run"
    echo "  teardown        Tear down an ephemeral environment"
    echo "  resync          Resync an ephemeral environment to your branch"
    echo "  swap-branch     Swap an ephemeral environment to a different branch"
    echo "  list            List ephemeral environments"
    echo "  shell           Interactive shell for Platform API access"
    echo "  bastion         Connect to RC/MC bastion in an ephemeral env"
    echo "  post-account    Register a customer AWS account with the RC platform API"
    echo "  port-forward    Forward ports through RC/MC bastion in an ephemeral env"
    echo "  sre-ui          Tunnel SRE UI tools through the internal ALB via bastion"
    echo "  e2e             Run e2e tests against an ephemeral env"
    echo "  zoa-e2e         Run rosa-seaplane-zoa's deep e2e suite against an ephemeral env"
    echo "  dump-env        Dump EKS must-gather and DB state from RC/MC in an ephemeral env"
}

usage_bastion_interactive() {
    echo "Usage: $0 bastion --cluster-type [value]"
    echo ""
    echo "Connect to RC/MC bastion in an ephemeral environment"
    echo ""
    echo "Flags:"
    echo "  --cluster-type  Defines which cluster type to connect to. Accepted values are \"regional\" or \"management\""
}

usage_port_forward() {
    echo "Usage: $0 port-forward --cluster-type [value] <additional flags>"
    echo ""
    echo "Opens Port Forwards to the various services that are running on a cluster in the ephemeral env"
    echo ""
    echo "Flags:"
    echo "  --all           Automatically open all port forwards to the various services"
    echo "  --cluster-type  Defines which cluster type to connect to. Accepted values are \"regional\" or \"management\""
}

# Extract a KEY=VALUE field from an .ephemeral-envs line.
# Uses a space prefix to match exact keys (e.g. BRANCH vs EPH_BRANCH).
get_field() {
    echo "$1" | sed -n "s/.* ${2}=\([^ ]*\).*/\1/p"
}

# Update the STATE field for a BUILD_ID in .ephemeral-envs.
update_state() {
    local id="$1" new_state="$2"
    grep -v "^${id} " "$ENVS_FILE" > "${ENVS_FILE}.tmp" || true
    grep "^${id} " "$ENVS_FILE" \
        | sed "s/STATE=[^ ]*/STATE=${new_state}/" >> "${ENVS_FILE}.tmp"
    mv "${ENVS_FILE}.tmp" "$ENVS_FILE"
}

# Append KEY=VALUE to a BUILD_ID's line in .ephemeral-envs.
append_field() {
    local id="$1" key="$2" value="$3"
    sed "s|^${id} .*|& ${key}=${value}|" "$ENVS_FILE" > "${ENVS_FILE}.tmp" \
        && mv "${ENVS_FILE}.tmp" "$ENVS_FILE"
}

# Require the outputs needed by the local ephemeral workflow before marking the
# environment ready.
validate_provision_outputs() {
    local id="$1" api_url="$2" region="$3" rhobs_api_url="$4"
    local missing=()

    [[ -n "$api_url" ]] || missing+=(API_URL)
    [[ -n "$region" ]] || missing+=(REGION)
    [[ -n "$rhobs_api_url" ]] || missing+=(RHOBS_API_URL)

    if (( ${#missing[@]} > 0 )); then
        update_state "$id" "provisioning-failed"
        echo "Fix the provisioning failure, then retry:"
        echo "  make ephemeral-provision-resume ID=$id"
        die "Provisioning completed but required outputs are missing for ID $id: ${missing[*]}"
    fi
}

# Update one or more KEY=VALUE fields (update existing or append).
# Usage: update_fields <id> KEY1=VAL1 [KEY2=VAL2 ...]
update_fields() {
    local id="$1"; shift
    cp "$ENVS_FILE" "${ENVS_FILE}.tmp"
    for pair in "$@"; do
        local key="${pair%%=*}" value="${pair#*=}"
        if grep "^${id} " "${ENVS_FILE}.tmp" | grep -q " ${key}="; then
            sed -i.bak "/^${id} /s| ${key}=[^ ]*| ${key}=${value}|" "${ENVS_FILE}.tmp"
        else
            sed -i.bak "s|^${id} .*|& ${key}=${value}|" "${ENVS_FILE}.tmp"
        fi
    done
    rm -f "${ENVS_FILE}.tmp.bak"
    mv "${ENVS_FILE}.tmp" "$ENVS_FILE"
}

# Persist a successful provision as one metadata update. STATE=ready is only
# written together with the outputs that were validated by the provider.
record_ready_environment() {
    local id="$1" region="$2" api_url="$3" rhobs_api_url="$4"
    local zoa_rc_api_url="$5" zoa_mc_api_url="$6" eph_branch="$7"
    local fields=("STATE=ready")

    [[ -z "$region" ]] || fields+=("REGION=$region")
    [[ -z "$api_url" ]] || fields+=("API_URL=$api_url")
    [[ -z "$rhobs_api_url" ]] || fields+=("RHOBS_API_URL=$rhobs_api_url")
    [[ -z "$zoa_rc_api_url" ]] || fields+=("ZOA_RC_API_URL=$zoa_rc_api_url")
    [[ -z "$zoa_mc_api_url" ]] || fields+=("ZOA_MC_API_URL=$zoa_mc_api_url")
    fields+=("EPH_BRANCH=$eph_branch")

    if ! update_fields "$id" "${fields[@]}"; then
        update_state "$id" "provisioning-failed" || true
        die "Unable to persist successful provisioning metadata for ID $id"
    fi
}

# Derive the ephemeral branch name from an env ID and branch name.
# Must match the Python logic in ci/ephemeral-provider/git.py and main.py.
derive_eph_branch() {
    local env_id="$1" branch="$2"
    echo "eph-${env_id}-$(echo "$branch" | tr '/' '-')-ci"
}

# Interactive fzf picker for remote + branch.
# Sets globals: PICKED_REPO, PICKED_BRANCH
pick_remote_branch() {
    local prompt="${1:-Select branch:}"

    local remote
    remote=$(git remote -v | grep '(fetch)' \
        | awk '{printf "%-15s %s\n", $1, $2}' \
        | fzf --height=10 --header="Select remote:" \
        | awk '{print $1}') \
        || { echo "Aborted."; exit 1; }

    PICKED_REPO=$(git remote get-url "$remote" | sed 's|.*github\.com[:/]||; s|\.git$||')
    echo "Fetching branches from $remote ($PICKED_REPO)..."

    PICKED_BRANCH=$(git ls-remote --heads "$remote" 2>/dev/null \
        | sed 's|.*refs/heads/||' \
        | fzf --height=20 --header="$prompt") \
        || { echo "Aborted."; exit 1; }
}

# Select an environment by explicit ID or interactive fzf picker.
# Sets global: BUILD_ID, ENV_LINE
#   $1 = grep pattern to filter candidates
#   $2 = fzf header text
#   $3 = "no match" message
#   $4 = bool - auto select the only result if this is true
select_env() {
    local state_filter="$1" header="$2" no_match_msg="$3" auto_select_single=${4:-false}

    if [[ -n "${ID:-}" ]]; then
        BUILD_ID="$ID"
    else
        command -v fzf >/dev/null 2>&1 \
            || die "fzf is required for interactive selection. Install fzf or pass ID=<id> directly."
        [[ -f "$ENVS_FILE" && -s "$ENVS_FILE" ]] \
            || die "No environments found in $ENVS_FILE."

        local candidates
        candidates=$(grep -E "$state_filter" "$ENVS_FILE" || true)
        [[ -n "$candidates" ]] || die "$no_match_msg"

        local selected
        local candidate_count=$(wc -l <<< "$candidates")

        if [ $auto_select_single == true ] && [ $candidate_count -eq 1 ]; then
            selected="$candidates"
            BUILD_ID=$(echo "$selected" | awk '{print $1}')
            echo "Only one ready environment found. Defaulting to: $BUILD_ID"
        else
            selected=$(echo "$candidates" | fzf --height=20 --header="$header") \
                || { echo "Aborted."; exit 1; }
            BUILD_ID=$(echo "$selected" | awk '{print $1}')
        fi
    fi

    ENV_LINE=$(grep "^${BUILD_ID} " "$ENVS_FILE" 2>/dev/null) \
        || die "ID $BUILD_ID not found in $ENVS_FILE."
}

fzf_pick() {
  local header="$1"
  shift
  printf '%s\n' "$@" | fzf --multi --height=10 --layout=reverse --header="$header" --no-info
}

# Check if .ephemeral-env/ override directory exists.
# Sets global: OVERRIDE_MOUNT (container flags), OVERRIDE_INFO (display string)
setup_override_mount() {
    OVERRIDE_MOUNT=""
    OVERRIDE_INFO="(default)"
    if [[ -d "${REPO_ROOT}/.ephemeral-env" ]]; then
        OVERRIDE_MOUNT="-v ${REPO_ROOT}/.ephemeral-env:/overrides:ro,z -e EPHEMERAL_OVERRIDE_DIR=/overrides"
        OVERRIDE_INFO=".ephemeral-env/"
    fi
}

# Fetch GitHub token from SSM Parameter Store (unless already set).
# Requires rrp-ephemeral-central profile to be available.
fetch_github_token() {
    SEAPLANE_CI_GITHUB_TOKEN="${SEAPLANE_CI_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -z "${SEAPLANE_CI_GITHUB_TOKEN:-}" ]]; then
        echo "Fetching GitHub token from SSM Parameter Store..."
        local ssm_err
        ssm_err=$(mktemp)
        SEAPLANE_CI_GITHUB_TOKEN=$(aws ssm get-parameter \
            --name "$GITHUB_TOKEN_SECRET" \
            --with-decryption \
            --profile rrp-ephemeral-central \
            --query Parameter.Value --output text 2>"$ssm_err") \
            || die "Failed to fetch GitHub token from SSM.
$(cat "$ssm_err")"
        rm -f "$ssm_err"
    fi
    export SEAPLANE_CI_GITHUB_TOKEN
}

# Create temporary AWS config with ephemeral profiles.
setup_aws_config() {
    if [[ -n "${RRP_AWS_PROFILES_PRESET:-}" ]]; then
        echo "Using pre-existing AWS credentials (RRP_AWS_PROFILES_PRESET)"
        export AWS_CONFIG_FILE=${AWS_CONFIG_FILE:-$HOME/.aws/config}
        return 0
    fi

    local accounts_file="${RRP_ACCOUNTS_DEV:-${REPO_ROOT}/../rosa-seaplane-internal/infra/accounts/dev/accounts.json}"
    [[ -f "$accounts_file" ]] \
        || die "Account IDs file not found: $accounts_file
    Either clone rosa-seaplane-internal as a sibling directory,
    or set RRP_ACCOUNTS_DEV to point to your accounts JSON file.
    See docs/development-environment.md for details."
    load_accounts "$accounts_file" admin central rc mc customer

    init_aws_config

    cat > "$AWS_CONFIG_FILE" <<AWSCFG
[profile rrp-ephemeral-admin]
credential_process = uv run ${SCRIPT_DIR}/cached_saml_credentials_process.py ${ADMIN_ACCOUNT} ${ADMIN_ACCOUNT}-rrp-admin
region = us-east-1
duration_seconds = 3600

[profile rrp-ephemeral-central]
role_arn = arn:aws:iam::${CENTRAL_ACCOUNT}:role/OrganizationAccountAccessRole
source_profile = rrp-ephemeral-admin
region = us-east-1
duration_seconds = 3600

[profile rrp-ephemeral-rc]
role_arn = arn:aws:iam::${RC_ACCOUNT}:role/OrganizationAccountAccessRole
source_profile = rrp-ephemeral-admin
region = us-east-1
duration_seconds = 3600

[profile rrp-ephemeral-mc]
role_arn = arn:aws:iam::${MC_ACCOUNT}:role/OrganizationAccountAccessRole
source_profile = rrp-ephemeral-admin
region = us-east-1
duration_seconds = 3600

[profile rrp-ephemeral-customer]
role_arn = arn:aws:iam::${CUSTOMER_ACCOUNT}:role/OrganizationAccountAccessRole
source_profile = rrp-ephemeral-admin
region = us-east-1
duration_seconds = 3600
AWSCFG

    echo "AWS config written to: $AWS_CONFIG_FILE"
}

# Resolve ephemeral profiles to static container credentials.
write_eph_container_config() {
    # If profiles are preset, mount the whole .aws dir — config, cred-helper,
    # and real_credentials all need to be present at the same absolute paths.
    if [[ -n "${RRP_AWS_PROFILES_PRESET:-}" ]]; then
        _CONTAINER_AWS_FLAGS="-v ${HOME}/.aws:/home/agent/.aws:ro,z -e AWS_CONFIG_FILE=/home/agent/.aws/config"
        # Pass through TLS env vars if set in the caller's environment
        for _var in AWS_CA_BUNDLE REQUESTS_CA_BUNDLE SSL_CERT_FILE UV_NATIVE_TLS; do
            [[ -n "${!_var:-}" ]] && _CONTAINER_AWS_FLAGS="${_CONTAINER_AWS_FLAGS} -e ${_var}=${!_var}"
        done
        return 0
    fi

    write_container_config \
        "rrp-ephemeral-central rrp-central us-east-1" \
        "rrp-ephemeral-rc rrp-rc us-east-1" \
        "rrp-ephemeral-mc rrp-mc us-east-1" \
        "rrp-ephemeral-customer rrp-customer us-east-1"
}

profile_for() {
    case "$1" in
        regional)   echo "rrp-ephemeral-rc" ;;
        management) echo "rrp-ephemeral-mc" ;;
        *)          die "Unknown cluster type: $1" ;;
    esac
}

# Initial bastion connectivity and setup
bastion_setup() {
    local cluster_type="${1:-}"

    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment for bastion access:" \
        "No ready environments found." \
        true

    local region
    region=$(get_field "$ENV_LINE" REGION)
    [[ -n "$region" ]] \
        || die "No REGION found for ID $BUILD_ID. Was it captured during provision?"

    # Compute eph_prefix from BUILD_ID (must match ci/ephemeral-provider/main.py)
    local eph_prefix="eph-${BUILD_ID}"

    # Derive cluster ID and ECS resource names from eph_prefix
    if [[ "$cluster_type" == "regional" ]]; then
        cluster_id="${eph_prefix}-regional"
    else
        cluster_id="${eph_prefix}-mc01"
    fi
    export ecs_cluster="${cluster_id}-bastion"

    setup_aws_config

    local profile
    profile=$(profile_for "$cluster_type")
    export AWS_PROFILE="$profile"
    export AWS_DEFAULT_REGION="$region"
    export AWS_REGION="$region"

    echo "Connecting to ephemeral bastion..."
    echo "  ID:           $BUILD_ID"
    echo "  Eph prefix:   $eph_prefix"
    echo "  Cluster type: $cluster_type"
    echo "  Cluster ID:   $cluster_id"
    echo "  Region:       $region"
    echo ""

    bastion_run_task "$cluster_id"
}


# Check that required CLI tools are available.
preflight() {
    local missing=""
    local required_tools="jq uv aws git python3"
    if [[ -z "${RRP_AWS_PROFILES_PRESET:-}" ]]; then
        required_tools="fzf $required_tools"
    fi
    for tool in $required_tools; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    [[ -n "$CONTAINER_ENGINE" ]] || missing="$missing podman/docker"
    [[ -z "$missing" ]] || die "Missing required tools:$missing"
}

# =============================================================================
# Commands
# =============================================================================

cmd_provision() {
    local command_start=$SECONDS
    local repo="${REPO:-openshift-online/rosa-seaplane}"
    local branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

    # Generate an ID if not provided
    if [[ -z "${ID:-}" ]]; then
        ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
    fi

    # Interactive remote + branch picker (when BRANCH not explicitly set)
    if [[ -z "${BRANCH:-}" ]] && command -v fzf >/dev/null 2>&1; then
        echo "Current branch: $branch"
        echo "Select a remote to pick a branch from (or Esc to abort):"
        pick_remote_branch "Select branch:"
        repo="$PICKED_REPO"
        branch="$PICKED_BRANCH"
        echo "Selected branch: $branch (from $repo)"
    fi

    # Check for local config overrides
    setup_override_mount

    # Fetch credentials and write container config
    setup_aws_config
    fetch_github_token
    write_eph_container_config

    # Print summary
    echo "Provisioning ephemeral environment..."
    echo "  ID:                $ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  ENV CONFIG:        $OVERRIDE_INFO"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"

    # Record initial state
    echo "$ID REPO=$repo BRANCH=$branch STATE=provisioning CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$ENVS_FILE"

    # Run the ephemeral provider
    local tmpdir artifacts_dir
    tmpdir=$(mktemp -d)
    artifacts_dir="${ARTIFACTS_DIR:-${ARTIFACT_DIR:-${REPO_ROOT}/.ephemeral-artifacts/${ID}}}"
    mkdir -p "$artifacts_dir"
    _prev_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    trap 'rm -rf "${tmpdir:-}"; eval "$_prev_trap"' EXIT

    echo "  ARTIFACTS_DIR:     $artifacts_dir"

    local rc=0
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $_CONTAINER_AWS_FLAGS \
        -e "SEAPLANE_CI_GITHUB_TOKEN=$SEAPLANE_CI_GITHUB_TOKEN" \
        $OVERRIDE_MOUNT \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -v "${tmpdir}:/output:z" \
        -v "${artifacts_dir}:/artifacts:z" \
        -w /workspace \
        -e WORKSPACE_DIR=/workspace \
        -e ARTIFACT_DIR=/artifacts \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --id "$ID" \
            --repo "$repo" --branch "$branch" \
            --save-regional-state /output/tf-outputs.json \
            --save-management-state /output/tf-outputs-mc.json \
    || rc=$?

    local command_elapsed=$((SECONDS - command_start))
    echo "Total provisioning command duration: $((command_elapsed / 60))m $((command_elapsed % 60))s"

    # Record results
    if [[ $rc -eq 0 ]]; then
        local api_url="" region=""
        if [[ -f "$tmpdir/tf-outputs.json" ]] && command -v jq >/dev/null 2>&1; then
            api_url=$(jq -r '.api_gateway_invoke_url.value // empty' "$tmpdir/tf-outputs.json" 2>/dev/null || true)
        fi
        if [[ -f "$tmpdir/region" ]]; then
            region=$(cat "$tmpdir/region")
        fi

        local rhobs_api_url=""
        if [[ -f "$tmpdir/tf-outputs.json" ]]; then
            rhobs_api_url=$(jq -r '.rhobs_api_url.value // empty' "$tmpdir/tf-outputs.json" 2>/dev/null || true)
        fi

        local zoa_rc_api_url="" zoa_mc_api_url=""
        if [[ -f "$tmpdir/tf-outputs.json" ]]; then
            zoa_rc_api_url=$(jq -r '.zoa_api_function_url.value // empty' "$tmpdir/tf-outputs.json" 2>/dev/null || true)
        fi
        if [[ -f "$tmpdir/tf-outputs-mc.json" ]]; then
            zoa_mc_api_url=$(jq -r '.zoa_api_function_url.value // empty' "$tmpdir/tf-outputs-mc.json" 2>/dev/null || true)
        fi
        validate_provision_outputs \
            "$ID" "$api_url" "$region" "$rhobs_api_url"

        # Store ephemeral branch name so it survives branch swaps
        record_ready_environment \
            "$ID" "$region" "$api_url" "$rhobs_api_url" \
            "$zoa_rc_api_url" "$zoa_mc_api_url" \
            "$(derive_eph_branch "$ID" "$branch")"

        echo ""
        echo "Environment recorded in $ENVS_FILE."
        [[ -z "$api_url" ]] || echo -e "\n  API Gateway:  $api_url"
        [[ -z "$zoa_rc_api_url" ]] || echo -e "  ZOA API (RC): $zoa_rc_api_url"
        [[ -z "$zoa_mc_api_url" ]] || echo -e "  ZOA API (MC): $zoa_mc_api_url"
        echo ""
        echo "  To interact with the API:"
        echo "    make ephemeral-shell ID=$ID"
        echo ""
        echo "  To run e2e tests:"
        echo "    make ephemeral-e2e ID=$ID"
        echo ""
        echo "  To tear down:"
        echo "    make ephemeral-teardown ID=$ID"
    else
        update_state "$ID" "provisioning-failed"
        echo "Provisioning failed. State updated to provisioning-failed."
        echo "CodeBuild logs (if captured): $artifacts_dir"
        echo "Fix the failure, then retry:"
        echo "  make ephemeral-provision-resume ID=$ID"
        exit $rc
    fi
}

cmd_provision_resume() {
    local command_start=$SECONDS
    select_env "STATE=provisioning-failed" \
        "Select failed environment to resume:" \
        "No failed provisioning environments found."

    local repo branch eph_branch
    repo=$(get_field "$ENV_LINE" REPO)
    branch=$(get_field "$ENV_LINE" BRANCH)
    eph_branch=$(get_field "$ENV_LINE" EPH_BRANCH)
    local state
    state=$(get_field "$ENV_LINE" STATE)

    [[ "$state" == "provisioning-failed" ]] \
        || die "Environment $BUILD_ID is in state '$state'; only provisioning-failed environments can be resumed."
    [[ -n "$repo" ]] || die "Environment $BUILD_ID has no REPO field."
    [[ -n "$branch" ]] || die "Environment $BUILD_ID has no BRANCH field."
    [[ -n "$eph_branch" ]] || eph_branch=$(derive_eph_branch "$BUILD_ID" "$branch")

    setup_override_mount
    setup_aws_config
    fetch_github_token
    write_eph_container_config

    echo "Resuming ephemeral environment provisioning..."
    echo "  ID:                $BUILD_ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  EPH_BRANCH:        $eph_branch"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"

    local tmpdir artifacts_dir
    tmpdir=$(mktemp -d)
    artifacts_dir="${ARTIFACTS_DIR:-${ARTIFACT_DIR:-${REPO_ROOT}/.ephemeral-artifacts/${BUILD_ID}}}"
    mkdir -p "$artifacts_dir"
    _prev_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    trap 'rm -rf "${tmpdir:-}"; eval "$_prev_trap"' EXIT

    echo "  ARTIFACTS_DIR:     $artifacts_dir"

    local rc=0
    local resync_arg=()
    case "${RESYNC:-true}" in
        true|1|yes|TRUE|YES)
            resync_arg=(--resync-before-resume)
            ;;
        false|0|no|FALSE|NO)
            ;;
        *)
            die "RESYNC must be true or false (got: ${RESYNC})"
            ;;
    esac

    update_state "$BUILD_ID" "provisioning"

    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $_CONTAINER_AWS_FLAGS \
        -e "SEAPLANE_CI_GITHUB_TOKEN=$SEAPLANE_CI_GITHUB_TOKEN" \
        $OVERRIDE_MOUNT \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -v "${tmpdir}:/output:z" \
        -v "${artifacts_dir}:/artifacts:z" \
        -w /workspace \
        -e WORKSPACE_DIR=/workspace \
        -e ARTIFACT_DIR=/artifacts \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --resume \
            ${resync_arg[@]+"${resync_arg[@]}"} \
            --id "$BUILD_ID" \
            --repo "$repo" --branch "$branch" \
            --eph-branch "$eph_branch" \
            --save-regional-state /output/tf-outputs.json \
            --save-management-state /output/tf-outputs-mc.json \
    || rc=$?

    local command_elapsed=$((SECONDS - command_start))
    echo "Total provisioning-resume command duration: $((command_elapsed / 60))m $((command_elapsed % 60))s"

    if [[ $rc -eq 0 ]]; then
        local api_url="" region=""
        if [[ -f "$tmpdir/tf-outputs.json" ]] && command -v jq >/dev/null 2>&1; then
            api_url=$(jq -r '.api_gateway_invoke_url.value // empty' "$tmpdir/tf-outputs.json" 2>/dev/null || true)
        fi
        if [[ -f "$tmpdir/region" ]]; then
            region=$(cat "$tmpdir/region")
        fi

        local rhobs_api_url=""
        if [[ -f "$tmpdir/tf-outputs.json" ]]; then
            rhobs_api_url=$(jq -r '.rhobs_api_url.value // empty' "$tmpdir/tf-outputs.json" 2>/dev/null || true)
        fi

        local zoa_rc_api_url="" zoa_mc_api_url=""
        if [[ -f "$tmpdir/tf-outputs.json" ]]; then
            zoa_rc_api_url=$(jq -r '.zoa_api_function_url.value // empty' "$tmpdir/tf-outputs.json" 2>/dev/null || true)
        fi
        if [[ -f "$tmpdir/tf-outputs-mc.json" ]]; then
            zoa_mc_api_url=$(jq -r '.zoa_api_function_url.value // empty' "$tmpdir/tf-outputs-mc.json" 2>/dev/null || true)
        fi
        validate_provision_outputs \
            "$BUILD_ID" "$api_url" "$region" "$rhobs_api_url"

        record_ready_environment \
            "$BUILD_ID" "$region" "$api_url" "$rhobs_api_url" \
            "$zoa_rc_api_url" "$zoa_mc_api_url" "$eph_branch"
        echo "Environment $BUILD_ID provisioning resumed successfully."
    else
        update_state "$BUILD_ID" "provisioning-failed"
        echo "Resume failed. State updated to provisioning-failed."
        echo "CodeBuild logs (if captured): $artifacts_dir"
        echo "Fix the failure, then retry:"
        echo "  make ephemeral-provision-resume ID=$BUILD_ID"
        exit $rc
    fi
}

cmd_teardown() {
    local with_resync=false
    [[ "${RESYNC:-}" == "1" ]] && with_resync=true

    # Select environment
    select_env "STATE=(provisioning|ready|provisioning-failed|deprovisioning|deprovisioning-failed)" \
        "Select environment to tear down:" \
        "No active environments found."

    local repo branch region eph_branch
    repo=$(get_field "$ENV_LINE" REPO)
    branch=$(get_field "$ENV_LINE" BRANCH)
    region=$(get_field "$ENV_LINE" REGION)
    eph_branch=$(get_field "$ENV_LINE" EPH_BRANCH)

    setup_override_mount

    # Fetch credentials and write container config
    setup_aws_config
    fetch_github_token
    write_eph_container_config

    # Build --eph-branch flag if available (needed after swap-branch)
    local eph_branch_flag=""
    [[ -z "$eph_branch" ]] || eph_branch_flag="--eph-branch $eph_branch"

    local with_resync_flag=""
    [[ "$with_resync" == "true" ]] && with_resync_flag="--resync"

    # Set up artifacts directory for CodeBuild logs
    local artifacts_dir
    artifacts_dir="${ARTIFACTS_DIR:-${ARTIFACT_DIR:-${REPO_ROOT}/.ephemeral-artifacts/${BUILD_ID}}}"
    mkdir -p "$artifacts_dir"

    # Print summary
    echo "Tearing down ephemeral environment..."
    echo "  ID:                $BUILD_ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  RESYNC:            $with_resync"
    if [[ "$with_resync" == "true" ]]; then
        echo "  ENV CONFIG:        $OVERRIDE_INFO"
    fi
    echo "  REGION:            $region"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"
    echo "  ARTIFACTS_DIR:     $artifacts_dir"

    # Run teardown
    update_state "$BUILD_ID" "deprovisioning"

    local rc=0
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $_CONTAINER_AWS_FLAGS \
        -e "SEAPLANE_CI_GITHUB_TOKEN=$SEAPLANE_CI_GITHUB_TOKEN" \
        $OVERRIDE_MOUNT \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -v "${artifacts_dir}:/artifacts:z" \
        -w /workspace \
        -e WORKSPACE_DIR=/workspace \
        -e ARTIFACT_DIR=/artifacts \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --teardown $with_resync_flag --id "$BUILD_ID" --repo "$repo" --branch "$branch" \
            $eph_branch_flag \
    || rc=$?

    # Update state
    if [[ $rc -eq 0 ]]; then
        update_state "$BUILD_ID" "deprovisioned"
        echo "Environment $BUILD_ID deprovisioned."
    else
        update_state "$BUILD_ID" "deprovisioning-failed"
        echo "Teardown failed. State updated to deprovisioning-failed."
        exit $rc
    fi
}

cmd_resync() {
    # Select environment
    select_env "STATE=(provisioning|ready|provisioning-failed|deprovisioning|deprovisioning-failed)" \
        "Select environment to resync:" \
        "No active environments found."

    local repo branch eph_branch
    repo=$(get_field "$ENV_LINE" REPO)
    branch=$(get_field "$ENV_LINE" BRANCH)
    eph_branch=$(get_field "$ENV_LINE" EPH_BRANCH)

    # Check for local config overrides
    setup_override_mount

    # Fetch credentials and write container config
    setup_aws_config
    fetch_github_token
    write_eph_container_config

    # Build --eph-branch flag if available (needed after swap-branch)
    local eph_branch_flag=""
    [[ -z "$eph_branch" ]] || eph_branch_flag="--eph-branch $eph_branch"

    # Set up artifacts directory for CodeBuild logs
    local artifacts_dir
    artifacts_dir="${ARTIFACTS_DIR:-${ARTIFACT_DIR:-${REPO_ROOT}/.ephemeral-artifacts/${BUILD_ID}}}"
    mkdir -p "$artifacts_dir"

    # Print summary
    echo "Resyncing ephemeral environment..."
    echo "  ID:                $BUILD_ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  ENV CONFIG:        $OVERRIDE_INFO"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"
    echo "  ARTIFACTS_DIR:     $artifacts_dir"

    # Run resync
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $_CONTAINER_AWS_FLAGS \
        -e "SEAPLANE_CI_GITHUB_TOKEN=$SEAPLANE_CI_GITHUB_TOKEN" \
        $OVERRIDE_MOUNT \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -v "${artifacts_dir}:/artifacts:z" \
        -w /workspace \
        -e WORKSPACE_DIR=/workspace \
        -e ARTIFACT_DIR=/artifacts \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --resync --id "$BUILD_ID" --repo "$repo" --branch "$branch" \
            $eph_branch_flag
}

cmd_swap_branch() {
    local new_branch="${NEW_BRANCH:-}"
    local new_repo="${NEW_REPO:-}"

    # Select environment
    select_env "STATE=ready" \
        "Select environment to swap branch:" \
        "No ready environments found."

    local repo branch eph_branch
    repo=$(get_field "$ENV_LINE" REPO)
    branch=$(get_field "$ENV_LINE" BRANCH)
    eph_branch=$(get_field "$ENV_LINE" EPH_BRANCH)

    # Compute EPH_BRANCH for pre-existing envs that don't have it yet
    [[ -n "$eph_branch" ]] || eph_branch=$(derive_eph_branch "$BUILD_ID" "$branch")

    # Interactive branch picker if NEW_BRANCH not set
    if [[ -z "$new_branch" ]] && command -v fzf >/dev/null 2>&1; then
        echo "Current: $branch (repo: $repo)"
        echo "Select a remote to pick a new branch from (or Esc to abort):"
        pick_remote_branch "Select branch to swap to:"
        new_repo="$PICKED_REPO"
        new_branch="$PICKED_BRANCH"
        echo "Selected: $new_branch (from $new_repo)"
    elif [[ -z "$new_branch" ]]; then
        die "NEW_BRANCH is required. Usage: make ephemeral-swap-branch NEW_BRANCH=<branch> [NEW_REPO=<owner/repo>]"
    fi

    # Default new_repo to the current repo if not specified
    [[ -n "$new_repo" ]] || new_repo="$repo"

    # Skip if already on the target branch
    if [[ "$new_repo" == "$repo" && "$new_branch" == "$branch" ]]; then
        echo "Already on $repo @ $branch. Nothing to do."
        return
    fi

    echo ""
    echo "Swapping ephemeral environment branch..."
    echo "  ID:      $BUILD_ID"
    echo "  FROM:    $repo @ $branch"
    echo "  TO:      $new_repo @ $new_branch"

    # Update .ephemeral-envs with new branch/repo and persist EPH_BRANCH (single write)
    update_fields "$BUILD_ID" "REPO=$new_repo" "BRANCH=$new_branch" "EPH_BRANCH=$eph_branch"

    # Resync to the new branch
    ID="$BUILD_ID" cmd_resync
}

cmd_list() {
    if [[ ! -f "$ENVS_FILE" || ! -s "$ENVS_FILE" ]]; then
        echo "No ephemeral environments."
        return
    fi

    echo "Ephemeral environments:"
    echo ""
    printf "%-12s %-45s %-25s %-12s %-22s %-20s %-60s %s\n" \
        "ID" "REPO" "BRANCH" "REGION" "STATE" "CREATED" "API_URL" "RHOBS_API_URL"
    echo "------------ --------------------------------------------- ------------------------- ------------ ---------------------- -------------------- ------------------------------------------------------------ ------------------------------------------------------------"

    while IFS= read -r line; do
        local build_id repo branch region state created api_url rhobs_api_url
        build_id=$(echo "$line" | awk '{print $1}')
        repo=$(get_field "$line" REPO)
        branch=$(get_field "$line" BRANCH)
        region=$(get_field "$line" REGION)
        state=$(get_field "$line" STATE)
        created=$(get_field "$line" CREATED)
        api_url=$(get_field "$line" API_URL)
        rhobs_api_url=$(get_field "$line" RHOBS_API_URL)
        printf "%-12s %-45s %-25s %-12s %-22s %-20s %-60s %s\n" \
            "$build_id" "$repo" "$branch" "$region" "$state" "$created" "$api_url" "$rhobs_api_url"
    done < "$ENVS_FILE"

    echo ""
    echo "To clear list: rm $ENVS_FILE"
}

cmd_shell() {
    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment:" \
        "No ready environments found." \
        true

    local api_url region zoa_rc_api_url zoa_mc_api_url
    api_url=$(get_field "$ENV_LINE" API_URL)
    region=$(get_field "$ENV_LINE" REGION)
    zoa_rc_api_url=$(get_field "$ENV_LINE" ZOA_RC_API_URL)
    zoa_mc_api_url=$(get_field "$ENV_LINE" ZOA_MC_API_URL)

    # Fetch credentials and write container config
    setup_aws_config
    write_eph_container_config

    # Launch interactive shell
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm -it \
        $_CONTAINER_AWS_FLAGS \
        -e "AWS_PROFILE=rrp-rc" \
        -e "AWS_DEFAULT_REGION=$region" \
        -e "AWS_REGION=$region" \
        -e "API_URL=$api_url" \
        -e "ZOA_RC_API_URL=${zoa_rc_api_url:-}" \
        -e "ZOA_MC_API_URL=${zoa_mc_api_url:-}" \
        "$CI_IMAGE" \
        bash -c '
            echo ""
            echo "ROSA Seaplane shell"
            echo ""
            echo "API Gateway: $API_URL"
            [[ -z "${ZOA_RC_API_URL:-}" ]] || echo "ZOA API (RC): $ZOA_RC_API_URL"
            [[ -z "${ZOA_MC_API_URL:-}" ]] || echo "ZOA API (MC): $ZOA_MC_API_URL"
            echo "Region:      $AWS_DEFAULT_REGION"
            echo ""
            echo "Example commands:"
            echo "  awscurl --service execute-api $API_URL/v0/live"
            exec bash'
}

cmd_bastion_interactive() {
    local cluster_type

    while [ "${1:-}" != "" ]; do
        case $1 in
            --cluster-type )        cluster_type=${2:-}
                                    shift
                                    ;;
            --help )                usage_bastion_interactive
                                    exit 0
                                    ;;
            * ) echo "Unexpected parameter $1"
                usage
                exit 1
        esac
        shift
    done

    case "$cluster_type" in
      regional|management) ;;
      *) echo "Error: invalid cluster type '$cluster_type'"; echo ""; usage_bastion_interactive; exit 1 ;;
    esac

    bastion_setup $cluster_type

    ## Leave these here so we can ensure that the variables
    ## are actually available since we refactored out the logic
    echo ""
    echo "==> Bastion task ready"
    echo "    ECS cluster: $ecs_cluster"
    echo "    Task ID:     $task_id"
    echo ""
    echo "==> Connecting to bastion..."
    echo ""

    # Connect via ECS Exec
    aws ecs execute-command \
        --cluster "$ecs_cluster" \
        --task "$task_id" \
        --container bastion \
        --interactive \
        --command '/bin/bash'
}

usage_post_account() {
    echo "Usage: make ephemeral-post-account-shell ACCOUNT_ID=<12-digit-aws-account-id> [ID=<env-id>]"
    echo ""
    echo "Register a customer AWS account with the platform API using the ephemeral shell"
    echo "container, where awscurl and API_URL are already configured."
    echo ""
    echo "Example:"
    echo "  make ephemeral-post-account-shell ACCOUNT_ID=123456789012"
}

cmd_post_account() {
    local account_id="${ACCOUNT_ID:-}"

    if [[ -z "$account_id" ]]; then
        echo "Error: ACCOUNT_ID is required"
        echo ""
        usage_post_account
        exit 1
    fi

    if [[ ! "$account_id" =~ ^[0-9]{12}$ ]]; then
        echo "Error: ACCOUNT_ID must be a 12-digit AWS account number, got: $account_id"
        exit 1
    fi

    select_env "STATE=ready" \
        "Select environment:" \
        "No ready environments found." \
        true

    local api_url region
    api_url=$(get_field "$ENV_LINE" API_URL)
    region=$(get_field "$ENV_LINE" REGION)

    setup_aws_config
    write_eph_container_config

    # account_id is validated as 12 digits so embedding it in the payload is safe.
    # awscurl does not support curl's -s/-w flags, so success/failure is detected
    # from the response body: the platform API always returns metav1.Status JSON
    # with "status":"Failure" on errors.
    local script
    script="$(cat <<SCRIPT
RESPONSE=\$(awscurl --service execute-api "\$API_URL/api/v0/accounts" \\
    -X POST \\
    -H 'Content-Type: application/json' \\
    -d '{"accountId":"${account_id}","privileged":true}')
echo "\$RESPONSE"
echo ""
if echo "\$RESPONSE" | grep -q '"status":"Failure"'; then
    REASON=\$(echo "\$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reason',''))" 2>/dev/null)
    if [ "\$REASON" = "AlreadyExists" ]; then
        echo "==> OK: account already registered"
    else
        echo "==> FAILED: \${REASON:-unknown error}"
        exit 1
    fi
else
    echo "==> SUCCESS: account registered"
fi
SCRIPT
)"

    echo "==> Registering account ${account_id}..."
    echo ""

    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm -i \
        $_CONTAINER_AWS_FLAGS \
        -e "AWS_PROFILE=rrp-rc" \
        -e "AWS_DEFAULT_REGION=$region" \
        -e "AWS_REGION=$region" \
        -e "API_URL=$api_url" \
        "$CI_IMAGE" \
        bash -c "$script"
}

cmd_bastion_port_forward() {
    local all_svcs=false
    local cluster_type

    while [ "${1:-}" != "" ]; do
    case $1 in
        --all )                 all_svcs=true
                                ;;
        --cluster-type )        cluster_type=${2:-}
                                shift
                                ;;
        --help )                usage_port_forward
                                exit 0
                                ;;
        * ) echo "Unexpected parameter $1"
            usage
            exit 1
    esac
    shift
    done

    # --- Validations ------------------------
    case "$cluster_type" in
      regional|management) ;;
      *) echo "Error: invalid cluster type '$cluster_type'"; echo ""; usage_port_forward; exit 1 ;;
    esac

    local argocd="argocd        - ArgoCD server HTTPS"
    local prometheus="prometheus    - Prometheus Monitoring Dashboard"
    local thanos="thanos        - Thanos Query + Ruler (aggregated RC+MC metrics and alerting)"
    local loki="loki          - Loki Query Frontend (platform logs)"
    local alertmanager="alertmanager  - AlertManager Web UI"
    local grafana="grafana       - Grafana Dashboard"
    local custom="custom        - Custom service / ports"

    # custom services are added only for interactive
    local regional_svc_list=("$argocd" "$prometheus" "$thanos" "$loki" "$alertmanager" "$grafana")
    local management_svc_list=("$argocd" "$prometheus")

    local services

    # If we provide the all-services flag, set all the services
    if [ $all_svcs == true ]; then
        case "$cluster_type" in
            regional )      services=$(printf '%s\n' "${regional_svc_list[@]}") ;;
            management )    services=$(printf '%s\n' "${management_svc_list[@]}") ;;
        esac
    else
        # otherwise, prompt the user
        if [ "$cluster_type" = "regional" ]; then
            services=$(fzf_pick "Select service (${cluster_type}):" "${regional_svc_list[@]}" "$custom")
        else
            services=$(fzf_pick "Select service (${cluster_type}):" "${management_svc_list[@]}" "$custom")
        fi
    fi
    services=$(awk '{print $1}' <<< "$services" | tr '\n' ' ')

    local forwards=()
    for service in $services
    do
        # ── Build port-forward definitions ───────────────────────────────────────────
        # Each entry: "label remote_port local_port k8s_svc k8s_namespace k8s_svc_port"

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
        thanos)
            forwards+=(
            "Thanos-Query 10902 10902 thanos-query-frontend-thanos-query thanos 9090"
            "Thanos-Ruler 10903 10903 thanos-ruler-thanos-ruler thanos 9090"
            )
            ;;
        loki)
            forwards+=(
            "Loki-Query 13100 13100 loki-query-frontend loki 3100"
            )
            ;;
        alertmanager)
            forwards+=(
            "AlertManager 9093 9093 monitoring-alertmanager monitoring 9093"
            )
            ;;
        grafana)
            forwards+=(
            "Grafana 3000 3000 grafana grafana 80"
            )
            ;;
        custom)
            local k8s_ns k8s_svc k8s_svc_port local_port remote_port
            echo ""
            read -rp "Kubernetes namespace: " k8s_ns
            read -rp "Service name (without svc/ prefix): " k8s_svc
            read -rp "Service port [443]: " k8s_svc_port
            k8s_svc_port="${k8s_svc_port:-443}"
            read -rp "Local port [${k8s_svc_port}]: " local_port
            local_port="${local_port:-$k8s_svc_port}"
            remote_port="$local_port"

            forwards+=(
            "Custom ${remote_port} ${local_port} ${k8s_svc} ${k8s_ns} ${k8s_svc_port}"
            )
            ;;
        *) echo "Error: unknown service '$service'"; echo ""; usage; exit 1 ;;
        esac
    done

    # ── Pre-flight: check local ports are free ───────────────────────────────────

    for entry in "${forwards[@]}"; do
        local local_port
        read -r label _ local_port _ _ _ <<< "$entry"
        if lsof -iTCP:"$local_port" -sTCP:LISTEN -t &>/dev/null; then
            echo "Error: Local port ${local_port} (${label}) is already in use."
            echo "Kill the process using it first: lsof -iTCP:${local_port} -sTCP:LISTEN"
            exit 1
        fi
    done

    # ── Connect to Bastion ──────────────────────────────────────────────────────

    bastion_setup $cluster_type

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

    # ── Port forwarding ─────────────────────────────────────────────────────────

    ssm_pids=()
    bastion_pids=()

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
    }
    chain_exit_trap cleanup

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

    # Start kubectl port-forward(s) inside the bastion (one ECS exec per forward).
    # The ECS exec session is short-lived but kubectl keeps running in the container.
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

    # Wait for kubectl to bind inside the bastion
    echo ""
    echo "==> Waiting for kubectl port-forward(s) to be ready..."
    sleep 5

    # Hop 2: SSM port forward from laptop to bastion
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
    # Use a marker prefix so we can extract the password from the SSM session noise.
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

    # Wait for any SSM session to exit — if one dies, tear everything down
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

    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment for e2e tests:" \
        "No ready environments found."

    local api_url region zoa_rc_api_url zoa_mc_api_url
    api_url=$(get_field "$ENV_LINE" API_URL)
    region=$(get_field "$ENV_LINE" REGION)
    zoa_rc_api_url=$(get_field "$ENV_LINE" ZOA_RC_API_URL)
    zoa_mc_api_url=$(get_field "$ENV_LINE" ZOA_MC_API_URL)
    [[ -n "$api_url" ]] \
        || die "No API_URL found for ID $BUILD_ID. Was it captured during provision?"
    [[ -n "$zoa_rc_api_url" ]] \
        || die "No ZOA_RC_API_URL found for ID $BUILD_ID. Was it captured during provision?"
    [[ -n "$zoa_mc_api_url" ]] \
        || die "No ZOA_MC_API_URL found for ID $BUILD_ID. Was it captured during provision?"

    # Fetch credentials and write container config
    setup_aws_config
    write_eph_container_config

    local rhobs_api_url
    rhobs_api_url=$(get_field "$ENV_LINE" RHOBS_API_URL)
    [[ -n "$rhobs_api_url" ]] \
        || die "No RHOBS_API_URL found for ID $BUILD_ID. Was it captured during provision?"

    # Run tests
    echo "Running e2e tests..."
    echo "  ID:             $BUILD_ID"
    echo "  API_URL:        $api_url"
    echo "  RHOBS_API_URL:  $rhobs_api_url"
    echo "  ZOA_RC_API_URL: $zoa_rc_api_url"
    echo "  ZOA_MC_API_URL: $zoa_mc_api_url"
    echo "  REGION:         $region"
    echo "  E2E_REF:        $e2e_ref"
    echo "  E2E_REPO:       $e2e_repo"

    $CONTAINER_ENGINE run --rm \
        $_CONTAINER_AWS_FLAGS \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -w /workspace \
        -e "CLUSTER_PREFIX=eph-${BUILD_ID}-" \
        -e "BUILD_ID=$BUILD_ID" \
        -e "BASE_URL=$api_url" \
        -e "RHOBS_API_URL=$rhobs_api_url" \
        -e "ZOA_RC_API_URL=$zoa_rc_api_url" \
        -e "ZOA_MC_API_URL=$zoa_mc_api_url" \
        -e "AWS_DEFAULT_REGION=$region" \
        -e "AWS_REGION=$region" \
        -e "E2E_REF=$e2e_ref" \
        -e "E2E_REPO=$e2e_repo" \
        -e "CLI_REF=${CLI_REF:-main}" \
        -e "CLI_REPO=${CLI_REPO:-}" \
        -e "ROSA_REPO_URL=${ROSA_REPO_URL:-}" \
        -e "ROSA_REPO_BRANCH=${ROSA_REPO_BRANCH:-}" \
        -e "ROSA_LABEL_FILTER=${ROSA_LABEL_FILTER:-}" \
        -e "ROSA_TEST_PROFILE=${ROSA_TEST_PROFILE:-}" \
        -e "E2E_SKIP_CLEANUP=${E2E_SKIP_CLEANUP:-}" \
        -e "E2E_SKIP_PLATFORM_API=${E2E_SKIP_PLATFORM_API:-}" \
        -e "E2E_SKIP_HCP=${E2E_SKIP_HCP:-}" \
        -e "E2E_SKIP_MONITORING=${E2E_SKIP_MONITORING:-}" \
        -e "E2E_SKIP_ROSA_CLI=${E2E_SKIP_ROSA_CLI:-}" \
        -e "E2E_SKIP_ZOA=${E2E_SKIP_ZOA:-}" \
        "$CI_IMAGE" \
        bash ci/e2e-tests.sh
}

# Runs rosa-seaplane-zoa e2e tests against an already-provisioned ephemeral
# env's ZOA Lambda URLs. Clones ZOA_REPO@ZOA_REF inside the container and runs
# `make $ZOA_MAKE_TARGET` (default: test-e2e; set to test-e2e-smoke for smoke).
# Same clone-by-ref pattern cmd_e2e uses for rosa-seaplane-api. To test a
# branch/fork, push it and set ZOA_REF/ZOA_REPO.
cmd_zoa_e2e() {
    local zoa_ref="${ZOA_REF:-main}"
    local zoa_repo="${ZOA_REPO:-https://github.com/openshift-online/rosa-seaplane-zoa.git}"

    select_env "STATE=ready" \
        "Select environment for ZOA e2e tests:" \
        "No ready environments found."

    local zoa_rc_api_url zoa_mc_api_url region rhobs_api_url
    zoa_rc_api_url=$(get_field "$ENV_LINE" ZOA_RC_API_URL)
    zoa_mc_api_url=$(get_field "$ENV_LINE" ZOA_MC_API_URL)
    region=$(get_field "$ENV_LINE" REGION)
    rhobs_api_url=$(get_field "$ENV_LINE" RHOBS_API_URL)
    [[ -n "$zoa_rc_api_url" ]] \
        || die "No ZOA_RC_API_URL found for ID $BUILD_ID. Was it captured during provision?"
    [[ -n "$zoa_mc_api_url" ]] \
        || die "No ZOA_MC_API_URL found for ID $BUILD_ID. Was it captured during provision?"
    [[ -n "$rhobs_api_url" ]] \
        || die "No RHOBS_API_URL found for ID $BUILD_ID. Was it captured during provision?"

    setup_aws_config
    write_eph_container_config

    echo "Running zoa e2e suite..."
    echo "  ID:             $BUILD_ID"
    echo "  ZOA_RC_API_URL: $zoa_rc_api_url"
    echo "  ZOA_MC_API_URL: $zoa_mc_api_url"
    echo "  RHOBS_API_URL:  $rhobs_api_url"
    echo "  REGION:         $region"
    echo "  ZOA_REF:        $zoa_ref"
    echo "  ZOA_REPO:       $zoa_repo"

    $CONTAINER_ENGINE run --rm \
        $_CONTAINER_AWS_FLAGS \
        -e "ZOA_RC_API_URL=$zoa_rc_api_url" \
        -e "ZOA_MC_API_URL=$zoa_mc_api_url" \
        -e "RHOBS_API_URL=$rhobs_api_url" \
        -e "AWS_DEFAULT_REGION=$region" \
        -e "AWS_REGION=$region" \
        -e "ZOA_MAKE_TARGET=${ZOA_MAKE_TARGET:-test-e2e}" \
        -e "GINKGO_FLAGS=${GINKGO_FLAGS:-}" \
        "$CI_IMAGE" \
        bash -c 'git clone --depth 1 --branch "'"${zoa_ref}"'" "'"${zoa_repo}"'" /tmp/zoa-e2e && cd /tmp/zoa-e2e && make ${ZOA_MAKE_TARGET} GINKGO_FLAGS="${GINKGO_FLAGS:-}"'
}

cmd_dump_env() {
    local cluster_type="${1:-all}"
    # Accept short aliases
    case "$cluster_type" in
        rc) cluster_type="regional" ;;
        mc) cluster_type="management" ;;
    esac
    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment for dump-env:" \
        "No ready environments found." \
        true

    setup_aws_config
    write_eph_container_config

    local region
    region=$(get_field "$ENV_LINE" REGION)

    local eph_prefix
    eph_prefix="eph-${BUILD_ID}-"

    # dump-env.sh runs on the host (not in a container) but needs
    # the standardized profile names (rrp-rc, rrp-mc). Point it at the resolved
    # container config which has those profiles with static credentials.
    export AWS_CONFIG_FILE="$_CONTAINER_CONFIG"
    export AWS_SHARED_CREDENTIALS_FILE=/dev/null
    export AWS_REGION="$region"
    export CLUSTER_PREFIX="$eph_prefix"
    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
        export LOG_OUTPUT_DIR="$ARTIFACT_DIR"
    fi

    "${REPO_ROOT}/scripts/dev/dump-env.sh" "$cluster_type"
}

# =============================================================================
# Main
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Commands that don't need preflight or container image
case "${1:-help}" in
    list) cmd_list; exit 0 ;;
esac

cmd_sre_tunnel() {
    local local_port=4443

    bastion_setup "regional"

    local runtime_id
    runtime_id=$(aws ecs describe-tasks \
        --cluster "$ecs_cluster" \
        --tasks "$task_id" \
        --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' \
        --output text)
    [[ -n "$runtime_id" && "$runtime_id" != "None" ]] \
        || die "runtime_id not found for task '$task_id' in cluster '$ecs_cluster'"

    local target="ecs:${ecs_cluster}_${task_id}_${runtime_id}"

    # Retrieve ALB DNS and SRE domain from the in-cluster secret via bastion
    echo "==> Fetching SRE gateway info from cluster..."
    local raw
    raw=$(aws ecs execute-command \
        --cluster "$ecs_cluster" \
        --task "$task_id" \
        --container bastion \
        --interactive \
        --command "sh -c \"echo SRE_ALB=\$(kubectl get secret local-cluster-identity -n argocd -o jsonpath='{.metadata.annotations.sre_alb_dns_name}'); echo SRE_DOMAIN=\$(kubectl get secret local-cluster-identity -n argocd -o jsonpath='{.metadata.annotations.sre_domain}')\"" 2>/dev/null || true)

    local alb_dns sre_domain
    alb_dns=$(echo "$raw" | grep -o 'SRE_ALB=.*' | cut -d= -f2 | tr -d '[:space:]')
    sre_domain=$(echo "$raw" | grep -o 'SRE_DOMAIN=.*' | cut -d= -f2 | tr -d '[:space:]')

    [[ -n "$alb_dns" ]] || die "Could not retrieve SRE ALB DNS. Is the SRE gateway deployed?"
    [[ -n "$sre_domain" ]] || die "Could not retrieve SRE domain."

    cleanup() {
        echo ""; echo "Closing SRE UI tunnel..."
        kill "$ssm_pid" 2>/dev/null || true
    }
    chain_exit_trap cleanup

    echo "==> [local] SSM tunnel localhost:${local_port} -> ${alb_dns}:443"
    aws ssm start-session \
        --target "$target" \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "{\"host\":[\"${alb_dns}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"${local_port}\"]}" &
    ssm_pid=$!
    sleep 3

    echo ""
    echo "==> SRE UI tunnel active"
    echo ""
    echo "Add these lines to /etc/hosts (requires sudo):"
    for tool in grafana argocd prometheus thanos loki; do
        printf "    127.0.0.1  %s.%s\n" "$tool" "$sre_domain"
    done
    echo ""
    echo "Then open (note: port ${local_port}, not 443):"
    for tool in grafana argocd prometheus thanos loki; do
        printf "    https://%s.%s:%s\n" "$tool" "$sre_domain" "$local_port"
    done
    echo ""
    echo "Press Ctrl+C to close the tunnel."
    wait "$ssm_pid"
}

case "${1:-help}" in
    bastion|dump-env|sre-ui)
        for tool in jq uv aws; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
    port-forward)
        for tool in jq uv aws fzf lsof; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
    shell|e2e|zoa-e2e|post-account)
        preflight
        ensure_image
        ;;
    *)
        # provision, provision-resume, teardown, resync
        preflight
        ensure_image
        ;;
esac

case "${1:-help}" in
    provision)      cmd_provision ;;
    provision-resume) cmd_provision_resume ;;
    teardown)       cmd_teardown ;;
    resync)         cmd_resync ;;
    swap-branch)    cmd_swap_branch ;;
    shell)          cmd_shell ;;
    bastion)        shift; cmd_bastion_interactive "$@" ;;
    post-account)   cmd_post_account ;;
    port-forward)   shift; cmd_bastion_port_forward "$@" ;;
    sre-ui)         cmd_sre_tunnel ;;
    e2e)            cmd_e2e ;;
    zoa-e2e)        cmd_zoa_e2e ;;
    dump-env)       shift; cmd_dump_env "$@" ;;
    help|*)
        usage
        ;;
esac
