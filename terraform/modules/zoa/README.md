# ZOA Data Layer Module

Manages the shared ZOA data layer deployed once per region in the Regional Cluster (RC) account.

## Resources

- **DynamoDB** — Three tables (all KMS-encrypted, TTL default 365d via `DYNAMODB_TTL_DAYS` on writers):
  - **Executions** — PK `executionId`; GSIs `target-status-index`, `date-bucket-index`
  - **Audit** — PK `accountId`, SK `timestamp`; GSI `date-bucket-index`
  - **Boundary sessions** — PK `sessionId`; GSIs `task-id-index`, `target-status-index` (reaper), `date-bucket-index`
- **S3** — Artifact bucket for TA output, logs, and large files
- **KMS** — Regional CMK for DynamoDB, S3, boundary/Lambda CloudWatch Logs, and ECS Exec encryption (see `kms.tf`)
- **IAM** — Uploader role (for async Job S3 uploads), data-access role (for MC cross-account access)
- **Container images** — The Lambda image is mirrored from Quay into this region's ECR repository with `skopeo`; Lambda functions in the RC and MCs pull from that repository. Runner and Boundary images are pulled directly from their Quay source references, with no ECR mirror.

Boundary **targets** are registered in RC SSM (`/zoa/targets/<deployment>/<cluster>`): RC via `zoa-lambda`; MC via `terraform/config/mc-zoa-target-ssm-provisioning/` (MC pipeline). See `dynamodb.tf`.

## Cross-Account Access Model

MC Lambdas access RC data by assuming IAM roles in the RC account:

- `data_access` role: MC Lambdas assume this for DynamoDB (executions, audit, sessions), S3, and KMS. Lambdas receive table names via environment variables.
- `uploader` role: MC Lambdas assume this for scoped S3 upload credentials in async Jobs

`data_access` and `uploader` trust MC `*-zoa-lambda` roles via OU path + `ArnLike` conditions (parallel RC/MC deploy — IAM does not allow explicit cross-account role ARNs in trust until those roles exist). S3/KMS key policies use the same OU model. MC SSM target rows are not managed here — see `mc-zoa-target-ssm-provisioning`.

RC Access Lambda assumes per-MC boundary roles using `management_clusters` account IDs and `*-zoa-boundary-*` role name patterns (`module.zoa-access`). MC boundary trust uses `zoa_access_lambda_role_arn` from RC Terraform outputs (polled in `provision-infra-mc.sh`).
