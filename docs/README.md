# ROSA Seaplane

## Overview

The ROSA Seaplane project is a strategic initiative to redesign the architecture of Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Planes (HCP). This new architecture moves away from a globally-centralized management model to a regionally-distributed approach, where each AWS region operates independently with its own control plane infrastructure.

The goal is to improve reliability, reduce dependencies on global services, and provide customers with lower-latency access to cluster management through regional API endpoints.

## Architecture at a Glance

The architecture consists of three layers within each region:

1. **Regional Cluster (RC)** - EKS-based cluster running core services (Platform API, seaplane-operator, kube-applier, ArgoCD, Tekton)
2. **Management Clusters (MC)** - EKS clusters hosting customer Hosted Control Planes via HyperShift
3. **Customer Hosted Clusters** - ROSA HCP clusters with control planes in MCs and workers in customer accounts

## Documentation Index

### Design Decisions

Detailed architecture and rationale for key technical decisions:

| Document                                                                             | Topic                                                                     |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| [Alerting Architecture](design/alerting-architecture.md)                             | Fan-out alert routing (AlertManager, PagerDuty, SNS)                      |
| [AWS IAM Hosted Cluster Auth](design/aws-iam-hosted-cluster-authentication.md)       | AWS IAM authentication for hosted clusters (experimental)                 |
| [DNS Architecture](design/dns-architecture.md)                                       | Hierarchical DNS with zone shards, `deployment_name`, DNSSEC chain        |
| [ECS Fargate Bootstrap](design/fully-private-eks-bootstrap.md)                       | How fully private EKS clusters are bootstrapped via ECS                   |
| [FIPS-Only EKS Compute](design/fips-eks-compute.md)                                  | FIPS NodeClass/NodePool strategy for FedRAMP workload nodes               |
| [GitOps Cluster Configuration](design/gitops-cluster-configuration.md)               | ApplicationSet pattern, progressive deployment, config modes              |
| [Infrastructure Logging](design/infrastructure-logging.md)                           | AWS CloudWatch log groups, KMS encryption, Grafana access                 |
| [Karpenter Node Provisioning](design/karpenter-node-provisioning.md)                 | Self-managed Karpenter IAM roles, Pod Identity, SQS interruption handling |
| [Kube-Applier Architecture](design/kube-applier-architecture.md)                     | DynamoDB-backed resource distribution to MCs via GSI polling              |
| [Lifecycle Alert Silencing](design/lifecycle-alert-silencing.md)                     | Alertmanager silences for cluster lifecycle phases                        |
| [Logging Platform](design/logging-platform.md)                                       | Application-level log collection (Vector + Loki)                          |
| [MC Metrics Remote Write](design/mc-metrics-remote-write.md)                         | MC-to-RC metrics forwarding via RHOBS API Gateway                         |
| [Monitoring Platform](design/monitoring-platform.md)                                 | Metrics pipeline (Prometheus + Thanos)                                    |
| [Pipeline-Based Lifecycle](design/pipeline-based-lifecycle.md)                       | Historical multi-stage pipeline architecture                              |
| [Rate Limiting](design/rate-limiting-architecture.md)                                | Per-account rate limiting for Platform API                                |
| [Regional Account Minting](design/regional-account-minting.md)                       | AWS account structure and minting pipelines                               |
| [Regional Control Plane Architecture](design/regional-control-plane-architecture.md) | Operator + PostgreSQL control plane (seaplane-operator, seaplane-db)      |
| [Regional OIDC Ownership](design/regional-oidc-ownership.md)                         | Shared OIDC bucket per region, cross-account MC writes                    |
| [Spec-to-PR Agent](design/spec-to-pr-agent.md)                                       | AI agent workflow for spec-driven implementation                          |
| [SRE UI Access](design/sre-ui-access.md)                                             | ALB + OIDC access to SRE UIs replacing SSM port-forward                   |
| [CodePipeline Cluster Lifecycle](design/codepipeline-cluster-lifecycle.md)           | Per-cluster CodePipeline orchestration with retained CodeBuild workers    |
| [CodeBuild Provisioning](design/codebuild-optimization.md)                           | Superseded standalone-CodeBuild design                                    |
| [Terraform Resource Adoption](design/terraform-resource-adoption.md)                 | Idempotent import of auto-created AWS resources into Terraform            |
| [Testing Strategy](design/testing-strategy.md)                                       | Ephemeral and long-lived test environments                                |
| [Thanos Metrics Infrastructure](design/thanos-metrics-infrastructure.md)             | Thanos S3 storage, operator, and Pod Identity setup                       |
| [ZOA Architecture](design/zoa-architecture.md)                                       | Zero Operator Access — Lambda architecture, Terraform modules, security   |
| [C4 Architecture Model](design/c4/README.md)                                         | Interactive Structurizr C4 model of the regional architecture             |

### How-To Guides

| Document                                                             | Topic                                          |
| -------------------------------------------------------------------- | ---------------------------------------------- |
| [Provision a New Environment](environment-provisioning.md)           | Pipeline-based environment provisioning        |
| [Provisioning a Development Environment](development-environment.md) | Ephemeral dev environments                     |
| [Provision a Hosted Cluster](hostedcluster-provisioning.md)          | Create and access a ROSA HCP cluster           |
| [Hosted Cluster Teardown](hostedcluster-teardown.md)                 | Admin-only manual teardown and force cleanup   |
| [Adding Alerting Rules](adding-alerting-rules.md)                    | Platform alerting and recording rules          |
| [Platform API Authorization](platform-api-authorization.md)          | Configure Cedar authorization for Platform API |
| [Konflux onboarding](konflux-onboarding.md)                          | Onboard Seaplane images to Konflux CI/CD       |

### Reference

| Document                                                  | Topic                                     |
| --------------------------------------------------------- | ----------------------------------------- |
| [FAQ](FAQ.md)                                             | Architecture Q&A and pending decisions    |
| [ArgoCD Configuration](../argocd/README.md)               | ArgoCD setup, config modes, adding charts |
| [CI](../ci/README.md)                                     | E2E testing, ephemeral environments       |
| [Terraform Configurations](../terraform/config/README.md) | Pipeline architecture and cluster configs |

### Terraform Module Documentation

Each module has its own README with usage, inputs, outputs, and architecture:

- [`eks-cluster`](../terraform/modules/eks-cluster/README.md) - Private EKS cluster with GitOps bootstrap
- [`ecs-bootstrap`](../terraform/modules/ecs-bootstrap/README.md) - ECS Fargate bootstrap infrastructure
- [`api-gateway`](../terraform/modules/api-gateway/README.md) - API Gateway with VPC Link to internal ALB
- [`bastion`](../terraform/modules/bastion/README.md) - Ephemeral bastion for private cluster access
- [`kube-applier`](../terraform/modules/kube-applier/README.md) - IAM and Pod Identity for the kube-applier controller on MCs
- [`kube-applier-dynamodb`](../terraform/modules/kube-applier-dynamodb/README.md) - DynamoDB tables and backend IAM role for kube-applier (RC account)
- [`seaplane-db`](../terraform/modules/seaplane-db/) - Aurora PostgreSQL for seaplane-operator cluster/nodepool state
- [`grafana-cloudwatch-logs`](../terraform/modules/grafana-cloudwatch-logs/) - IAM + Pod Identity for Grafana CloudWatch Logs datasources (RC primary + MC reader)
- [`aws-load-balancer-controller`](../terraform/modules/aws-load-balancer-controller/README.md) - IAM role and Pod Identity association for AWS Load Balancer Controller

### ArgoCD Helm Chart Documentation

- [`seaplane`](../argocd/config/regional-cluster/seaplane/) - Seaplane Operator (postgres-based cluster lifecycle controller)
- [`platform-api`](../argocd/config/regional-cluster/platform-api/README.md) - Platform API
- [`thanos`](../argocd/config/regional-cluster/thanos/) - Thanos platform resources (CRs, S3 secret, Pod Identity SA, ALB TargetGroupBinding) plus app-of-apps Application that installs the upstream operator
- [`thanos-operator`](../argocd/config/regional-cluster/thanos-operator/) - Thin wrapper chart that delivers the Thanos operator via OCI-packaged Helm subchart

## Scope

- This architecture is designed exclusively for **ROSA HCP** (Hosted Control Planes)
- ROSA Classic and OSD clusters are not part of this architecture
- All ROSA HCP clusters will eventually migrate to this regional architecture

## Current Status

This is an active development project. Some design decisions are still pending — see [FAQ](FAQ.md) for details on open questions.
