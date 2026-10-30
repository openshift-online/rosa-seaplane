#!/usr/bin/env bash
# lib.sh — Shared utilities for pipeline buildspec scripts.
#
# Source once at the top of each buildspec script:
#   source scripts/pipeline-common/lib.sh
#
# Functions:
#   preflight_check          Validate required env vars, init credentials
#   config_load <mode>       Load deploy config (regional|management)
#   parseBool <filter> [default] <file>
#   init_account_helpers     Capture CodeBuild ambient credentials
#   use_mc_account           Switch to MC/target account
#   use_rc_account           Switch to RC account
#   use_central_account      Restore central account credentials
#   get_rc_account_id        Return resolved RC account ID
#   get_central_ssm_parameter Read /infra/* SSM from the central (pipeline) account
#   resolve_management_cluster_account_id  MC account_id from deploy JSON → 12-digit ID
#   build_management_clusters_tf_var       management_clusters_info JSON → TF_VAR string
#   terraform_init_backend   Init terraform with S3 backend
#   bootstrap_argocd         Run ArgoCD bootstrap via ECS task
#   import_if_needed         Idempotent terraform import
#   tf_state_value           Read attribute from terraform state
#   tf_import_summary        Print import summary, fail if errors

set -euo pipefail

# ── Internal state ───────────────────────────────────────────────────────────

_CENTRAL_AWS_ACCESS_KEY_ID=""
_CENTRAL_AWS_SECRET_ACCESS_KEY=""
_CENTRAL_AWS_SESSION_TOKEN=""
_RESOLVED_RC_ACCOUNT_ID=""

# Shared API live endpoint. Override through the build environment when the
# route changes; both RC and MC readiness checks use this value.
export PLATFORM_API_LIVE_PATH="${PLATFORM_API_LIVE_PATH:-/api/v0/live}"

# ── Validation ───────────────────────────────────────────────────────────────

# Validate required pipeline env vars, derive CLUSTER_ID, and init credentials.
preflight_check() {
    CLUSTER_ID="${REGIONAL_ID:-${MANAGEMENT_ID:-}}"

    if [[ -z "${TARGET_ACCOUNT_ID:-}" || -z "${TARGET_REGION:-}" || -z "${CLUSTER_ID:-}" ]]; then
        echo "ERROR: Required environment variables not set" >&2
        echo "  TARGET_ACCOUNT_ID=${TARGET_ACCOUNT_ID:-<not set>}" >&2
        echo "  TARGET_REGION=${TARGET_REGION:-<not set>}" >&2
        echo "  REGIONAL_ID=${REGIONAL_ID:-<not set>}" >&2
        echo "  MANAGEMENT_ID=${MANAGEMENT_ID:-<not set>}" >&2
        exit 1
    fi

    init_account_helpers
}

# Require non-empty runtime variables before Terraform is invoked. Terraform
# defaults are useful for optional settings, but must not hide missing pipeline
# identity, repository, or image inputs.
require_nonempty_vars() {
    local context="$1"
    shift
    local missing=()
    local name

    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            missing+=("$name")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required ${context} variables: ${missing[*]}" >&2
        return 1
    fi
}

validate_aws_account_id() {
    local label="$1"
    local account_id="$2"

    if [[ ! "$account_id" =~ ^[0-9]{12}$ ]]; then
        echo "ERROR: ${label} must be a 12-digit AWS account ID, got '${account_id}'" >&2
        return 1
    fi
}

validate_arn_account() {
    local label="$1"
    local arn="$2"
    local account_id="$3"

    if [[ ! "$arn" =~ ^arn:[^:]*:[^:]*:[^:]*:${account_id}: ]]; then
        echo "ERROR: ${label} is not an ARN in AWS account ${account_id}: '${arn}'" >&2
        return 1
    fi
}

# Print a safe, source-labelled summary of the values that control a
# provisioning step. Callers pass triples: name, source, value.
print_provision_param_summary() {
    local context="$1"
    shift

    echo "${context} parameter summary:"
    while [[ $# -gt 0 ]]; do
        local name="$1"
        local source="$2"
        local value="$3"
        shift 3

        case "$name" in
            *SECRET*|*TOKEN*|*PASSWORD*|*PRIVATE_KEY*|*ACCESS_KEY*|*API_KEY*|*ENCRYPTION_KEY*|*SIGNING_KEY*) value="<redacted>" ;;
        esac
        [[ -n "$value" ]] || value="<empty>"
        printf '  %-36s %-12s %s\n' "$name" "$source" "$value"
    done
}

# ── AWS Credentials ──────────────────────────────────────────────────────────

# Capture CodeBuild's ambient credentials. Call once at pipeline start.
init_account_helpers() {
    _CENTRAL_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    _CENTRAL_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    _CENTRAL_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

    export CENTRAL_ACCOUNT_ID
    CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
}

# Assume OrganizationAccountAccessRole in TARGET_ACCOUNT_ID.
use_mc_account() {
    _assume_account "${TARGET_ACCOUNT_ID}" "mc-${CLUSTER_ID:-pipeline}"
}

# Assume OrganizationAccountAccessRole in REGIONAL_AWS_ACCOUNT_ID (SSM-aware).
use_rc_account() {
    _resolve_rc_account
    _assume_account "$_RESOLVED_RC_ACCOUNT_ID" "rc-${CLUSTER_ID:-pipeline}"
}

# Restore central (CodeBuild) credentials.
use_central_account() {
    export AWS_ACCESS_KEY_ID="$_CENTRAL_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$_CENTRAL_AWS_SECRET_ACCESS_KEY"
    export AWS_SESSION_TOKEN="$_CENTRAL_AWS_SESSION_TOKEN"
}

# Return resolved RC account ID (resolves SSM on first call).
get_rc_account_id() {
    _resolve_rc_account
    echo "$_RESOLVED_RC_ACCOUNT_ID"
}

# Read SSM from the central CodeBuild account. /infra/* params live there, not in RC/MC.
get_central_ssm_parameter() {
    local param_name="$1"
    local region="${2:-${TARGET_REGION}}"
    AWS_ACCESS_KEY_ID="$_CENTRAL_AWS_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$_CENTRAL_AWS_SECRET_ACCESS_KEY" \
        AWS_SESSION_TOKEN="$_CENTRAL_AWS_SESSION_TOKEN" \
        aws ssm get-parameter \
            --name "$param_name" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${region}"
}

# Resolve a whole-field SSM reference using central credentials. The registry
# account parameter is in us-east-1; callers may pass a different SSM region.
resolve_central_ssm_value() {
    local value="$1"
    local region="${2:-${TARGET_REGION}}"
    if [[ "$value" == ssm://* ]]; then
        get_central_ssm_parameter "${value#ssm://}" "$region"
    else
        echo "$value"
    fi
}

_resolve_rc_account() {
    if [ -n "$_RESOLVED_RC_ACCOUNT_ID" ]; then
        return
    fi

    _RESOLVED_RC_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

    if [[ "$_RESOLVED_RC_ACCOUNT_ID" =~ ^ssm:// ]]; then
        local ssm_param="${_RESOLVED_RC_ACCOUNT_ID#ssm://}"
        _RESOLVED_RC_ACCOUNT_ID=$(get_central_ssm_parameter "$ssm_param")
    fi
}

# ── management_clusters (RC Terraform) ───────────────────────────────────────
#
# Terraform always uses the same variable: management_clusters = "mc01:123456789012,..."
# (see TF_VAR_management_clusters in provision-infra-rc.sh).
#
# Only the *source* of each MC AWS account ID in deploy JSON differs by environment:
#
#   Static (integration, stage, production, …):
#     render.py leaves account_id as ssm:///infra/<env>/<region>/<mc>/account_id
#     in pipeline-regional-cluster-inputs/terraform.json. Values live in the
#     central pipeline account; provision-infra-rc.sh resolves before assume-role
#     (get_central_ssm_parameter also works after assume into RC).
#
#   Ephemeral:
#     ci/ephemeral-provider (or local dev) injects literal 12-digit account IDs
#     into config before render. deploy JSON must not contain ssm:// for MC
#     account_id (guard below).
#
# resolve_management_cluster_account_id: one deploy "account_id" field → digits or empty.

resolve_management_cluster_account_id() {
    local raw_account_id="$1"

    if [[ -z "$raw_account_id" ]]; then
        echo ""
        return 0
    fi

    if [[ "${ENVIRONMENT:-}" == "ephemeral" && "$raw_account_id" =~ ^ssm:// ]]; then
        echo "ERROR: ephemeral RC deploy must use literal MC account_id in management_clusters_info" >&2
        echo "  (re-render after ephemeral provider sets aws.management_cluster_account_id from STS)" >&2
        exit 1
    fi

    if [[ "$raw_account_id" =~ ^ssm:// ]]; then
        local ssm_param="${raw_account_id#ssm://}"
        get_central_ssm_parameter "$ssm_param"
        return 0
    fi

    echo "$raw_account_id"
}

# build_management_clusters_tf_var: deploy JSON path → "id:account,id:account" for Terraform.

build_management_clusters_tf_var() {
    local deploy_config_file="$1"
    local mc_info
    mc_info=$(jq -c '.management_clusters_info // []' "$deploy_config_file")

    if [[ "$mc_info" == "[]" ]]; then
        echo ""
        return 0
    fi

    local parts=()
    local entry id acct resolved
    for entry in $(echo "$mc_info" | jq -r '.[] | @base64'); do
        id=$(echo "$entry" | base64 -d | jq -r '.id // empty')
        acct=$(echo "$entry" | base64 -d | jq -r '.account_id // empty')
        resolved=$(resolve_management_cluster_account_id "$acct") || return 1
        if [[ -z "$id" || ! "$resolved" =~ ^[0-9]{12}$ ]]; then
            echo "ERROR: Invalid management cluster id/account: '${id}:${resolved}'" >&2
            return 1
        fi
        parts+=("${id}:${resolved}")
    done

    local mc_info_len
    mc_info_len=$(echo "$mc_info" | jq 'length')
    if [[ "$mc_info_len" -gt 0 && ${#parts[@]} -eq 0 ]]; then
        echo "ERROR: management_clusters_info lists ${mc_info_len} cluster(s) but none resolved to id:account_id" >&2
        echo "  static envs: check central SSM /infra/${ENVIRONMENT:-<env>}/<region>/<mc>/account_id" >&2
        echo "  ephemeral: use literal account_id in deploy JSON (provider inject + render)" >&2
        exit 1
    fi

    local IFS=,
    echo "${parts[*]}"
}

_assume_account() {
    local account_id="$1"
    local session_name="$2"

    if [ "$account_id" = "$CENTRAL_ACCOUNT_ID" ]; then
        use_central_account
        return
    fi

    # hop 2: assume the child admin role for infra apply / argocd bootstrap.
    # Role name is configurable per environment (set as a CodeBuild env var by
    # the pipeline TF); defaults to the AWS Organizations role.
    local role_arn="arn:aws:iam::${account_id}:role/${CHILD_ADMIN_ROLE_NAME:-OrganizationAccountAccessRole}"
    local creds
    if ! creds=$(
        AWS_ACCESS_KEY_ID="$_CENTRAL_AWS_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$_CENTRAL_AWS_SECRET_ACCESS_KEY" \
        AWS_SESSION_TOKEN="$_CENTRAL_AWS_SESSION_TOKEN" \
        aws sts assume-role \
            --role-arn "$role_arn" \
            --role-session-name "$session_name" \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
            --output text 2>&1); then
        echo "ERROR: Failed to assume role $role_arn: $creds" >&2
        return 1
    fi

    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    AWS_ACCESS_KEY_ID=$(echo "$creds" | awk '{print $1}')
    AWS_SECRET_ACCESS_KEY=$(echo "$creds" | awk '{print $2}')
    AWS_SESSION_TOKEN=$(echo "$creds" | awk '{print $3}')

    local assumed_account
    assumed_account=$(aws sts get-caller-identity --query Account --output text)
    if [ "$assumed_account" != "$account_id" ]; then
        echo "ERROR: Assumed wrong account. Expected $account_id, got $assumed_account" >&2
        return 1
    fi
}

# ── Configuration ────────────────────────────────────────────────────────────

# Parse a boolean field from a JSON file. Returns "true" or "false".
# Usage: parseBool '.field' [default] file.json
parseBool() {
    local _filter="$1" _default="${2:-false}" _file="$3"
    local _raw
    _raw=$(jq -r "if $_filter == null then \"__null__\" else $_filter end" "$_file") || return $?
    case "$_raw" in
        true|1)  echo "true" ;;
        false|0) echo "false" ;;
        __null__) echo "$_default" ;;
        *)
            echo "ERROR: parseBool: expected boolean for '$_filter' in $_file, got '$_raw'" >&2
            exit 9
            ;;
    esac
}

# Resolve a rendered cluster config path (render.py writes codebuild-* dirs).
config_path_for_mode() {
    local mode="$1"

    if [[ "$mode" == "regional" ]]; then
        echo "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json"
    elif [[ "$mode" == "management" ]]; then
        echo "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-management-cluster-${MANAGEMENT_ID}-inputs/terraform.json"
    else
        echo "ERROR: config_path_for_mode: unknown mode '$mode'" >&2
        return 1
    fi
}

provisioner_config_path() {
    echo "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-provisioner-inputs/terraform.json"
}

# Load terraform variables from deploy/ JSON config files.
# Usage: config_load regional   OR   config_load management
# Exports: DEPLOY_CONFIG_FILE, APP_CODE, SERVICE_PHASE, COST_CENTER,
#          ENABLE_BASTION, ENVIRONMENT_DOMAIN
# Management mode also exports: CLUSTER_ID, REGIONAL_AWS_ACCOUNT_ID
config_load() {
    local mode="$1"

    ENVIRONMENT="${ENVIRONMENT:-staging}"

    DEPLOY_CONFIG_FILE=$(config_path_for_mode "$mode")

    if [ ! -f "$DEPLOY_CONFIG_FILE" ]; then
        echo "ERROR: Deploy config not found: $DEPLOY_CONFIG_FILE" >&2
        exit 1
    fi

    APP_CODE=$(jq -r '.app_code // "infra"' "$DEPLOY_CONFIG_FILE")
    SERVICE_PHASE=$(jq -r '.service_phase // "dev"' "$DEPLOY_CONFIG_FILE")
    COST_CENTER=$(jq -r '.cost_center // "000"' "$DEPLOY_CONFIG_FILE")
    ENABLE_BASTION=$(parseBool '.enable_bastion' false "$DEPLOY_CONFIG_FILE")

    local env_json
    env_json=$(provisioner_config_path)
    if [ -f "$env_json" ]; then
        ENVIRONMENT_DOMAIN=$(jq -r '.domain // empty' "$env_json")
    else
        ENVIRONMENT_DOMAIN=""
    fi

    if [[ "$mode" == "management" ]]; then
        CLUSTER_ID=$(jq -r '.management_id // ""' "$DEPLOY_CONFIG_FILE")
        if [[ -z "$CLUSTER_ID" ]]; then
            CLUSTER_ID="${MANAGEMENT_ID}"
        fi
        REGIONAL_AWS_ACCOUNT_ID=$(jq -r '.regional_aws_account_id // ""' "$DEPLOY_CONFIG_FILE")

        if [[ "$REGIONAL_AWS_ACCOUNT_ID" =~ ^ssm:// ]]; then
            local ssm_param="${REGIONAL_AWS_ACCOUNT_ID#ssm://}"
            REGIONAL_AWS_ACCOUNT_ID=$(aws ssm get-parameter \
                --name "$ssm_param" \
                --with-decryption \
                --query 'Parameter.Value' \
                --output text \
                --region "${TARGET_REGION}")
        fi

        if [[ -z "$REGIONAL_AWS_ACCOUNT_ID" ]]; then
            echo "ERROR: regional_aws_account_id must be provided in $DEPLOY_CONFIG_FILE" >&2
            exit 1
        fi

        export CLUSTER_ID REGIONAL_AWS_ACCOUNT_ID
    fi

    export DEPLOY_CONFIG_FILE APP_CODE SERVICE_PHASE COST_CENTER ENABLE_BASTION ENVIRONMENT_DOMAIN
}

# ── Terraform ────────────────────────────────────────────────────────────────

# Init terraform with S3 backend in the current account.
# Usage: terraform_init_backend <cluster-type> <region> <cluster-id>
# cluster-type: regional-cluster or management-cluster
terraform_init_backend() {
    local cluster_type="$1"
    local region="$2"
    local cluster_id="$3"

    local target_account_id
    target_account_id=$(aws sts get-caller-identity --query Account --output text)
    local bucket="terraform-state-${target_account_id}-${region}"
    local key="${cluster_type}/${cluster_id}.tfstate"

    export TF_VAR_region="${region}"

    (
        cd "terraform/config/${cluster_type}"
        terraform init -reconfigure \
            -backend-config="bucket=${bucket}" \
            -backend-config="key=${key}" \
            -backend-config="region=${region}" \
            -backend-config="use_lockfile=true"
    )

    (
        cd "terraform/config/${cluster_type}"
        if ! terraform output -json > /tmp/tf-outputs.json 2>&1; then
            echo "ERROR: Failed to read terraform outputs" >&2
            cat /tmp/tf-outputs.json >&2
            exit 1
        fi
        if [ "$(jq 'length' /tmp/tf-outputs.json)" -eq 0 ]; then
            echo "ERROR: No terraform outputs found — terraform apply may not have run." >&2
            exit 1
        fi
    )
}

# Run ArgoCD bootstrap via ECS task.
# Usage: bootstrap_argocd <cluster-type> <target-account-id>
bootstrap_argocd() {
    local cluster_type="$1"
    local target_account_id="$2"

    if [[ "$cluster_type" != "regional-cluster" && "$cluster_type" != "management-cluster" ]]; then
        echo "ERROR: cluster-type must be 'regional-cluster' or 'management-cluster'" >&2
        exit 1
    fi

    ENVIRONMENT="${ENVIRONMENT:-${TARGET_ENVIRONMENT:-}}"
    if [[ -z "${ENVIRONMENT:-}" ]]; then
        echo "ERROR: ENVIRONMENT variable not set" >&2
        exit 1
    fi

    export ENVIRONMENT
    export REGION_DEPLOYMENT="${TARGET_REGION}"
    export AWS_REGION="${TARGET_REGION}"

    set +e
    ./scripts/bootstrap-argocd.sh "$cluster_type" 2>&1 | tee /tmp/bootstrap.log
    local exit_code=${PIPESTATUS[0]}
    set -e

    if [ $exit_code -ne 0 ]; then
        echo "ERROR: ArgoCD bootstrap failed (exit $exit_code). Log:" >&2
        cat /tmp/bootstrap.log >&2
        exit 1
    fi
}

# ── Terraform Import ─────────────────────────────────────────────────────────

_TF_IMPORT_COUNT=0
_TF_IMPORT_SKIPPED=0
_TF_IMPORT_NOT_FOUND=0
_TF_IMPORT_FAILED=0

_TF_IMPORT_NOT_FOUND_PATTERNS=(
    "ResourceNotFoundException"
    "does not exist"
    "NoSuchEntity"
    "NotFoundException"
    "404"
    "Cannot import non-existent"
)

# Idempotently import an AWS resource into Terraform state.
# Usage: import_if_needed <terraform-address> <aws-resource-id>
import_if_needed() {
    local ADDR="$1"
    local ID="$2"

    if terraform state show "$ADDR" &>/dev/null; then
        echo "  [skip] $ADDR"
        ((_TF_IMPORT_SKIPPED++)) || true
        return 0
    fi

    local IMPORT_STDERR
    IMPORT_STDERR=$(mktemp)
    if terraform import "$ADDR" "$ID" 2>"$IMPORT_STDERR"; then
        echo "  [imported] $ADDR <- $ID"
        ((_TF_IMPORT_COUNT++)) || true
        rm -f "$IMPORT_STDERR"
        return 0
    fi

    local ERR_MSG
    ERR_MSG=$(cat "$IMPORT_STDERR")
    rm -f "$IMPORT_STDERR"

    for pattern in "${_TF_IMPORT_NOT_FOUND_PATTERNS[@]}"; do
        if [[ "$ERR_MSG" == *"$pattern"* ]]; then
            echo "  [not-found] $ADDR"
            ((_TF_IMPORT_NOT_FOUND++)) || true
            return 0
        fi
    done

    echo "  [FAILED] $ADDR <- $ID" >&2
    echo "    Error: $ERR_MSG" >&2
    ((_TF_IMPORT_FAILED++)) || true
    return 1
}

# Extract a resource attribute from Terraform state.
# Usage: tf_state_value <terraform-address> <jq-path>
# Example: BROKER_ID=$(tf_state_value 'module.foo.aws_bar.baz' '.values.id')
tf_state_value() {
    local ADDR="$1"
    local JQ_EXPR="$2"
    local ATTR="${JQ_EXPR#.values.}"

    terraform state pull 2>/dev/null | jq -r --arg addr "$ADDR" --arg attr "$ATTR" '
        [.resources[] |
         select(
           ((if .module then .module + "." else "" end) + .type + "." + .name) == $addr
         )
        ] | first | .instances[0].attributes[$attr] // empty
    ' 2>/dev/null || true
}

# Print import summary. Exits non-zero if any imports failed.
tf_import_summary() {
    echo "Import summary: imported=${_TF_IMPORT_COUNT} skipped=${_TF_IMPORT_SKIPPED} not-found=${_TF_IMPORT_NOT_FOUND} failed=${_TF_IMPORT_FAILED}"
    if [ "${_TF_IMPORT_FAILED}" -gt 0 ]; then
        echo "ERROR: ${_TF_IMPORT_FAILED} import(s) failed — aborting before apply" >&2
        exit 1
    fi
}
