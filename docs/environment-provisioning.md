# Provision a New Environment

Set up shared central resources and one CodePipeline with a combined CodeBuild worker per Regional or Management Cluster. The cluster builds provision infrastructure, bootstrap ArgoCD, and establish kube-applier connectivity.

For an existing environment using Terraform-managed pipelines, review [migration from the previous pipeline architecture](design/codepipeline-cluster-lifecycle.md#migration-from-terraform-managed-pipelines) before running bootstrap.

---

## 1. Prerequisites

### Required tools

```bash
aws --version
terraform --version
python --version
uv --version
jq --version
```

### 1.1 Required AWS accounts

Three accounts are needed:

- **Central** — hosts the CodePipeline infrastructure
- **Regional** — hosts the Regional Infrastructure (including EKS Regional Cluster)
- **Management** — hosts the Management Infrastructure (including EKS Management Cluster)

The Regional and Management accounts must allow assume-role from Central (see 1.2).

Bootstrap authorizes the exact account IDs and `aws.child_admin_role_name` from
the rendered configuration, resolving SSM account references in the Central
account. The RC worker can assume its configured Regional account role; MC
workers can assume the configured Management account roles and the Regional
account role needed for registration and cleanup. Update the configuration and
rerun bootstrap before using a new target account or administrator role.

### 1.2 Enable assume-role

Add the Central account to the `OrganizationAccountAccessRole` trust policy in both the Regional and Management accounts:

If `aws.child_admin_role_name` selects another role, use that role below.

```bash
CENTRAL_ACCOUNT_ID="123456789012"
ROLE_NAME="OrganizationAccountAccessRole"

# Get current trust policy and add Central account
aws iam get-role --role-name $ROLE_NAME --query 'Role.AssumeRolePolicyDocument' --output json | \
  jq --arg account "arn:aws:iam::${CENTRAL_ACCOUNT_ID}:root" \
  '.Statement[0].Principal.AWS |= (if type == "array" then (. + [$account] | unique) else [., $account] | unique end)' \
  > /tmp/trust-policy-updated.json

aws iam update-assume-role-policy \
  --role-name $ROLE_NAME \
  --policy-document file:///tmp/trust-policy-updated.json

# Repeat for the Management account (switch credentials first)
```

## 2. Configure the Region

> **Skip this step** if reusing an existing environment/region configuration.
>
> **DNS prerequisite**: If this environment will have DNS enabled (`dns.domain` set), the environment zone (e.g. `int0.rosa.devshift.net`) must exist in the central account first. This is a one-time setup per environment — see [DNS Architecture: Testing Strategy](design/dns-architecture.md#testing-strategy) for details.

### 2.1 Store account IDs in SSM

Push the Regional and Management account IDs to SSM Parameter Store in the Central account. The default config uses the resolver URI `ssm:///infra/<environment>/<region>/account_id` to look up account IDs at runtime; the actual SSM parameter name stored in Parameter Store is `/infra/<environment>/<region>/account_id` (the `ssm://` prefix is stripped by the resolver).

```bash
ENV=my-env
REGION=us-east-1
RC_ACCOUNT_ID=123456789012    # Regional Cluster account
MC_ACCOUNT_ID=987654321098    # Management Cluster account

aws ssm put-parameter --name "/infra/${ENV}/${REGION}/account_id" \
  --value "$RC_ACCOUNT_ID" --type String
aws ssm put-parameter --name "/infra/${ENV}/${REGION}/mc01/account_id" \
  --value "$MC_ACCOUNT_ID" --type String
```

### 2.2 MC OU path SSM parameter (auto-provisioned)

The DNS zone operator trust policy uses `aws:PrincipalOrgPaths` to allow MC accounts to assume the cross-account role. The OU path is stored in SSM Parameter Store **in the RC account** at `/infra/<environment>/<region>/ou-path`.

**This parameter is automatically created** by `rosa-seaplane-internal/infra/modules/account-config` when the RC account is minted. No manual creation is needed.

Example path: `/infra/stage/us-east-1/ou-path`

### 2.3 Add the environment configuration

Create a new region config file at `config/<environment>/<region>.yaml`. This inherits defaults from `config/defaults.yaml` — override only what differs. Environment-level defaults can be set in `config/<environment>/defaults.yaml`.

```yaml
# config/my-env/us-east-1.yaml
provision_mcs:
  mc01: {}
```

To enable the bastion:

```yaml
# config/my-env/us-east-1.yaml
regional_cluster:
  enable_bastion: true
management_cluster_defaults:
  enable_bastion: true
provision_mcs:
  mc01: {}
```

### 2.4 Render and commit

```bash
uv run scripts/render.py
ls deploy/<environment>/<region>/    # verify pipeline-*-inputs/ and argocd-* outputs exist

git add config/ deploy/
git commit -m "Add <environment>/<region> configuration"
git push origin <your-branch>
```

---

## 3. Bootstrap Central Resources and Cluster Pipelines

Switch to your Central AWS profile. Bootstrap applies Terraform for shared resources (connection, IAM roles, artifact bucket, and platform-image builder), ensures the platform image exists, and invokes `scripts/provision-cluster-resources.sh` to create or update each cluster's CodeBuild project and CodePipeline through AWS APIs. There is no pipeline-provisioner meta-pipeline.

### 3.1 Run the bootstrap script

```bash
export AWS_PROFILE=<central-profile>

GITHUB_REPOSITORY=<org>/rosa-seaplane \
GITHUB_BRANCH=<branch> \
TARGET_ENVIRONMENT=<environment> \
./scripts/bootstrap-central-account.sh
```

Defaults to `openshift-online/rosa-seaplane` on `main` if not specified.

### 3.2 Accept the CodeStar connection

The bootstrap script creates a CodeStar connection and polls until it becomes AVAILABLE. While it waits:

1. Open the [AWS CodeStar Connections console](https://console.aws.amazon.com/codesuite/settings/connections) in the Central account
2. Find the **Pending** connection and click **Update pending connection**
3. Click **Install a new app**, then install the GitHub App on the repository you are targeting — this is required for the GitOps pipeline triggers to pick up changes

The script proceeds automatically once the connection is authorized. Newly created CodePipelines start their first execution automatically. Bootstrap returns after reconciling their definitions; check the RC/MC executions for completion before verification.

### 3.3 Reconcile cluster definitions

Push rendered configuration changes to the tracked branch. Existing pipelines run when their branch and file filters match. Adding a cluster or changing a CodeBuild/CodePipeline definition also requires rerunning bootstrap with the same environment and branch so the per-cluster resources are reconciled. Updating an existing pipeline definition alone does not start an execution; use the [manual trigger](#trigger-pipelines-via-cli) when needed.

Use `cluster_naming` to customize project names. The lifecycle commands also
support dynamically created MCs in accounts already authorized by bootstrap;
they do not require names beginning with `mc` or containing `regional`. Adding a
new target account or changing its administrator role requires a bootstrap rerun
to update authorization before creating its pipeline.

Cluster build logs are grouped under
`/aws/codebuild/<pipeline-role-name>/regional` or
`/aws/codebuild/<pipeline-role-name>/management` in CloudWatch. Use the build's log
stream to distinguish individual clusters and executions.

## 4. Verification

### 4.1 Connect to the bastion

Requires `enable_bastion: true` in config. Use the respective account's credentials (Regional for the RC bastion, Management for the MC bastion):

```bash
# Connect to the regional cluster bastion
make int-bastion-rc    # or: make ephemeral-bastion-rc ID=<id>

# Connect to the management cluster bastion
make int-bastion-mc    # or: make ephemeral-bastion-mc ID=<id>
```

### 4.2 Verify ArgoCD applications

From the Regional Cluster bastion:

```bash
kubectl get applications -A
```

Expected output:

```
NAMESPACE   NAME                  SYNC STATUS   HEALTH STATUS
argocd      argocd                Synced        Healthy
argocd      seaplane            Synced        Healthy
argocd      monitoring          Synced        Healthy
argocd      platform-api        Synced        Healthy
argocd      root                Synced        Healthy
argocd      storageclass        Synced        Healthy
```

From the Management Cluster bastion:

```bash
kubectl get applications -A
```

Expected output:

```
NAMESPACE   NAME            SYNC STATUS   HEALTH STATUS
argocd      argocd          Synced        Healthy
argocd      cert-manager    Synced        Healthy
argocd      hypershift      Synced        Healthy
argocd      kube-applier    Synced        Healthy
argocd      monitoring      Synced        Healthy
argocd      root            Synced        Healthy
argocd      storageclass    Synced        Healthy
```

### 4.3 Verify the Platform API

From the Regional account, extract the API Gateway endpoint from the cluster's Terraform state. Use the `regional_id` from `deploy/<environment>/<region>/pipeline-regional-cluster-inputs/terraform.json`:

```bash
export AWS_PROFILE=<regional-profile>
cd terraform/config/regional-cluster/

terraform init -reconfigure \
  -backend-config="bucket=terraform-state-<REGIONAL_ACCOUNT_ID>-<region>" \
  -backend-config="key=regional-cluster/<regional_id>.tfstate" \
  -backend-config="region=<region>"

terraform output -raw api_test_command
# Then run the output command, e.g.:
# awscurl --service execute-api --region us-east-2 https://<id>.execute-api.<region>.amazonaws.com/prod/v0/live
```

> **Note:** The API Gateway accepts requests from any authenticated AWS principal. Authorization is enforced by the Platform API backend — only accounts registered with the Platform API (starting with the bootstrap account) receive a successful response.

---

## Appendix

### Register additional accounts

The bootstrap account (seeded by Terraform via the `bootstrap_accounts` variable) is the only account authorized to call the Platform API initially. To authorize additional AWS accounts, the first invocation must be made from the bootstrap account:

```bash
awscurl -X POST $API_GATEWAY_URL/api/v0/accounts \
    --service execute-api --region <region> \
    -H "Content-Type: application/json" \
    -d '{"accountId": "<AWS_ACCOUNT_ID>", "privileged": true}'
```

> **Note:** The `API_GATEWAY_URL` can be obtained from `terraform output -raw api_gateway_invoke_url` in the regional cluster terraform config. The `awscurl` request must be signed with credentials from an already-authorized account (initially, the bootstrap account).

### Trigger pipelines via CLI

Pipelines are triggered automatically by Git pushes, but you can also trigger them manually. Requires Central account credentials.

```bash
export AWS_PROFILE=<central-profile>

# List available pipelines
aws codepipeline list-pipelines \
  --query 'pipelines[*].[name,created,updated]' \
  --output table

# Trigger a specific pipeline (fetches latest commit)
aws codepipeline start-pipeline-execution --name <regional_id>-pipeline
```
