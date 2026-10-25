# ci/ephemeral-provider

Python package for provisioning, resyncing, and tearing down ephemeral CI environments for ROSA Seaplane.

For local development usage via Make targets, see [Provisioning a Development Environment](../../docs/development-environment.md).

## Credentials

Provide the token through an environment variable or the `--creds-dir` directory
(default: `/var/run/rosa-credentials/`):

| File           | Purpose                              | Environment variable               |
| -------------- | ------------------------------------ | ---------------------------------- |
| `github_token` | GitHub token for pushing CI branches | `SEAPLANE_CI_GITHUB_TOKEN` env var |

Token lookup order is `SEAPLANE_CI_GITHUB_TOKEN`, `GITHUB_TOKEN`, then the
`github_token` file.
Empty environment variables are skipped. Local Make wrappers pass the selected
token into containers as `SEAPLANE_CI_GITHUB_TOKEN`; if no token variable is set,
they fetch `/ephemeral-provider/github-token` from SSM Parameter Store.

The provider also expects AWS CLI profiles `rrp-central`, `rrp-rc`, and `rrp-mc` to be available via `AWS_CONFIG_FILE`. See the [AWS Profiles](../README.md#aws-profiles) section in the CI README for details.

## Direct Usage

```bash
# Requires uv (https://docs.astral.sh/uv/)

# Provision (generates a random ID and prints it — pass it to teardown/resync)
./ci/ephemeral-provider/main.py --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Provision with an explicit ID (use directly in prefix, no hashing)
./ci/ephemeral-provider/main.py --id abc123 --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Teardown (same --id)
./ci/ephemeral-provider/main.py --teardown --id abc123 --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Start RC/MC teardown without waiting for cluster destruction
./ci/ephemeral-provider/main.py --teardown-fire-and-forget --id abc123 --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Teardown after updating the CI branch from --branch (same as make ephemeral-teardown RESYNC=1)
./ci/ephemeral-provider/main.py --teardown --resync --id abc123 --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Resync and resume a failed provisioning run using the existing ephemeral branch
./ci/ephemeral-provider/main.py --resume --resync-before-resume --id abc123 --repo owner/repo --branch my-feature --eph-branch eph-abc123-my-feature-ci --creds-dir /path/to/credentials

# Resume without resyncing the existing ephemeral branch
./ci/ephemeral-provider/main.py --resume --id abc123 --repo owner/repo --branch my-feature --eph-branch eph-abc123-my-feature-ci --creds-dir /path/to/credentials

# Resync (rebase ephemeral branch onto latest source branch, same --id)
./ci/ephemeral-provider/main.py --resync --id abc123 --repo owner/repo --branch my-feature --creds-dir /path/to/credentials
```

Teardown starts the RC and all MC destroy executions before waiting, so cluster destruction runs concurrently. `--teardown` waits for every execution to succeed before deleting the cluster pipelines/projects and shared bootstrap resources. `--teardown-fire-and-forget` exits after starting all destroy executions, without waiting for cluster destruction or deleting those pipeline/bootstrap resources; run a full teardown later to complete cleanup.

## Overrides

Two mechanisms let you customize an ephemeral environment at provision time:

### `--override-dir`

Replaces the entire `config/ephemeral/` directory with a local directory of YAML files. Use this to swap the region, change cluster sizing, or provide a fully custom environment config. Re-applied on `--resync` so config changes are picked up alongside code changes.

```bash
./ci/ephemeral-provider/main.py --override-dir ./my-overrides/ ...
```

Also settable via `EPHEMERAL_OVERRIDE_DIR` env var.

### `--provision-override-file`

Deep-merges a YAML fragment into a specific file in the repo before the ephemeral branch is committed. Useful for surgical changes like overriding a single Helm value without replacing the whole file. Only applied during provision (not resync).

```bash
./ci/ephemeral-provider/main.py \
  --provision-override-file argocd/config/regional-cluster/platform-api/values.yaml:override.yaml \
  ...
```

Can be specified multiple times. Format is `<target-path>:<override-file>` where target path is relative to the repo root. Merge rules:

- Dicts are merged recursively
- Lists of dicts are matched by `name` key (matched items are merged, unmatched are appended)
- Scalars and plain lists are replaced

## Modules

| Module              | Description                                                                  |
| ------------------- | ---------------------------------------------------------------------------- |
| `main.py`           | CLI entrypoint — parses args, runs provision, resume, teardown, or resync    |
| `orchestrator.py`   | Top-level orchestration logic for provision, resume, and teardown workflows  |
| `aws.py`            | AWS credential management and session helpers                                |
| `git.py`            | Git operations for ephemeral branch creation, rendering, and resync (rebase) |
| `codepipeline.py`   | CodePipeline execution monitoring and underlying CodeBuild status validation |
| `codebuild_logs.py` | CloudWatch log fetching and formatting for CodeBuild projects                |
| `yaml_utils.py`     | YAML deep-merge utilities for applying provision overrides                   |
