#!/bin/bash
set -euo pipefail

# =============================================================================
# Bootstrap Central AWS Account
# =============================================================================
# This script bootstraps the central AWS account with:
# 1. Terraform state infrastructure (S3 bucket with lockfile-based locking)
# 2. Regional cluster CodeBuild infrastructure
# 3. Management cluster CodeBuild infrastructure
#
# Prerequisites:
# - AWS CLI configured with central account credentials
# - Terraform >= 1.14.3 installed
# - GitHub repository set up
#
# Usage:
#   GITHUB_REPOSITORY=owner/repo GITHUB_BRANCH=main ./bootstrap-central-account.sh
#
#   Or with command-line arguments:
#   ./bootstrap-central-account.sh owner/repo main staging
# =============================================================================

# Show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [GITHUB_REPOSITORY] [GITHUB_BRANCH] [ENVIRONMENT]

Bootstrap the central AWS account with CodeBuild infrastructure.

ARGUMENTS:
    GITHUB_REPOSITORY    GitHub repository in owner/name format (default: 'openshift-online/rosa-seaplane')
    GITHUB_BRANCH        Branch name (default: 'main')
    ENVIRONMENT          Environment to monitor (e.g., integration, staging, production) (default: 'staging')

OPTIONS:
    -h, --help          Show this help message

ENVIRONMENT VARIABLES:
    GITHUB_REPOSITORY   GitHub repository in owner/name format (e.g., 'openshift-online/rosa-seaplane')
    GITHUB_BRANCH       Git branch to track (default: main)
    TARGET_ENVIRONMENT  Environment to monitor (default: staging)
    AWS_REGION          AWS region to deploy to. Priority: 1) Source config filename (config/<env>/<region>.yaml),
                        2) this env var, 3) AWS CLI config, 4) us-east-1. Region is extracted from the
                        config filename stem (e.g., us-east-1.yaml -> us-east-1). Only use this env var
                        for bootstrapping before any config files exist.
    ENABLE_SLACK_NOTIFICATIONS  Enable CodeBuild failure notifications to Slack (true|false).
                             Opt-in: defaults to false. Set to true to enable.
    ENABLE_CODEPIPELINE_PUSH_TRIGGERS  Enable RC/MC source push triggers (true|false; default true).
    SLACK_WEBHOOK_SSM_PARAM  SSM Parameter Store path containing Slack webhook URL (only used when
                             notifications are enabled). Default: /rosa-regional/slack/webhook-url
    AWS_PROFILE         AWS CLI profile to use

EXAMPLES:
    # With environment variables (recommended)
    GITHUB_REPOSITORY=openshift-online/rosa-seaplane GITHUB_BRANCH=bugfix-environment TARGET_ENVIRONMENT=brian $0

    # With command-line arguments
    $0 custom-org/rosa-seaplane feature-branch staging

    # Using defaults (openshift-online/rosa-seaplane, main, staging)
    $0
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            # First positional argument found, stop parsing flags
            break
            ;;
    esac
done

# Determine repo root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "ROSA Seaplane - Central Account Bootstrap"
echo "======================================================"
echo ""
echo "Repository Root: $REPO_ROOT"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI not found. Please install AWS CLI."
    exit 1
fi

if ! command -v terraform &> /dev/null; then
    echo "ERROR: Terraform not found. Please install Terraform >= 1.14.3"
    exit 1
fi

# Get current AWS identity (capture once to avoid duplicate calls)
echo "Checking AWS credentials..."
if ! AWS_IDENTITY=$(aws sts get-caller-identity --no-cli-pager 2>&1); then
    echo "ERROR: Failed to authenticate with AWS"
    echo "$AWS_IDENTITY"
    exit 1
fi

ACCOUNT_ID=$(echo "$AWS_IDENTITY" | jq -r '.Account')

if [[ -z "$ACCOUNT_ID" || ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "ERROR: Invalid AWS account ID: '$ACCOUNT_ID'"
    exit 1
fi

echo "Authenticated as:"
echo "$AWS_IDENTITY"
echo ""

# Parse command-line arguments or use environment variables (no interactive prompts)
if [ $# -ge 1 ]; then
    # Command-line arguments provided
    GITHUB_REPOSITORY="$1"
    GITHUB_BRANCH="${2:-main}"
    TARGET_ENVIRONMENT="${3:-}"
fi

# Set defaults for optional parameters
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-openshift-online/rosa-seaplane}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
TARGET_ENVIRONMENT="${TARGET_ENVIRONMENT:-staging}"

# Determine region from source config files (true source of truth)
# Priority: 1) Source config filename (config/<env>/<region>.yaml), 2) AWS_REGION env var, 3) AWS CLI config
# Region is encoded in the config filename stem (e.g., config/stage/us-east-1.yaml -> us-east-1)
REGION=""
REGION_FILES=($(find "config/${TARGET_ENVIRONMENT}" -maxdepth 1 -type f -name "*.yaml" ! -name "defaults.yaml" 2>/dev/null | sort))
REGION_COUNT=${#REGION_FILES[@]}

if [ "$REGION_COUNT" -eq 0 ]; then
    echo "ERROR: No region config files found in config/${TARGET_ENVIRONMENT}/" >&2
    echo "   Expected: config/${TARGET_ENVIRONMENT}/<region>.yaml" >&2
    exit 1
elif [ "$REGION_COUNT" -gt 1 ]; then
    echo "WARNING: Multiple region configs found in config/${TARGET_ENVIRONMENT}/:" >&2
    printf '  %s\n' "${REGION_FILES[@]}" | sed 's|^|   - |' >&2
    echo "   Using first: $(basename "${REGION_FILES[0]}" .yaml)" >&2
fi

# Extract region from the first config filename
REGION=$(basename "${REGION_FILES[0]}" .yaml)

# Allow AWS_REGION or AWS CLI config to override if explicitly set
configured_region=$(aws configure get region 2>/dev/null || true)
REGION="${AWS_REGION:-${configured_region:-$REGION}}"

if [ -z "$REGION" ]; then
    echo "ERROR: Could not determine AWS region" >&2
    echo "   Set AWS_REGION env var or configure 'aws configure set region <region>'" >&2
    exit 1
fi

# Validate: all rendered CodeBuild configs should use the same region
# This prevents CodeBuild projects from being scattered across different regions
if [ -d "deploy/${TARGET_ENVIRONMENT}" ]; then
    echo "Validating CodeBuild project regions for consistency..."
    MISMATCHED_REGIONS=()
    while IFS= read -r json_file; do
        CONFIG_REGION=$(jq -r '.region // empty' "$json_file" 2>/dev/null)
        if [ -n "$CONFIG_REGION" ] && [ "$CONFIG_REGION" != "$REGION" ]; then
            MISMATCHED_REGIONS+=("$json_file: expected $REGION, got $CONFIG_REGION")
        fi
    done < <(find "deploy/${TARGET_ENVIRONMENT}" -type f -name "*.json" -path "*/pipeline-*-inputs/*" 2>/dev/null)

    if [ ${#MISMATCHED_REGIONS[@]} -gt 0 ]; then
        echo "ERROR: CodeBuild project region mismatch detected!" >&2
        echo "Expected region: $REGION (from config/${TARGET_ENVIRONMENT}/<region>.yaml)" >&2
        echo "" >&2
        echo "Mismatched files:" >&2
        printf '  %s\n' "${MISMATCHED_REGIONS[@]}" >&2
        echo "" >&2
        echo "Run 'uv run scripts/render.py' to regenerate deploy/ files from config/ source" >&2
        exit 1
    fi
    echo "All CodeBuild project configs use region: $REGION"
fi

NAME_PREFIX="${NAME_PREFIX:-}"
SLACK_WEBHOOK_SSM_PARAM="${SLACK_WEBHOOK_SSM_PARAM:-/rosa-regional/slack/webhook-url}"

# Resolve the rendered deployment targets before granting the build roles any
# cross-account access. SSM references use the central account credentials and
# the same region as the cluster lifecycle provisioner.
read_cluster_iam_descriptor() {
    local config_file="$1" id_field="$2"
    local descriptor target_account_id

    if ! descriptor=$(jq -ce --arg id_field "$id_field" --arg region "$REGION" '
        select(.region == $region)
        | {project_name: .[$id_field], account_id, child_admin_role_name}
        | select(
            (.project_name | type == "string") and
            (.project_name | test("^[a-z0-9][a-z0-9-]*$")) and
            (.account_id | type == "string") and (.account_id | length > 0) and
            (.child_admin_role_name | type == "string") and
            (.child_admin_role_name | test("^[A-Za-z0-9_+=,.@-]+(/[A-Za-z0-9_+=,.@-]+)*$"))
        )' "$config_file"); then
        echo "ERROR: Invalid or missing rendered cluster IAM configuration: $config_file" >&2
        return 1
    fi

    target_account_id=$(jq -r '.account_id' <<<"$descriptor")
    if [[ "$target_account_id" == ssm://* ]]; then
        if ! target_account_id=$(aws ssm get-parameter \
            --name "${target_account_id#ssm://}" \
            --with-decryption --query 'Parameter.Value' --output text \
            --region "$REGION" --no-cli-pager); then
            echo "ERROR: Could not resolve target account for $config_file" >&2
            return 1
        fi
    fi
    if [[ ! "$target_account_id" =~ ^[0-9]{12}$ ]]; then
        echo "ERROR: Target account must resolve to a 12-digit ID: $config_file" >&2
        return 1
    fi

    jq -c --arg account_id "$target_account_id" '.account_id = $account_id' <<<"$descriptor"
}

RESOURCE_CONFIG_DIR="${REPO_ROOT}/deploy/${TARGET_ENVIRONMENT}/${REGION}/pipeline-provisioner-inputs"
REGIONAL_CLUSTER=$(read_cluster_iam_descriptor "${RESOURCE_CONFIG_DIR}/regional-cluster.json" regional_id)
MANAGEMENT_CLUSTERS='[]'
for cluster_config in "${RESOURCE_CONFIG_DIR}"/management-cluster-*.json; do
    [[ -f "$cluster_config" ]] || continue
    cluster_descriptor=$(read_cluster_iam_descriptor "$cluster_config" management_id)
    MANAGEMENT_CLUSTERS=$(jq -cn \
        --argjson clusters "$MANAGEMENT_CLUSTERS" --argjson cluster "$cluster_descriptor" \
        '$clusters + [$cluster]')
done

# Validate repository format (must be owner/name)
if [[ ! "$GITHUB_REPOSITORY" =~ ^[^/]+/[^/]+$ ]]; then
    echo "ERROR: GITHUB_REPOSITORY must be in 'owner/name' format"
    echo "   Example: openshift-online/rosa-seaplane"
    exit 1
fi

# Determine whether Slack notifications should be enabled.
# Explicit feature flag, opt-in: notifications are disabled unless
# ENABLE_SLACK_NOTIFICATIONS=true is set.
ENABLE_SLACK_NOTIFICATIONS="${ENABLE_SLACK_NOTIFICATIONS:-false}"

# Normalize and validate the flag
ENABLE_SLACK_NOTIFICATIONS=$(printf '%s' "$ENABLE_SLACK_NOTIFICATIONS" | tr '[:upper:]' '[:lower:]')
if [[ "$ENABLE_SLACK_NOTIFICATIONS" != "true" && "$ENABLE_SLACK_NOTIFICATIONS" != "false" ]]; then
    echo "ERROR: ENABLE_SLACK_NOTIFICATIONS must be 'true' or 'false' (got: '$ENABLE_SLACK_NOTIFICATIONS')"
    exit 1
fi
SLACK_NOTIFICATIONS_ENABLED="$ENABLE_SLACK_NOTIFICATIONS"

if [[ "$SLACK_NOTIFICATIONS_ENABLED" == "true" ]]; then
    # Verify the SSM parameter exists (Lambda will fetch the actual value at runtime)
    echo "Verifying Slack webhook SSM parameter: $SLACK_WEBHOOK_SSM_PARAM"

    if aws ssm get-parameter \
        --name "$SLACK_WEBHOOK_SSM_PARAM" \
        --query 'Parameter.Name' \
        --output text \
        --region "$REGION" \
        --no-cli-pager >/dev/null 2>&1; then
        echo "SSM parameter verified: $SLACK_WEBHOOK_SSM_PARAM"
    else
        # Notifications are enabled but the parameter is missing - fail fast
        echo "ERROR: SSM parameter not found: $SLACK_WEBHOOK_SSM_PARAM"
        echo "   Slack notifications are enabled for environment '$TARGET_ENVIRONMENT'."
        echo "   Set ENABLE_SLACK_NOTIFICATIONS=false to opt out, or create the parameter:"
        echo ""
        echo "   aws ssm put-parameter --name '$SLACK_WEBHOOK_SSM_PARAM' \\"
        echo "     --value 'https://hooks.slack.com/services/...' \\"
        echo "     --type SecureString --region $REGION"
        exit 1
    fi
else
    echo "INFO: Slack notifications disabled for environment '${TARGET_ENVIRONMENT}' (skipping SSM verification)"
fi

echo ""
echo "Configuration:"
echo "  Central Account ID: $ACCOUNT_ID"
echo "  AWS Region:         $REGION"
echo "  GitHub Repo:        $GITHUB_REPOSITORY"
echo "  GitHub Branch:      $GITHUB_BRANCH"
echo "  Target Environment: $TARGET_ENVIRONMENT"
echo "  Name Prefix:        ${NAME_PREFIX:-<none>}"
if [[ "$SLACK_NOTIFICATIONS_ENABLED" == "true" ]]; then
    echo "  Slack Notifications: enabled (SSM: $SLACK_WEBHOOK_SSM_PARAM)"
else
    echo "  Slack Notifications: disabled"
fi
echo ""
echo "Proceeding with bootstrap..."

echo ""
echo "==================================================="
echo "Step 1: Creating Terraform State Infrastructure"
echo "==================================================="

# Create state bucket (uses lockfile-based locking)
STATE_BUCKET="terraform-state-${ACCOUNT_ID}"

"${REPO_ROOT}/scripts/bootstrap-state.sh" --central "$REGION"

echo ""

echo "==================================================="
echo "Step 2: Ensuring GitHub CodeStar Connection"
echo "==================================================="

CODESTAR_CONNECTION_NAME="rosa-regional-github-shared"

# Resolve the centrally-managed connection, creating it when it is missing.
if ! EXISTING_ARN=$(aws codestar-connections list-connections \
    --provider-type-filter GitHub \
    --query "Connections[?ConnectionName=='${CODESTAR_CONNECTION_NAME}'].ConnectionArn | [0]" \
    --output text --no-cli-pager); then
    echo "ERROR: Failed to list CodeStar connections." >&2
    exit 1
fi

if [[ -n "$EXISTING_ARN" && "$EXISTING_ARN" != "None" ]]; then
    echo "Found existing CodeStar connection: $EXISTING_ARN"
    GITHUB_CONNECTION_ARN="$EXISTING_ARN"
else
    echo "Creating CodeStar connection: ${CODESTAR_CONNECTION_NAME}"
    GITHUB_CONNECTION_ARN=$(aws codestar-connections create-connection \
        --provider-type GitHub \
        --connection-name "${CODESTAR_CONNECTION_NAME}" \
        --query "ConnectionArn" \
        --output text --no-cli-pager)
    echo "Created CodeStar connection: $GITHUB_CONNECTION_ARN"
    echo "Authorize the pending connection in the AWS Console before continuing."
fi

# Verify connection is AVAILABLE before proceeding
CONNECTION_STATUS=$(aws codestar-connections get-connection \
    --connection-arn "$GITHUB_CONNECTION_ARN" \
    --query "Connection.ConnectionStatus" \
    --output text --no-cli-pager)

if [[ "$CONNECTION_STATUS" != "AVAILABLE" ]]; then
    echo ""
    echo "WARNING: Connection status is: $CONNECTION_STATUS"
    echo "   CodeBuild projects require an AVAILABLE connection to function."
    echo "   Please authorize the connection in the AWS Console before continuing."
    echo ""

    POLL_INTERVAL=15
    MAX_WAIT=300
    WAITED=0
    echo "   Polling every ${POLL_INTERVAL}s (timeout: ${MAX_WAIT}s)..."
    while [[ "$CONNECTION_STATUS" != "AVAILABLE" && "$WAITED" -lt "$MAX_WAIT" ]]; do
        sleep "$POLL_INTERVAL"
        WAITED=$((WAITED + POLL_INTERVAL))
        CONNECTION_STATUS=$(aws codestar-connections get-connection \
            --connection-arn "$GITHUB_CONNECTION_ARN" \
            --query "Connection.ConnectionStatus" \
            --output text --no-cli-pager)
        echo "   [$WAITED/${MAX_WAIT}s] Connection status: $CONNECTION_STATUS"
    done

    if [[ "$CONNECTION_STATUS" != "AVAILABLE" ]]; then
        echo "ERROR: Timed out waiting for connection to become AVAILABLE (status: $CONNECTION_STATUS)."
        exit 1
    fi
fi

echo "CodeStar connection is AVAILABLE"

echo ""
echo "==================================================="
echo "Step 3: Deploying CodeBuild Infrastructure"
echo "==================================================="

cd "${REPO_ROOT}/terraform/config/central-account-bootstrap"

# Initialize Terraform
echo "Initializing Terraform..."
terraform init -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=${NAME_PREFIX:+${NAME_PREFIX}-}central-account-bootstrap/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="use_lockfile=true"

# Keep resolved account descriptors in a JSON variable file rather than
# interpolating configuration values into HCL. Terraform loads it for import,
# plan, apply, and subsequent teardown from this checkout.
jq -n --argjson regional_cluster "$REGIONAL_CLUSTER" \
    --argjson management_clusters "$MANAGEMENT_CLUSTERS" \
    '{regional_cluster: $regional_cluster, management_clusters: $management_clusters}' \
    > cluster-iam.auto.tfvars.json

# Import the existing CodeStar connection into terraform state so it can
# reference the ARN directly (instead of passing it as a variable).
# The connection is shared across runs and is removed from state before
# destroy so it persists.
echo "Importing CodeStar connection into Terraform state..."
terraform state rm aws_codestarconnections_connection.github >/dev/null 2>&1 || true
if ! terraform import -var="github_repository=${GITHUB_REPOSITORY}" \
    aws_codestarconnections_connection.github "$GITHUB_CONNECTION_ARN"; then
    echo "ERROR: Failed to import the existing CodeStar connection; refusing to continue." >&2
    exit 1
fi

# Create tfvars file
cat > terraform.tfvars <<EOF
github_repository     = "${GITHUB_REPOSITORY}"
github_branch         = "${GITHUB_BRANCH}"
region                = "${REGION}"
environment           = "${TARGET_ENVIRONMENT}"
name_prefix           = "${NAME_PREFIX}"
enable_slack_notifications = ${SLACK_NOTIFICATIONS_ENABLED}
slack_webhook_ssm_param = "${SLACK_WEBHOOK_SSM_PARAM}"
EOF

echo "Terraform configuration created (terraform.tfvars)"
echo ""

# Run terraform plan
echo "Running Terraform plan..."
terraform plan -var-file=terraform.tfvars -out=tfplan

echo ""
echo "Applying Terraform configuration..."
terraform apply tfplan

echo ""
echo "==================================================="
echo "Step 4: Provisioning CodeBuild Projects"
echo "==================================================="

read_required_terraform_output() {
    local output_name="$1"
    local output_value

    if ! output_value=$(terraform output -raw "$output_name"); then
        echo "ERROR: Failed to read required Terraform output '$output_name'" >&2
        return 1
    fi
    if [[ -z "$output_value" || "$output_value" == "None" ]]; then
        echo "ERROR: Required Terraform output '$output_name' is empty" >&2
        return 1
    fi

    printf '%s\n' "$output_value"
}

# Export terraform outputs for provision-cluster-resources.sh
PLATFORM_IMAGE=$(read_required_terraform_output platform_container_image)
GITHUB_CONNECTION_ARN=$(read_required_terraform_output github_connection_arn)
RC_CODEBUILD_ROLE_ARN=$(read_required_terraform_output rc_codebuild_role_arn)
MC_CODEBUILD_ROLE_ARN=$(read_required_terraform_output mc_codebuild_role_arn)
CODEPIPELINE_ROLE_ARN=$(read_required_terraform_output codepipeline_role_arn)
PIPELINE_ARTIFACT_BUCKET=$(read_required_terraform_output codepipeline_artifact_bucket_name)
export PLATFORM_IMAGE GITHUB_CONNECTION_ARN RC_CODEBUILD_ROLE_ARN
export MC_CODEBUILD_ROLE_ARN CODEPIPELINE_ROLE_ARN PIPELINE_ARTIFACT_BUCKET
export ENVIRONMENT="${TARGET_ENVIRONMENT}"
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY}"
export GITHUB_BRANCH="${GITHUB_BRANCH}"

cd "${REPO_ROOT}"

echo "Running provision-cluster-resources.sh..."
./scripts/provision-cluster-resources.sh

echo ""
echo "==================================================="
echo "Bootstrap Complete!"
echo "==================================================="
echo ""
echo "CodeBuild projects and CodePipelines have been created for RC/MC clusters."
echo "To add more regions, update config/<env>/<region>.yaml and run scripts/render.py."
echo ""
