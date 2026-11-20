# AWS Account Cleanup (Janitor)

The ephemeral tests create AWS resources across multiple accounts. Teardown relies on `terraform destroy`, which can fail and leak resources. To clean up leaked resources, a scheduled [aws-nuke](https://github.com/ekristen/aws-nuke) job runs in each minted CI / ephemeral account.

## Configuration

`aws-nuke-config-v2.yaml` is the nuke configuration. It is account-agnostic: the janitor appends an `accounts:` block for the account it runs in at runtime. It defines:

- **Regions** to scan (us-east-1 + global)
- **Preservation rules** — resources that must survive cleanup, mostly via the `aws-nuke=skip` and `platform-janitor/lifecycle=ignore` tags, plus AWS/SSO/org-managed roles by name

Everything not matched is deleted.

## Deployment

The janitor is provisioned per account by the `aws-nuke` Terraform module in [rosa-seaplane-internal](https://github.com/openshift-online/rosa-seaplane-internal) (`infra/modules/aws-nuke`). It downloads this config from `main` at runtime, so changes take effect on the next scheduled run after merge.

## Modifying preservation rules

Edit `aws-nuke-config-v2.yaml`. Prefer tagging resources with `aws-nuke=skip` over adding name-based filters.
