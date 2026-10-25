# Rebuild the Integration Environment

Tear down and re-provision the integration environment when it is unrecoverable through normal pipeline runs.

This procedure assumes the environment already uses the [current per-cluster CodePipeline architecture](../design/codepipeline-cluster-lifecycle.md). For legacy Terraform-managed pipelines, complete the documented migration planning first.

## Prerequisites

1. AWS Console access to the **central account** (hosts CodePipeline)
2. AWS Console or CLI access to the **RC and MC target accounts** (for manual cleanup of leftover resources)

## Procedure

The rebuild follows a teardown-then-provision cycle. MC must be torn down before RC because it depends on RC resources (IoT certificates, DNS zones).

```mermaid
sequenceDiagram
    participant Operator
    participant Console as AWS Console<br/>(Central Account)
    participant MC as MC Pipeline<br/>(mc01-pipeline)
    participant RC as RC Pipeline<br/>(regional-pipeline)
    Operator->>Console: Start MC pipeline (IS_DESTROY=true)
    Console->>MC: Trigger teardown
    MC-->>Console: Complete (may partially fail)
    Operator->>Console: Start RC pipeline (IS_DESTROY=true)
    Console->>RC: Trigger teardown
    RC-->>Console: Complete (may partially fail)
    Operator->>Console: Manually delete leftover resources
    Note over Operator,Console: Check RC and MC accounts for<br/>orphaned resources
    Operator->>Operator: Reconcile cluster definitions through bootstrap
    Operator->>Console: Start RC pipeline (IS_DESTROY=false)
    Console->>RC: Provision RC
    RC-->>Console: Complete
    Operator->>Console: Start MC pipeline (IS_DESTROY=false)
    Console->>MC: Provision MC
    MC-->>Console: Complete
    Operator->>Operator: Trigger nightly-integration to verify
```

### Step 1: Tear down the Management Cluster

1. Open the [AWS CodePipeline console](https://console.aws.amazon.com/codesuite/codepipeline/pipelines) in the **central account**.

2. Find the MC pipeline: `mc01-pipeline`. Suspend source-triggered executions during the rebuild so a push cannot race with teardown.

3. Click **Release change** (or **Start execution** in the pipeline detail view). When prompted for pipeline variables, set:

   ```text
   IS_DESTROY = true
   ```

4. Wait for the pipeline to complete. The teardown may partially fail due to dependency violations (e.g., RDS ENIs, EKS-managed resources). This is expected; leftover resources are cleaned up in Step 3.

### Step 2: Tear down the Regional Cluster

1. In the same CodePipeline console, find the RC pipeline: `regional-pipeline`. Suspend its source-triggered executions during the rebuild as well.

2. Start execution with:

   ```text
   IS_DESTROY = true
   ```

3. Wait for the pipeline to complete. As with the MC, partial failures are expected.

### Step 3: Clean up leftover resources

After both teardowns complete, the HyperShift config secret in the MC account will remain scheduled for deletion with a 30-day recovery window. This blocks re-provision because Terraform cannot create a secret while another with the same name is pending deletion. Force-delete it:

```bash
for secret in hypershift/mc01-config; do
  aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery --region us-east-1
done
```

RC secrets do not need manual cleanup (they use `recovery_window_in_days = 0`).

If the teardown failed more broadly, also check for other leaked resources (ENIs, EBS volumes, VPC components, EKS clusters) using [AWS Resource Explorer](https://resource-explorer.console.aws.amazon.com/) in each account.

### Step 4: Re-provision

Reconcile the current cluster definitions, then run the RC and MC pipelines:

1. Follow [central bootstrap](../environment-provisioning.md#3-bootstrap-central-resources-and-cluster-pipelines) with the integration environment's existing repository, branch, and resource prefix. This restores configured push triggers and creates or updates the per-cluster resources.

2. For existing pipelines, start `regional-pipeline` with `IS_DESTROY=false` and wait for it to succeed. A newly created pipeline starts automatically; monitor that execution instead of starting a duplicate.

3. Start `mc01-pipeline` with `IS_DESTROY=false`, or monitor its automatic creation execution. The MC build waits for regional prerequisites before completing bootstrap and registration.

4. Monitor both pipelines until they succeed.

   If the provision fails due to leftover resources from Step 3, delete the conflicting resources and re-trigger the failed pipeline.

## Post-Rebuild

### Update CI credentials

The RHOBS API Gateway uses a raw `execute-api` URL that changes on every rebuild (unlike the Platform API, which has a stable custom domain). Update the Prow vault secret so the nightly-integration job can reach Thanos and Loki:

1. Get the new RHOBS API Gateway URL from the Terraform state in the RC account:

   ```bash
   aws s3 cp s3://terraform-state-$(aws sts get-caller-identity --query Account --output text)-us-east-1/regional-cluster/regional.tfstate - \
     | jq -r '.outputs.rhobs_api_url.value'
   ```

2. Update the `rhobs_api_url` field in the Vault secret `selfservice/cluster-secrets-rosa-regional-platform-int/integration-creds` with the new URL.

### Verify the rebuild

1. Connect to the RC and MC bastions and verify ArgoCD applications are synced:

   ```bash
   make int-bastion-rc
   # On bastion:
   kubectl get applications -A
   ```

   All applications should show `Synced` and `Healthy`.

2. Test the Platform API:

   ```bash
   make int-shell
   # In shell:
   awscurl --service execute-api $API_URL/v0/live
   ```

   Expected response: `{"status":"ok"}`

3. Trigger the nightly-integration CI job to confirm end-to-end tests pass. Follow the [manual trigger instructions](../../ci/README.md#triggering-the-e2e-job-manually):

   ```bash
   curl -X POST \
       -H "Authorization: Bearer $(oc whoami -t)" \
       'https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/' \
       -d '{"job_name": "periodic-ci-openshift-online-rosa-seaplane-main-nightly-integration", "job_execution_type": "1"}'
   ```

## Reference

- [Provision a New Environment](../environment-provisioning.md) for the full provisioning guide
- [CI Jobs](../../ci/README.md) for CI job details and manual trigger instructions
- Pipeline buildspec scripts: [`scripts/buildspec/provision-infra-rc.sh`](../../scripts/buildspec/provision-infra-rc.sh), [`scripts/buildspec/provision-infra-mc.sh`](../../scripts/buildspec/provision-infra-mc.sh)
- Pipeline names are derived from `regional_id` and `management_id` in rendered `pipeline-provisioner-inputs/` files, constructed as `<id>-pipeline` by `scripts/provision-cluster-resources.sh`
