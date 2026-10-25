# Pipeline-Based Cluster Lifecycle Management

**Last Updated Date**: 2026-09-22

> Historical architecture. The modules, paths, and commands below describe the previous Terraform-managed pipeline hierarchy and are not instructions for the current checkout. See [CodePipeline Cluster Lifecycle](codepipeline-cluster-lifecycle.md) for the current design and migration requirements.

## Summary

The previous ROSA Seaplane architecture used a central pipeline-provisioner to dynamically create and manage Terraform-owned per-cluster CodePipelines from declarative configuration files across multiple AWS accounts and regions.

## Architecture Overview

### Three-Tier Pipeline Hierarchy

```mermaid
graph TB
    subgraph "Layer 1: Meta-Pipeline"
        PP[Pipeline Provisioner<br/>CodePipeline]
    end

    subgraph "Layer 2: Cluster Pipelines"
        RC1[Regional Cluster Pipeline<br/>us-east-1]
        RC2[Regional Cluster Pipeline<br/>eu-west-1]
        MC1[Management Cluster Pipeline<br/>mc01-us-east-1]
        MC2[Management Cluster Pipeline<br/>mc01-eu-west-1]
    end

    subgraph "Layer 3: Infrastructure"
        I1[EKS Cluster<br/>VPC, RDS, etc.]
        I2[EKS Cluster<br/>VPC, RDS, etc.]
        I3[EKS Cluster<br/>VPC, RDS, etc.]
        I4[EKS Cluster<br/>VPC, RDS, etc.]
    end

    PP -->|Creates/Manages| RC1
    PP -->|Creates/Manages| RC2
    PP -->|Creates/Manages| MC1
    PP -->|Creates/Manages| MC2

    RC1 -->|Provisions| I1
    RC2 -->|Provisions| I2
    MC1 -->|Provisions| I3
    MC2 -->|Provisions| I4

    style PP fill:#f9d5e5
    style RC1 fill:#eeeeee
    style RC2 fill:#eeeeee
    style MC1 fill:#eeeeee
    style MC2 fill:#eeeeee
    style I1 fill:#d5e1f9
    style I2 fill:#d5e1f9
    style I3 fill:#d5e1f9
    style I4 fill:#d5e1f9
```

### Event Triggers

```mermaid
flowchart LR
    subgraph events ["Events"]
        direction TB
        TF["terraform apply<br/>central-account-bootstrap/"]
        G1["git push<br/>deploy/**"]
        G2["git push<br/>deploy/‹env›/‹region›/**"]
        G3["git push<br/>deploy/‹env›/‹region›/pipeline-management-cluster-*-inputs/**"]
    end

    subgraph pipelines ["CodePipelines"]
        direction TB
        PP["pipeline-provisioner/"]
        RC_PIPE["pipeline-regional-cluster/"]
        MC_PIPE["pipeline-management-cluster/"]
    end

    TF -->|one-time setup| PP
    G1 -->|triggers| PP
    PP -->|"reads pipeline-provisioner-inputs/regional-cluster.json<br/>creates pipeline"| RC_PIPE
    PP -->|"reads pipeline-provisioner-inputs/management-cluster-*.json<br/>creates pipeline"| MC_PIPE
    G2 -->|triggers| RC_PIPE
    G3 -->|triggers| MC_PIPE

    style TF fill:#fff3e0,stroke:#e6a23c
    style G1 fill:#fff3e0,stroke:#e6a23c
    style G2 fill:#fff3e0,stroke:#e6a23c
    style G3 fill:#fff3e0,stroke:#e6a23c
    style PP fill:#e0f0ff,stroke:#4a90d9
    style RC_PIPE fill:#e0f0ff,stroke:#4a90d9
    style MC_PIPE fill:#e0f0ff,stroke:#4a90d9
```

**Layer 1 - Pipeline Provisioner (Meta-Pipeline)**:

- Single CodePipeline in central account
- **Bootstrap (Manual)**: Created once via `./scripts/bootstrap-central-account.sh`
- **Runtime (Automatic)**: Triggers on git push to `deploy/` or pipeline config changes
- Stages: Source → Build-Platform-Image → Provision
- The Provision stage runs `scripts/provision-pipelines.sh`, which reads `deploy/` and dynamically creates/updates/deletes Layer 2 pipelines

**Layer 2 - Cluster Pipelines**:

- One CodePipeline per cluster (RC or MC)
- Each pipeline provisions/manages a single cluster's infrastructure
- Is idempotent and can run in normal or destroy mode
- Runs in central account, stores terraform state in the target account, and deploys to target accounts
- RC stages: Source → Deploy → Bootstrap-ArgoCD
- MC stages: Source → Deploy → Bootstrap-ArgoCD → Register

**Layer 3 - Infrastructure**:

- Actual AWS resources (EKS, VPC, RDS, etc.)
- Managed by Layer 2 pipelines via Terraform
- Deployed in target accounts (separate from central account)

### Configuration Flow

```mermaid
graph LR
    A[config.yaml] -->|scripts/render.py| B[deploy/ directory<br/>for env-region]
    B --> C[regional.json]
    B --> D[management/*.json]
    B --> E[argocd/*-values.yaml]

    C --> F[Pipeline Provisioner]
    D --> F

    F -->|Reads configs| G[Creates Regional<br/>Cluster Pipeline]
    F -->|Reads configs| H[Creates Management<br/>Cluster Pipeline]

    G -->|terraform apply| I[Regional Cluster<br/>Infrastructure]
    H -->|terraform apply| J[Management Cluster<br/>Infrastructure]

    style A fill:#f9d5e5
    style B fill:#eeeeee
    style F fill:#d5f9e5
    style G fill:#d5e1f9
    style H fill:#d5e1f9
```

1. **config.yaml** - Single source of truth for all deployments
2. **scripts/render.py** - Processes config.yaml, generates environment-specific configs
3. **deploy/** - Generated directory structure with per-region/per-cluster configs and helm chart values files
4. **Pipeline Provisioner** - Reads `deploy/` structure, creates/updates pipelines
5. **Cluster Pipelines** - Read their own configs from `deploy/<env>/<region>/` and provision infrastructure

## Layer 1: Pipeline Provisioner (Meta-Pipeline)

### Purpose

The pipeline-provisioner is a "meta-pipeline" that manages other pipelines. It's responsible for:

- **Creating** new cluster pipelines when new regions/clusters are added to config.yaml
- **Updating** existing pipelines when configuration changes
- **Deleting** pipelines when clusters are marked for deletion

### Bootstrap (One-Time)

The pipeline-provisioner must be created once manually:

```bash
GITHUB_REPOSITORY=openshift-online/rosa-seaplane \
GITHUB_BRANCH=main \
TARGET_ENVIRONMENT=staging \
./scripts/bootstrap-central-account.sh
```

This runs `scripts/bootstrap-state.sh` (creates S3 state bucket) and then `terraform apply` on `terraform/config/central-account-bootstrap/` (creates the CodePipeline, CodeBuild project, CodeStar connection, IAM roles, and ECR repository).

After bootstrap, you must manually authorize the GitHub CodeStar connection in the AWS Console.

### Runtime Operation

After bootstrap, the pipeline-provisioner runs automatically when changes are pushed to `deploy/` or pipeline config directories. It executes `scripts/provision-pipelines.sh`, which scans `deploy/<env>/` for `regional.json` and `management/*.json` files and runs terraform to create/update/delete the corresponding cluster pipelines.

### State Management

**Pipeline definition state** is stored in the central account:

- **Bucket**: `terraform-state-${CENTRAL_ACCOUNT_ID}`
- **RC Key**: `pipelines/regional-${ENVIRONMENT}-${REGION_DEPLOYMENT}-${REGIONAL_ID}.tfstate`
- **MC Key**: `pipelines/management-${ENVIRONMENT}-${REGION_DEPLOYMENT}-${MANAGEMENT_ID}.tfstate`

This is the terraform state for the CodePipeline/CodeBuild resources themselves (not the cluster infrastructure).

See: `terraform/modules/pipeline-provisioner/`, `scripts/provision-pipelines.sh`

## Layer 2: Cluster Pipelines

Each cluster (regional or management) gets its own dedicated CodePipeline that manages that cluster's infrastructure lifecycle.

### Regional Cluster Pipeline

Provisions a Regional Cluster (EKS + VPC + RDS + Platform API).

- Stages: Source → Deploy → Bootstrap-ArgoCD
- Triggers on changes to `deploy/<env>/<region>/pipeline-regional-cluster-inputs/terraform.json`

See: `terraform/config/pipeline-regional-cluster/`, `terraform/config/regional-cluster/`

### Management Cluster Pipeline

Provisions a Management Cluster (EKS for hosting customer control planes).

- Stages: Source → Deploy → Bootstrap-ArgoCD → Register
- Triggers on changes to `deploy/<env>/<region>/pipeline-management-cluster-<cluster>-inputs/terraform.json`
- Deploys to management cluster account (may differ from regional account)
- The **Register** stage calls the Regional Cluster Platform API to register the Management Cluster as a known consumer, passing:
  - `cluster_id`, `management_id`, `region`, `alias` — cluster identity
  - `cloudfront_url` — the OIDC issuer base URL (sourced from the MC's HyperShift CloudFront domain)

See: `terraform/config/pipeline-management-cluster/`, `terraform/config/management-cluster/`

### State Management

**Infrastructure state** is stored in target accounts:

- **Bucket**: `terraform-state-${TARGET_ACCOUNT_ID}`
- **Regional Key**: `regional-cluster/${CLUSTER_ID}.tfstate`
- **Management Key**: `management-cluster/${CLUSTER_ID}.tfstate`

State is co-located with resources for security isolation and simplified disaster recovery.

## Cluster Lifecycle

### 1. Cluster Creation

```mermaid
sequenceDiagram
    participant SRE
    participant Git as Git Repository
    participant PP as Pipeline Provisioner
    participant CP as Cluster Pipeline
    participant Infra as Infrastructure

    SRE->>Git: 1. Update config.yaml (add region)
    SRE->>SRE: 2. Run scripts/render.py
    SRE->>Git: 3. Commit deploy/ files
    SRE->>Git: 4. Push to main branch

    Git->>PP: 5. Trigger pipeline-provisioner
    PP->>PP: 6. Detect new regional.json
    PP->>CP: 7. terraform apply (create pipeline)

    Note over CP: New pipeline created

    CP->>CP: 8. Auto-trigger (new pipeline)
    CP->>Infra: 9. Deploy stage (terraform apply)
    Infra->>Infra: 10. EKS cluster created
    Infra->>Infra: 11. VPC, RDS created
    Infra->>Infra: 12. ArgoCD bootstrapped

    Note over Infra: Cluster ready
```

### 2. Cluster Update

```mermaid
sequenceDiagram
    participant SRE
    participant Git as Git Repository
    participant CP as Cluster Pipeline
    participant Infra as Infrastructure

    SRE->>Git: 1. Update config.yaml (change values)
    SRE->>SRE: 2. Run scripts/render.py
    SRE->>Git: 3. Commit deploy/ files
    SRE->>Git: 4. Push to main branch

    Git->>CP: 5. Trigger cluster pipeline
    CP->>Infra: 6. Deploy stage (terraform apply)
    Infra->>Infra: 7. Update resources

    Note over Infra: Cluster updated
```

Updates are triggered directly on the cluster pipeline (no need for the pipeline-provisioner to run first, unless pipeline configuration itself changed).

### 3. Cluster Deletion (Two-Phase)

```mermaid
sequenceDiagram
    participant SRE
    participant Git as Git Repository
    participant PP as Pipeline Provisioner
    participant CP as Cluster Pipeline
    participant Infra as Infrastructure

    SRE->>Git: 1. Update config.yaml (delete: true)
    Note over SRE: Can set at regional or management level
    SRE->>SRE: 2. Run scripts/render.py
    SRE->>Git: 3. Commit deploy/ files
    SRE->>Git: 4. Push to main branch

    Git->>PP: 5. Trigger pipeline-provisioner

    rect rgb(255, 200, 200)
    Note over PP,Infra: Phase 1: Infrastructure Destruction
    PP->>CP: 6. Trigger cluster pipeline with IS_DESTROY=true
    CP->>Infra: 7. terraform destroy
    Infra-->>CP: 8. Resources deleted
    end

    rect rgb(200, 200, 255)
    Note over PP,CP: Phase 2: Pipeline Cleanup
    PP->>CP: 9. terraform destroy (pipeline)
    CP-->>PP: 10. Pipeline deleted
    end

    Note over Infra: Cluster gone
```

**Two-phase deletion** ensures infrastructure is destroyed before the pipeline that manages it. This preserves state file access during destruction and prevents orphaned resources.

**Deletion granularity**: The `delete: true` flag can be set at two levels:

- **Regional Cluster Level** (`regional.json`): Destroys the entire Regional Cluster and all associated infrastructure
- **Management Cluster Level** (`management/<mc>.json`): Destroys only that specific Management Cluster; the Regional Cluster and other MCs remain intact

The entire deletion flow is automatic and Git-driven - no manual intervention required.

## Design Decisions

- **Hierarchical meta-pipeline over monolithic or manual**: Isolates failures to single regions, enables parallelism, scales to hundreds of clusters, and keeps pipeline management Git-driven
- **Git-driven configuration over API or direct terraform**: Provides audit trail, peer review via PRs, rollback via git revert, and consistent declarative state
- **Separate state per account**: Pipeline state in central account (co-located with pipeline resources), infrastructure state in target accounts (co-located with infra). Provides security isolation and simplifies disaster recovery
- **Multi-stage pipelines**: Separates infrastructure provisioning from application bootstrap, giving independent failure domains and clear debugging boundaries

## Key File Reference

### Configuration

| File                                     | Purpose                                                 |
| ---------------------------------------- | ------------------------------------------------------- |
| `config.yaml`                            | Single source of truth for all deployments              |
| `scripts/render.py`                      | Generates environment-specific configs from config.yaml |
| `deploy/<env>/<region>/terraform/*.json` | Generated per-cluster pipeline configs                  |

### Pipeline Provisioner (Layer 1)

| File                                          | Purpose                                             |
| --------------------------------------------- | --------------------------------------------------- |
| `terraform/config/central-account-bootstrap/` | One-time bootstrap terraform config                 |
| `terraform/modules/pipeline-provisioner/`     | Pipeline provisioner definition and buildspecs      |
| `scripts/bootstrap-central-account.sh`        | One-time bootstrap script                           |
| `scripts/provision-pipelines.sh`              | Reads deploy/ and creates/updates/deletes pipelines |

### Cluster Pipelines (Layer 2)

| File                                            | Purpose                               |
| ----------------------------------------------- | ------------------------------------- |
| `terraform/config/pipeline-regional-cluster/`   | RC pipeline definition and buildspecs |
| `terraform/config/pipeline-management-cluster/` | MC pipeline definition and buildspecs |
| `terraform/config/regional-cluster/`            | RC infrastructure terraform module    |
| `terraform/config/management-cluster/`          | MC infrastructure terraform module    |

### State Locations

| State             | Bucket                                  | Key Pattern                                                                         |
| ----------------- | --------------------------------------- | ----------------------------------------------------------------------------------- |
| RC pipeline       | `terraform-state-${CENTRAL_ACCOUNT_ID}` | `pipelines/regional-${ENVIRONMENT}-${REGION_DEPLOYMENT}-${REGIONAL_ID}.tfstate`     |
| MC pipeline       | `terraform-state-${CENTRAL_ACCOUNT_ID}` | `pipelines/management-${ENVIRONMENT}-${REGION_DEPLOYMENT}-${MANAGEMENT_ID}.tfstate` |
| RC infrastructure | `terraform-state-${TARGET_ACCOUNT_ID}`  | `regional-cluster/${CLUSTER_ID}.tfstate`                                            |
| MC infrastructure | `terraform-state-${TARGET_ACCOUNT_ID}`  | `management-cluster/${CLUSTER_ID}.tfstate`                                          |
