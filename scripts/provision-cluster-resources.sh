#!/usr/bin/env bash
# Cluster lifecycle provisioner: creates/updates/deletes the CodeBuild worker and
# matching CodePipeline for each RC/MC cluster.
#
# With no arguments, processes every rendered cluster in the environment. The
# explicit create/delete commands provide the same per-cluster contract for the
# MC autoscaler.
#
# Required environment variables:
#   ENVIRONMENT          - Target environment (e.g., staging, production)
#   GITHUB_REPOSITORY    - GitHub repository in owner/name format
#   GITHUB_BRANCH        - GitHub branch to track
#   GITHUB_CONNECTION_ARN - resolved CodeStar connection ARN from bootstrap
#   PLATFORM_IMAGE       - Platform container image URI
#   RC_CODEBUILD_ROLE_ARN - ARN of the centrally-managed RC CodeBuild role
#   MC_CODEBUILD_ROLE_ARN - ARN of the shared MC CodeBuild role
#   CODEPIPELINE_ROLE_ARN - ARN of the shared cluster CodePipeline role
#   PIPELINE_ARTIFACT_BUCKET - S3 bucket used by cluster CodePipelines

set -euo pipefail
trap 'echo "FAILED: line $LINENO, exit code $?" >&2' ERR

echo "Provisioning cluster CodeBuild and CodePipeline resources for ${ENVIRONMENT:-staging}"

# Match the conditional FIPS endpoint policy of the Terraform-managed pipelines
# these CodeBuild/CodePipeline API calls replace. Other AWS calls keep their
# service-specific endpoint configuration.
aws_cluster_pipeline() {
    local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    local use_fips=false
    [[ "$region" == us-* ]] && use_fips=true
    AWS_USE_FIPS_ENDPOINT="$use_fips" aws "$@"
}

# ──────────────────────────────────────────────────────────────────────────────
# Platform Image Computation (ADR: fail-closed image check)
# ──────────────────────────────────────────────────────────────────────────────

DOCKERFILE="terraform/modules/platform-image/Dockerfile"
if [ -f "$DOCKERFILE" ] && [ -n "${PLATFORM_IMAGE:-}" ]; then
  _computed_tag=$(sha256sum "$DOCKERFILE" | cut -c1-12)
  _base_repo="${PLATFORM_IMAGE%:*}"
  PLATFORM_IMAGE="${_base_repo}:${_computed_tag}"
  echo "Platform image (computed from Dockerfile): ${PLATFORM_IMAGE}"
fi

# Fail-closed: verify image exists in ECR before create/update
verify_platform_image_exists() {
    local image_uri="$1"
    local repo="${image_uri%:*}"
    local tag="${image_uri##*:}"
    local repository_name

    # Public ECR uses different API
    if [[ "$repo" =~ ^public\.ecr\.aws ]]; then
        # Remove the public ECR registry alias but preserve nested repository paths.
        repository_name="${repo#public.ecr.aws/}"
        repository_name="${repository_name#*/}"
        if ! aws ecr-public describe-images --repository-name "$repository_name" --image-ids imageTag="$tag" --region us-east-1 --no-cli-pager >/dev/null 2>&1; then
            return 1
        fi
    else
        # Private ECR - extract region from repo URI
        local region="${repo#*.ecr.}"
        region="${region%%.*}"
        repository_name="${repo#*/}"
        if ! aws ecr describe-images --repository-name "$repository_name" --image-ids imageTag="$tag" --region "$region" --no-cli-pager >/dev/null 2>&1; then
            return 1
        fi
    fi

    return 0
}

# Ensure platform image exists; build if missing (Day-0/1)
ensure_platform_image() {
    local image_uri="$1"

    echo "Ensuring platform image exists: $image_uri"

    if verify_platform_image_exists "$image_uri"; then
        echo "✓ Platform image exists: $image_uri"
        return 0
    fi

    echo "Platform image not found in ECR — building now..."

    # Determine build project name
    local project_name="${NAME_PREFIX:+${NAME_PREFIX}-}build-platform-image"

    # Build at the ref we were handed. Pipelines and ArgoCD only ever follow
    # GITHUB_BRANCH; local HEAD is not necessarily that ref.
    echo "Building at ref: $GITHUB_BRANCH"

    # Start the build
    echo "Starting build: $project_name"
    local build_id
    if ! build_id=$(aws_cluster_pipeline codebuild start-build \
        --project-name "$project_name" \
        --source-version "$GITHUB_BRANCH" \
        --query 'build.id' \
        --output text \
        --no-cli-pager 2>&1); then
        echo "ERROR: Failed to start build for $project_name" >&2
        echo "$build_id" >&2
        exit 1
    fi

    echo "Build started: $build_id"

    # Wait for build to complete (poll every 15s, timeout 30 min)
    local max_wait=1800
    local waited=0
    local poll_interval=15

    while [ $waited -lt $max_wait ]; do
        local status
        if ! status=$(aws_cluster_pipeline codebuild batch-get-builds \
            --ids "$build_id" \
            --query 'builds[0].buildStatus' \
            --output text \
            --no-cli-pager 2>&1); then
            echo "WARNING: batch-get-builds failed, retrying..." >&2
            sleep $poll_interval
            waited=$((waited + poll_interval))
            continue
        fi

        case "$status" in
            SUCCEEDED)
                echo "✓ Build succeeded: $build_id"
                break
                ;;
            FAILED|TIMED_OUT|FAULT|STOPPED)
                echo "ERROR: Build failed with status: $status" >&2
                echo "Check CloudWatch logs for build: $build_id" >&2
                exit 1
                ;;
            IN_PROGRESS|QUEUED)
                echo "  [$waited/${max_wait}s] Build status: $status"
                sleep $poll_interval
                waited=$((waited + poll_interval))
                ;;
            *)
                echo "WARNING: Unknown build status: $status" >&2
                sleep $poll_interval
                waited=$((waited + poll_interval))
                ;;
        esac
    done

    if [ $waited -ge $max_wait ]; then
        echo "ERROR: Build did not complete within ${max_wait}s" >&2
        exit 1
    fi

    # Re-verify image now exists
    echo "Re-verifying platform image after build..."
    if ! verify_platform_image_exists "$image_uri"; then
        echo "ERROR: Platform image still missing after successful build!" >&2
        exit 1
    fi

    echo "✓ Platform image built and verified: $image_uri"
}

# ──────────────────────────────────────────────────────────────────────────────
# Helper Functions (preserved from original)
# ──────────────────────────────────────────────────────────────────────────────

# Central account state is initialized lazily so explicit help/delete command
# parsing does not require an unrelated STS call.
CENTRAL_ACCOUNT_ID="${CENTRAL_ACCOUNT_ID:-}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"

init_central_state() {
    if [ -z "$CENTRAL_ACCOUNT_ID" ]; then
        if ! CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text); then
            echo "ERROR: Failed to resolve the central AWS account ID" >&2
            return 1
        fi
        if [ -z "$CENTRAL_ACCOUNT_ID" ] || [ "$CENTRAL_ACCOUNT_ID" = "None" ]; then
            echo "ERROR: AWS returned an empty central account ID" >&2
            return 1
        fi
    fi
    if [ -z "$TF_STATE_BUCKET" ]; then
        TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
    fi
}

# Save central credentials for account switching
_CENTRAL_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
_CENTRAL_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
_CENTRAL_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

# Track which target accounts have had state buckets bootstrapped
BOOTSTRAPPED_ACCOUNTS=""

# Bootstrap state bucket in a target account (idempotent)
bootstrap_target_state_bucket() {
    local target_account_id="$1"
    local target_region="$2"

    init_central_state || return 1

    if echo "$BOOTSTRAPPED_ACCOUNTS" | grep -q "|${target_account_id}|"; then
        echo "State bucket already bootstrapped for account $target_account_id (skipping)"
        return 0
    fi

    if [ "$target_account_id" = "$CENTRAL_ACCOUNT_ID" ]; then
        ./scripts/bootstrap-state.sh "$target_region" || return 1
    else
        local admin_role="${CHILD_ADMIN_ROLE_NAME:-OrganizationAccountAccessRole}"
        local creds
        if ! creds=$(aws sts assume-role \
            --role-arn "arn:aws:iam::${target_account_id}:role/${admin_role}" \
            --role-session-name "bootstrap-state-${target_account_id}" \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
            --output text 2>&1); then
            echo "ERROR: Failed to assume ${admin_role} role in account $target_account_id"
            echo "Error: $creds"
            return 1
        fi

        if ! AWS_ACCESS_KEY_ID=$(echo "$creds" | awk '{print $1}') \
            AWS_SECRET_ACCESS_KEY=$(echo "$creds" | awk '{print $2}') \
            AWS_SESSION_TOKEN=$(echo "$creds" | awk '{print $3}') \
            ./scripts/bootstrap-state.sh "$target_region"; then
            echo "ERROR: Failed to bootstrap Terraform state in account $target_account_id" >&2
            return 1
        fi
    fi

    BOOTSTRAPPED_ACCOUNTS="${BOOTSTRAPPED_ACCOUNTS}|${target_account_id}|"
}

# Resolve SSM parameter if value starts with "ssm://"
resolve_ssm_param() {
    local value="$1"
    local region="${2:-${AWS_REGION}}"
    if [[ "$value" == ssm://* ]]; then
        local param_name="${value#ssm://}"
        aws ssm get-parameter \
            --name "$param_name" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${region}" \
            --no-cli-pager
    else
        echo "$value"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Resource specification and lifecycle functions
# ──────────────────────────────────────────────────────────────────────────────

# Generate CodeBuild project spec JSON (deterministic jq output for hashing)
# Args: cluster_type (regional|management) [followed by config vars via env]
generate_project_spec() {
    local cluster_type="$1"
    local project_name="$2"
    local service_role_arn="$3"
    local buildspec_path="$4"
    local timeout_minutes="$5"

    # Build environment variables array
    local env_vars='[]'
    env_vars=$(jq -n \
        --arg github_repo "$GITHUB_REPOSITORY" \
        --arg github_branch "$GITHUB_BRANCH" \
        --arg environment "$ENVIRONMENT" \
        --arg github_conn_arn "$GITHUB_CONNECTION_ARN" \
        --arg platform_image "$PLATFORM_IMAGE" \
        --arg target_account_id "${TARGET_ACCOUNT_ID:-}" \
        --arg target_region "${AWS_REGION:-us-east-1}" \
        --arg child_admin_role "${CHILD_ADMIN_ROLE_NAME:-OrganizationAccountAccessRole}" \
        --arg repo_url "https://github.com/$GITHUB_REPOSITORY.git" \
        --arg repo_branch "$GITHUB_BRANCH" \
        '[
            {name: "GITHUB_REPOSITORY", value: $github_repo, type: "PLAINTEXT"},
            {name: "GITHUB_BRANCH", value: $github_branch, type: "PLAINTEXT"},
            {name: "ENVIRONMENT", value: $environment, type: "PLAINTEXT"},
            {name: "GITHUB_CONNECTION_ARN", value: $github_conn_arn, type: "PLAINTEXT"},
            {name: "PLATFORM_IMAGE", value: $platform_image, type: "PLAINTEXT"},
            {name: "TARGET_ACCOUNT_ID", value: $target_account_id, type: "PLAINTEXT"},
            {name: "TARGET_REGION", value: $target_region, type: "PLAINTEXT"},
            {name: "CHILD_ADMIN_ROLE_NAME", value: $child_admin_role, type: "PLAINTEXT"},
            {name: "REPOSITORY_URL", value: $repo_url, type: "PLAINTEXT"},
            {name: "REPOSITORY_BRANCH", value: $repo_branch, type: "PLAINTEXT"}
        ]')

    # Add cluster-type-specific env vars
    if [ "$cluster_type" = "regional" ]; then
        env_vars=$(echo "$env_vars" | jq \
            --arg regional_id "${REGIONAL_ID:-}" \
            --arg zone_id "${ENVIRONMENT_HOSTED_ZONE_ID:-}" \
            '. + [
                {name: "REGIONAL_ID", value: $regional_id, type: "PLAINTEXT"},
                {name: "ENVIRONMENT_HOSTED_ZONE_ID", value: $zone_id, type: "PLAINTEXT"}
            ]')
    elif [ "$cluster_type" = "management" ]; then
        env_vars=$(echo "$env_vars" | jq \
            --arg management_id "${MANAGEMENT_ID:-}" \
            '. + [{name: "MANAGEMENT_ID", value: $management_id, type: "PLAINTEXT"}]')
    fi

    # Generate the full project spec (keys sorted for deterministic hash)
    jq -n -S \
        --arg name "$project_name" \
        --arg role_arn "$service_role_arn" \
        --arg image "$PLATFORM_IMAGE" \
        --arg buildspec "$buildspec_path" \
        --argjson timeout "$timeout_minutes" \
        --arg github_repo "$GITHUB_REPOSITORY" \
        --arg github_branch "$GITHUB_BRANCH" \
        --arg github_conn_arn "$GITHUB_CONNECTION_ARN" \
        --arg log_group "/aws/codebuild/${CODEPIPELINE_ROLE_ARN##*/}/${cluster_type}" \
        --argjson env_vars "$env_vars" \
        '{
            name: $name,
            serviceRole: $role_arn,
            artifacts: {type: "CODEPIPELINE"},
            environment: {
                type: "LINUX_CONTAINER",
                image: $image,
                computeType: "BUILD_GENERAL1_SMALL",
                imagePullCredentialsType: "CODEBUILD",
                privilegedMode: false,
                environmentVariables: $env_vars
            },
            source: {
                type: "CODEPIPELINE",
                buildspec: $buildspec
            },
            logsConfig: {
                cloudWatchLogs: {status: "ENABLED", groupName: $log_group}
            },
            timeoutInMinutes: $timeout,
            concurrentBuildLimit: 1
        }'
}

# Compute hash1 (SHA256 of spec with .tags stripped)
compute_spec_hash() {
    local spec="$1"
    echo "$spec" | jq -S 'del(.tags)' | sha256sum | awk '{print $1}'
}

generate_pipeline_file_paths() {
    local cluster_type="$1"
    local env="$2"
    local region_deployment="$3"
    local cluster_id="${4:-}"

    if [ "$cluster_type" = "regional" ]; then
        jq -n \
            --arg env "$env" \
            --arg region "$region_deployment" \
            '[
                ("deploy/" + $env + "/" + $region + "/pipeline-regional-cluster-inputs/**"),
                ("deploy/" + $env + "/" + $region + "/argocd-{values-regional-cluster.yaml,bootstrap-regional-cluster/**}"),
                "terraform/config/regional-cluster/**",
                "terraform/modules/{zoa,zoa-lambda,zoa-access}/**",
                "scripts/buildspec/build-zoa-lambda.sh"
            ]'
    elif [ "$cluster_type" = "management" ]; then
        jq -n \
            --arg env "$env" \
            --arg region "$region_deployment" \
            --arg mc_id "$cluster_id" \
            '[
                ("deploy/" + $env + "/" + $region + "/pipeline-management-cluster-" + $mc_id + "-inputs/**"),
                ("deploy/" + $env + "/" + $region + "/argocd-{values-management-cluster.yaml,bootstrap-management-cluster/**}"),
                "terraform/config/{management-cluster,kube-applier-dynamodb-provisioning,mc-zoa-target-ssm-provisioning}/**",
                "scripts/buildspec/provision-mc-zoa-target-ssm.sh"
            ]'
    fi
}

pipeline_name_for_project() {
    echo "${1}-pipeline"
}

generate_pipeline_spec() {
    local cluster_type="$1"
    local pipeline_name="$2"
    local project_name="$3"
    local cluster_id="$4"
    local region_deployment="$5"
    local push_triggers_enabled="${ENABLE_CODEPIPELINE_PUSH_TRIGGERS:-true}"
    local file_paths

    if [[ "$push_triggers_enabled" != "true" && "$push_triggers_enabled" != "false" ]]; then
        echo "ERROR: ENABLE_CODEPIPELINE_PUSH_TRIGGERS must be true or false" >&2
        return 1
    fi

    file_paths=$(generate_pipeline_file_paths "$cluster_type" "$ENVIRONMENT" "$region_deployment" "$cluster_id")

    jq -n -S \
        --arg name "$pipeline_name" \
        --arg role "$CODEPIPELINE_ROLE_ARN" \
        --arg bucket "$PIPELINE_ARTIFACT_BUCKET" \
        --arg connection "$GITHUB_CONNECTION_ARN" \
        --arg repository "$GITHUB_REPOSITORY" \
        --arg branch "$GITHUB_BRANCH" \
        --arg project "$project_name" \
        --argjson file_paths "$file_paths" \
        --argjson push_triggers_enabled "$push_triggers_enabled" \
        --arg cluster_type "$cluster_type" \
        '{pipeline: (
          {
            name: $name,
            roleArn: $role,
            pipelineType: "V2",
            executionMode: "SUPERSEDED",
            artifactStore: {type: "S3", location: $bucket},
            triggers: (if $push_triggers_enabled then [{
              providerType: "CodeStarSourceConnection",
              gitConfiguration: {
                sourceActionName: "Source",
                push: [{
                  branches: {includes: [$branch]},
                  filePaths: {includes: $file_paths}
                }]
              }
            }] else [] end),
            stages: [
              {
                name: "Source",
                actions: [{
                  name: "Source",
                  actionTypeId: {category: "Source", owner: "AWS", provider: "CodeStarSourceConnection", version: "1"},
                  configuration: {
                    ConnectionArn: $connection,
                    FullRepositoryId: $repository,
                    BranchName: $branch,
                    DetectChanges: "false"
                  },
                  outputArtifacts: [{name: "source_output"}],
                  runOrder: 1
                }]
              },
              {
                name: "Build",
                actions: [{
                  name: "ApplyInfrastructure",
                  actionTypeId: {category: "Build", owner: "AWS", provider: "CodeBuild", version: "1"},
                  configuration: {
                    ProjectName: $project,
                    EnvironmentVariables: "[{\"name\":\"IS_DESTROY\",\"value\":\"#{variables.IS_DESTROY}\",\"type\":\"PLAINTEXT\"}]"
                  },
                  inputArtifacts: [{name: "source_output"}],
                  runOrder: 1
                }]
              }
            ]
          }
          + {
              variables: [{name: "IS_DESTROY", defaultValue: "false"}]
            }
        )}'
}

# AWS returns optional empty collections that are absent from create requests.
normalize_pipeline_spec() {
    jq -S 'del(.version) | walk(
        if type == "object" then
            with_entries(select(.value != null and .value != [] and .value != {}))
        else . end
    )'
}

upsert_pipeline() {
    local cluster_type="$1"
    local project_name="$2"
    local cluster_id="$3"
    local region_deployment="$4"
    local pipeline_name
    pipeline_name=$(pipeline_name_for_project "$project_name")
    local spec
    spec=$(generate_pipeline_spec "$cluster_type" "$pipeline_name" "$project_name" "$cluster_id" "$region_deployment") || return 1

    if aws_cluster_pipeline codepipeline get-pipeline --name "$pipeline_name" --query 'pipeline.name' --output text --no-cli-pager 2>/dev/null | grep -qx "$pipeline_name"; then
        local current_spec current_normalized desired_normalized active_count
        current_spec=$(aws_cluster_pipeline codepipeline get-pipeline --name "$pipeline_name" --query 'pipeline' --output json --no-cli-pager)
        current_normalized=$(normalize_pipeline_spec <<< "$current_spec") || return 1
        desired_normalized=$(jq '.pipeline' <<< "$spec" | normalize_pipeline_spec) || return 1

        if [[ "$current_normalized" == "$desired_normalized" ]]; then
            echo "✓ CodePipeline unchanged: $pipeline_name"
            return 0
        fi

        if ! active_count=$(aws_cluster_pipeline codepipeline list-pipeline-executions \
            --pipeline-name "$pipeline_name" \
            --max-results 100 \
            --output json \
            --no-cli-pager | jq -e '[.pipelineExecutionSummaries[]? | select(.status == "InProgress" or .status == "Stopping" or .status == "Queued")] | length'); then
            echo "ERROR: Failed to list executions for $pipeline_name; cannot safely update" >&2
            return 1
        fi
        if (( active_count > 0 )); then
            local current_core desired_core
            current_core=$(jq 'del(.triggers)' <<< "$current_normalized") || return 1
            desired_core=$(jq 'del(.triggers)' <<< "$desired_normalized") || return 1
            if [[ "$current_core" != "$desired_core" ]]; then
                echo "ERROR: CodePipeline $pipeline_name has an active execution and non-trigger settings changed; update would stop that execution. Wait for it to finish, then resume provisioning." >&2
                return 1
            fi
            echo "ERROR: CodePipeline $pipeline_name has an active execution and its push-trigger settings changed. Wait for it to finish, then resume provisioning to apply the trigger update." >&2
            return 1
        fi

        if ! aws_cluster_pipeline codepipeline update-pipeline --cli-input-json "$spec" --no-cli-pager >/dev/null; then
            echo "ERROR: Failed to update CodePipeline $pipeline_name" >&2
            return 1
        fi
        echo "✓ CodePipeline updated: $pipeline_name"
    else
        if ! aws_cluster_pipeline codepipeline create-pipeline --cli-input-json "$spec" --no-cli-pager >/dev/null; then
            echo "ERROR: Failed to create CodePipeline $pipeline_name" >&2
            return 1
        fi
        echo "✓ CodePipeline created: $pipeline_name"
    fi
}

# Compare only fields managed here; AWS adds defaults and response metadata.
normalize_project_spec() {
    jq -S '{
        name, serviceRole,
        artifacts: {type: .artifacts.type},
        environment: (.environment | {
            type, image, computeType, imagePullCredentialsType, privilegedMode,
            environmentVariables: (.environmentVariables | sort_by(.name))
        }),
        source: (.source | {type, buildspec}),
        logsConfig: {cloudWatchLogs: (.logsConfig.cloudWatchLogs | {status, groupName})},
        timeoutInMinutes, concurrentBuildLimit
    }'
}

# Reconcile project configuration and ownership before starting its pipeline.
upsert_project() {
    local cluster_type="$1"
    local project_name="$2"
    local service_role_arn="$3"
    local buildspec_path="$4"
    local timeout_minutes="$5"
    local cluster_id="$6"
    local region_deployment="${REGION_DEPLOYMENT:?REGION_DEPLOYMENT not set}"
    local scope="${CODEPIPELINE_ROLE_ARN:?CODEPIPELINE_ROLE_ARN not set}"

    echo "Upserting CodeBuild project: $project_name ($cluster_type)"
    local spec desired_hash existing_project existing_scope tags desired_normalized current_normalized
    spec=$(generate_project_spec "$cluster_type" "$project_name" "$service_role_arn" "$buildspec_path" "$timeout_minutes") || return 1
    desired_hash=$(compute_spec_hash "$spec") || return 1
    if ! existing_project=$(aws_cluster_pipeline codebuild batch-get-projects \
        --names "$project_name" --query 'projects[0]' --output json --no-cli-pager); then
        echo "ERROR: Failed to read CodeBuild project $project_name" >&2
        return 1
    fi

    existing_scope=$(jq -r '[.tags[]? | select(.key == "ProvisioningScope") | .value][0] // empty' <<< "$existing_project") || return 1
    if [[ -n "$existing_scope" && "$existing_scope" != "$scope" ]]; then
        echo "ERROR: CodeBuild project $project_name belongs to a different provisioning scope" >&2
        return 1
    fi
    if [[ -z "$existing_scope" && "$(jq -r '.name // empty' <<< "$existing_project")" == "$project_name" &&
          "$(jq -r '.serviceRole // empty' <<< "$existing_project")" != "$service_role_arn" ]]; then
        echo "ERROR: Refusing to adopt untagged CodeBuild project $project_name with a different service role" >&2
        return 1
    fi
    # Preserve unrelated tags while repairing our ownership tag and hash.
    tags=$(jq --arg scope "$scope" --arg hash "$desired_hash" '
        [(.tags // [])[] | select(.key != "ProvisioningScope" and .key != "DefinitionHash")]
        + [{key: "ProvisioningScope", value: $scope}, {key: "DefinitionHash", value: $hash}]
        | sort_by(.key)
    ' <<< "$existing_project") || return 1
    spec=$(jq --argjson tags "$tags" '.tags = $tags' <<< "$spec") || return 1

    if [[ "$(jq -r '.name // empty' <<< "$existing_project")" == "$project_name" ]]; then
        current_normalized=$(normalize_project_spec <<< "$existing_project") || return 1
        desired_normalized=$(normalize_project_spec <<< "$spec") || return 1
        if [[ "$current_normalized" != "$desired_normalized" ]]; then
            aws_cluster_pipeline codebuild update-project --cli-input-json "$spec" --no-cli-pager >/dev/null || return 1
            echo "CodeBuild project configuration updated: $project_name"
        elif [[ "$(jq -S '(.tags // []) | sort_by(.key)' <<< "$existing_project")" != "$(jq -S . <<< "$tags")" ]]; then
            aws_cluster_pipeline codebuild update-project --name "$project_name" --tags "$tags" --no-cli-pager >/dev/null || return 1
            echo "CodeBuild project tags repaired: $project_name"
        else
            echo "CodeBuild project unchanged: $project_name"
        fi
    else
        aws_cluster_pipeline codebuild create-project --cli-input-json "$spec" --no-cli-pager >/dev/null || return 1
        echo "CodeBuild project created: $project_name"
    fi

    # CreatePipeline starts its own Day-1 execution. Ownership must be in place
    # before that execution uses the pipeline role's tag-scoped permissions.
    upsert_pipeline "$cluster_type" "$project_name" "$cluster_id" "$region_deployment"
}

# Delete a CodeBuild project (idempotent)
delete_project() {
    local project_name="$1"

    echo "═══ Deleting CodePipeline and CodeBuild project: $project_name ═══"

    local pipeline_name deletion_error
    pipeline_name=$(pipeline_name_for_project "$project_name")
    if deletion_error=$(aws_cluster_pipeline codepipeline delete-pipeline --name "$pipeline_name" --no-cli-pager 2>&1); then
        echo "✓ CodePipeline deleted: $pipeline_name"
    elif [[ "$deletion_error" == *"(PipelineNotFoundException)"* ]]; then
        echo "CodePipeline does not exist: $pipeline_name"
    else
        echo "ERROR: Failed to delete CodePipeline $pipeline_name: $deletion_error" >&2
        return 1
    fi

    # Delete project (idempotent)
    if deletion_error=$(aws_cluster_pipeline codebuild delete-project --name "$project_name" --no-cli-pager 2>&1); then
        echo "✓ Project deleted"
    elif [[ "$deletion_error" == *"(ResourceNotFoundException)"* ]]; then
        echo "CodeBuild project does not exist: $project_name"
    else
        echo "ERROR: Failed to delete CodeBuild project $project_name: $deletion_error" >&2
        return 1
    fi
}

validate_environment() {
    if [[ -z "$ENVIRONMENT" || ! "$ENVIRONMENT" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "ERROR: ENVIRONMENT is empty or contains invalid characters: '${ENVIRONMENT}'" >&2
        return 1
    fi
}

validate_child_admin_role() {
    local role_name="$1"

    if [[ "$role_name" != "OrganizationAccountAccessRole" && "$role_name" != "rosa-seaplane-account-admin" ]]; then
        echo "ERROR: Invalid child_admin_role_name: '${role_name}'" >&2
        return 1
    fi
}

load_cluster_config() {
    local cluster_type="$1"
    local config_path="$2"
    local region_deployment="$3"

    if [ ! -f "$config_path" ]; then
        echo "ERROR: Cluster config does not exist: $config_path" >&2
        return 1
    fi

    if ! AWS_REGION=$(jq -er '.region // .target_region // "us-east-1"' "$config_path"); then
        echo "ERROR: Could not read region from $config_path" >&2
        return 1
    fi
    if [ -z "$AWS_REGION" ]; then
        echo "ERROR: region must not be empty in $config_path" >&2
        return 1
    fi
    if ! TARGET_ACCOUNT_ID=$(jq -er '.account_id // empty' "$config_path"); then
        echo "ERROR: account_id must be provided in $config_path" >&2
        return 1
    fi
    if ! TARGET_ACCOUNT_ID=$(resolve_ssm_param "$TARGET_ACCOUNT_ID" "$AWS_REGION"); then
        echo "ERROR: Failed to resolve account_id from $config_path" >&2
        return 1
    fi
    if ! CHILD_ADMIN_ROLE_NAME=$(jq -er '.child_admin_role_name // "OrganizationAccountAccessRole"' "$config_path"); then
        echo "ERROR: Could not read child_admin_role_name from $config_path" >&2
        return 1
    fi

    validate_child_admin_role "$CHILD_ADMIN_ROLE_NAME" || return 1

    if [ -z "$TARGET_ACCOUNT_ID" ]; then
        echo "ERROR: account_id must be provided in $config_path" >&2
        return 1
    fi
    if [[ ! "$TARGET_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        echo "ERROR: account_id must resolve to a 12-digit AWS account ID in $config_path" >&2
        return 1
    fi

    if [ "$cluster_type" = "regional" ]; then
        if ! REGIONAL_ID=$(jq -er '.regional_id // empty' "$config_path"); then
            echo "ERROR: regional_id is missing from $config_path" >&2
            return 1
        fi
        CLUSTER_PROJECT_ID="$REGIONAL_ID"
        export REGIONAL_ID
    else
        if ! MANAGEMENT_ID=$(jq -er '.management_id // empty' "$config_path"); then
            echo "ERROR: management_id is missing from $config_path" >&2
            return 1
        fi
        CLUSTER_PROJECT_ID="$MANAGEMENT_ID"
        export MANAGEMENT_ID
    fi

    if [ -z "$CLUSTER_PROJECT_ID" ]; then
        echo "ERROR: Cluster ID is missing from $config_path" >&2
        return 1
    fi

    REGION_DEPLOYMENT="$region_deployment"
    export AWS_REGION TARGET_ACCOUNT_ID CHILD_ADMIN_ROLE_NAME REGION_DEPLOYMENT
}

ensure_platform_image_once() {
    if [ "${PLATFORM_IMAGE_READY:-false}" = "true" ]; then
        return 0
    fi

    if [ -z "${PLATFORM_IMAGE:-}" ]; then
        echo "ERROR: PLATFORM_IMAGE must be set for cluster creation" >&2
        return 1
    fi
    ensure_platform_image "$PLATFORM_IMAGE" || return 1
    PLATFORM_IMAGE_READY=true
}

create_cluster_resource() {
    local cluster_type="$1"
    local config_path="$2"
    local region_deployment="$3"
    local service_role_arn buildspec_path timeout_minutes

    if [ "$cluster_type" = "regional" ]; then
        service_role_arn="${RC_CODEBUILD_ROLE_ARN:-}"
        buildspec_path="terraform/config/codebuild-regional-cluster/buildspec-combined.yml"
        timeout_minutes=90
    else
        service_role_arn="${MC_CODEBUILD_ROLE_ARN:-}"
        buildspec_path="terraform/config/codebuild-management-cluster/buildspec-combined.yml"
        timeout_minutes=180
    fi

    load_cluster_config "$cluster_type" "$config_path" "$region_deployment" || return 1
    if [ -z "$service_role_arn" ]; then
        echo "ERROR: Missing CodeBuild service role ARN for $cluster_type cluster $CLUSTER_PROJECT_ID" >&2
        return 1
    fi
    bootstrap_target_state_bucket "$TARGET_ACCOUNT_ID" "$AWS_REGION" || return 1
    ensure_platform_image_once || return 1

    upsert_project "$cluster_type" "$CLUSTER_PROJECT_ID" "$service_role_arn" \
        "$buildspec_path" "$timeout_minutes" "$CLUSTER_PROJECT_ID" || return 1
}

delete_cluster_resource() {
    local cluster_type="$1"
    local config_path="$2"

    if [ ! -f "$config_path" ]; then
        echo "ERROR: Cluster config does not exist: $config_path" >&2
        return 1
    fi

    AWS_REGION=$(jq -er '.region // .target_region // "us-east-1"' "$config_path") || return 1
    export AWS_REGION

    if [ "$cluster_type" = "regional" ]; then
        CLUSTER_PROJECT_ID=$(jq -r '.regional_id // ""' "$config_path")
    else
        CLUSTER_PROJECT_ID=$(jq -r '.management_id // ""' "$config_path")
    fi

    if [ -z "$CLUSTER_PROJECT_ID" ]; then
        echo "ERROR: Cluster ID is missing from $config_path" >&2
        return 1
    fi

    delete_project "$CLUSTER_PROJECT_ID"
}

create_rc() {
    create_cluster_resource regional "$1" "$2"
}

delete_rc() {
    delete_cluster_resource regional "$1"
}

create_mc() {
    create_cluster_resource management "$1" "$2"
}

delete_mc() {
    delete_cluster_resource management "$1"
}

print_usage() {
    cat <<'EOF'
Usage:
  provision-cluster-resources.sh
  provision-cluster-resources.sh create-rc --config PATH --region-deployment REGION
  provision-cluster-resources.sh delete-rc --config PATH
  provision-cluster-resources.sh create-mc --config PATH --region-deployment REGION
  provision-cluster-resources.sh delete-mc --config PATH

The no-argument form processes all rendered RC/MC configs. Explicit actions
operate on one cluster and are suitable for the MC autoscaler. Explicit create
actions only create/update resources; the caller starts the pipeline at the
desired source revision.
EOF
}

run_cluster_action() {
    local action="$1"
    shift
    local config_path=""
    local region_deployment="${REGION_DEPLOYMENT:-}"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --config)
                [ "$#" -ge 2 ] || { echo "ERROR: --config requires a path" >&2; return 2; }
                config_path="$2"
                shift 2
                ;;
            --region-deployment)
                [ "$#" -ge 2 ] || { echo "ERROR: --region-deployment requires a value" >&2; return 2; }
                region_deployment="$2"
                shift 2
                ;;
            --environment)
                [ "$#" -ge 2 ] || { echo "ERROR: --environment requires a value" >&2; return 2; }
                ENVIRONMENT="$2"
                shift 2
                ;;
            --help|-h)
                print_usage
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 2
                ;;
        esac
    done

    [ -n "$config_path" ] || { echo "ERROR: --config is required" >&2; return 2; }
    validate_environment || return 2

    case "$action" in
        create-rc|CreateRC)
            [ -n "$region_deployment" ] || { echo "ERROR: --region-deployment is required" >&2; return 2; }
            create_rc "$config_path" "$region_deployment"
            ;;
        delete-rc|DeleteRC)
            delete_rc "$config_path"
            ;;
        create-mc|CreateMC)
            [ -n "$region_deployment" ] || { echo "ERROR: --region-deployment is required" >&2; return 2; }
            create_mc "$config_path" "$region_deployment"
            ;;
        delete-mc|DeleteMC)
            delete_mc "$config_path"
            ;;
        *)
            echo "ERROR: Unknown lifecycle action: $action" >&2
            print_usage >&2
            return 2
            ;;
    esac
}

ENVIRONMENT="${ENVIRONMENT:-${TARGET_ENVIRONMENT:-staging}}"
PLATFORM_IMAGE_READY=false

if [ "$#" -gt 0 ]; then
    case "$1" in
        create-rc|CreateRC|delete-rc|DeleteRC|create-mc|CreateMC|delete-mc|DeleteMC)
            run_cluster_action "$@"
            exit $?
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            print_usage >&2
            exit 2
            ;;
    esac
fi

# ──────────────────────────────────────────────────────────────────────────────
# Main Execution (preserves original flow)
# ──────────────────────────────────────────────────────────────────────────────

# Validate environment
validate_environment

# Detect TF state region
init_central_state
TF_STATE_REGION=""
if [ -d "deploy/${ENVIRONMENT}" ]; then
    FIRST_REGIONAL_JSON=$(find "deploy/${ENVIRONMENT}" -name "regional-cluster.json" -path "*/pipeline-provisioner-inputs/*" -type f | head -n 1)
    if [ -n "$FIRST_REGIONAL_JSON" ]; then
        TF_STATE_REGION=$(jq -r '.tf_state_region // empty' "$FIRST_REGIONAL_JSON" 2>/dev/null || echo "")
    fi
fi

if [ -z "$TF_STATE_REGION" ]; then
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$TF_STATE_BUCKET" --region us-east-1 --query LocationConstraint --output text --no-cli-pager 2>/dev/null || echo "")
    if [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ] || [ -z "$BUCKET_REGION" ]; then
        TF_STATE_REGION="us-east-1"
    else
        TF_STATE_REGION="$BUCKET_REGION"
    fi
fi

# FORCE_DELETE_ALL_PIPELINES CI hack
FORCE_DELETE_ALL_PIPELINES="${FORCE_DELETE_ALL_PIPELINES:-false}"
PROVISION_FAILURES=0

# ──────────────────────────────────────────────────────────────────────────────
# DNS Environment Zone (terraform block preserved)
# ──────────────────────────────────────────────────────────────────────────────

ENVIRONMENT_DOMAIN=""
ENVIRONMENT_HOSTED_ZONE_ID=""

for _first_region_dir in deploy/${ENVIRONMENT}/*/; do
    [ -d "$_first_region_dir" ] || continue
    _prov_tf="${_first_region_dir}pipeline-provisioner-inputs/terraform.json"
    if [ -f "$_prov_tf" ]; then
        ENVIRONMENT_DOMAIN=$(jq -r '.domain // empty' "$_prov_tf" 2>/dev/null || echo "")
        CREATE_ENVIRONMENT_ZONE=$(jq -r '.create_environment_zone // "false"' "$_prov_tf" 2>/dev/null || echo "false")
    fi
    break
done

if [ -n "$ENVIRONMENT_DOMAIN" ] && [ "$CREATE_ENVIRONMENT_ZONE" = "true" ]; then
    echo "Provisioning DNS environment zone: $ENVIRONMENT_DOMAIN"

    cd terraform/config/dns-environment-zone

    terraform init \
        -reconfigure \
        -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="key=dns/environment-zone-${ENVIRONMENT}.tfstate" \
        -backend-config="region=$TF_STATE_REGION" \
        -backend-config="use_lockfile=true"

    # Retry helper inline (terraform still used for DNS zone)
    _max_attempts=3
    _attempt=1
    _wait_time=30
    while [ $_attempt -le $_max_attempts ]; do
        if terraform apply -auto-approve \
            -var="environment_domain=${ENVIRONMENT_DOMAIN}" \
            -var="environment=${ENVIRONMENT}"; then
            if ! ENVIRONMENT_HOSTED_ZONE_ID=$(terraform output -raw zone_id); then
                echo "ERROR: Failed to read zone_id after creating $ENVIRONMENT_DOMAIN" >&2
                exit 1
            fi
            if [ -z "$ENVIRONMENT_HOSTED_ZONE_ID" ]; then
                echo "ERROR: Terraform returned an empty zone_id for $ENVIRONMENT_DOMAIN" >&2
                exit 1
            fi
            break
        fi
        if [ $_attempt -lt $_max_attempts ]; then
            echo "DNS zone apply attempt $_attempt failed, retrying in ${_wait_time}s..."
            sleep $_wait_time
            _wait_time=$((_wait_time * 2))
            _attempt=$((_attempt + 1))
        else
            echo "ERROR: Failed to create environment zone: $ENVIRONMENT_DOMAIN" >&2
            exit 1
        fi
    done

    cd ../../..
fi

# ──────────────────────────────────────────────────────────────────────────────
# Process regions
# ──────────────────────────────────────────────────────────────────────────────

if [ ! -d "deploy/${ENVIRONMENT}" ]; then
    echo "ERROR: Environment directory does not exist: deploy/${ENVIRONMENT}" >&2
    exit 1
fi

shopt -s nullglob
region_dirs=("deploy/${ENVIRONMENT}"/*/)
shopt -u nullglob

if [ ${#region_dirs[@]} -eq 0 ]; then
    echo "ERROR: No region directories found in deploy/${ENVIRONMENT}/" >&2
    exit 1
fi

for region_dir in deploy/${ENVIRONMENT}/*/; do
    [ -d "$region_dir" ] || continue

    REGION_DEPLOYMENT=$(basename "$region_dir")
    echo "Processing: $ENVIRONMENT / $REGION_DEPLOYMENT"

    # ── Regional Cluster ──────────────────────────────────────────────────────
    if [ -f "${region_dir}pipeline-provisioner-inputs/regional-cluster.json" ]; then
        REGIONAL_CONFIG="${region_dir}pipeline-provisioner-inputs/regional-cluster.json"

        DELETE_FLAG="$FORCE_DELETE_ALL_PIPELINES"

        if [ "$DELETE_FLAG" == "true" ]; then
            delete_rc "$REGIONAL_CONFIG"
        else
            if ! create_rc "$REGIONAL_CONFIG" "$REGION_DEPLOYMENT"; then
                echo "ERROR: Regional resource provisioning failed for $REGIONAL_CONFIG" >&2
                PROVISION_FAILURES=$((PROVISION_FAILURES + 1))
            fi
        fi
    fi

    # ── Management Clusters ───────────────────────────────────────────────────
    shopt -s nullglob
    _mc_configs=(${region_dir}pipeline-provisioner-inputs/management-cluster-*.json)
    shopt -u nullglob
    if [ ${#_mc_configs[@]} -gt 0 ]; then
        for mc_config in ${region_dir}pipeline-provisioner-inputs/management-cluster-*.json; do
            [ -e "$mc_config" ] || continue

            _mc_basename=$(basename "$mc_config" .json)
            CLUSTER_NAME="${_mc_basename#management-cluster-}"

            DELETE_FLAG="$FORCE_DELETE_ALL_PIPELINES"

            if [ "$DELETE_FLAG" == "true" ]; then
                delete_mc "$mc_config"
            else
                if ! create_mc "$mc_config" "$REGION_DEPLOYMENT"; then
                    echo "ERROR: Management resource provisioning failed for $mc_config" >&2
                    PROVISION_FAILURES=$((PROVISION_FAILURES + 1))
                fi
            fi
        done
    fi

done

if [ "$PROVISION_FAILURES" -gt 0 ]; then
    echo "ERROR: Cluster resource provisioning completed with $PROVISION_FAILURES failure(s)" >&2
    exit 1
fi

echo "✓ Cluster resource provisioning complete"
