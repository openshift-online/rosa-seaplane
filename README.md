# rosa-seaplane

For the full architecture overview, see [docs/README.md](docs/README.md).

## PR Dashboard

A [PR dashboard](https://openshift-online.github.io/rosa-seaplane/pr-dashboard) shows open PRs across all platform repositories, grouped by label (`review-ready`, `discussion-needed`, or `needs-ok-to-test`) and source (bot PRs). An **IC Tasks** panel at the top surfaces actionable items at a glance: review-ready PRs missing assigned reviewers, and bot PRs awaiting `/ok-to-test`. It refreshes automatically every 10 minutes via GitHub Actions.

To preview locally: `./dashboard/fetch-data.sh && python3 -m http.server -d dashboard 8080`

## C4 Model

An interactive [C4 model](https://openshift-online.github.io/rosa-seaplane/c4-model) of the ROSA
Seaplane architecture (System Context, Container, and Component views) is published alongside the
PR dashboard. See [docs/design/c4/README.md](docs/design/c4/README.md) for how it's authored and
rendered.

## Repository Structure

```
rosa-seaplane/
├── argocd/
│   └── config/                       # Live Helm chart configurations
│       ├── management-cluster/       # Management cluster application templates
│       ├── regional-cluster/         # Regional cluster application templates
│       └── shared/                   # Shared configurations (ArgoCD, etc.)
├── ci/                               # CI automation (e2e tests)
├── deploy/                           # Per-environment deployment configs
├── docs/                             # Design documents and presentations
├── hack/                             # Developer utility scripts
├── scripts/                          # Dev and pipeline scripts
└── terraform/
    ├── config/                       # Terraform root configurations
    └── modules/                      # Reusable Terraform modules
```

## Getting Started

### Pipeline-Based Provisioning (CI/CD)

This is the standard way to provision a region. A central AWS account hosts CodePipelines that automatically provision Regional and Management Clusters when configuration is committed to Git.

See [Provision a New Environment](docs/environment-provisioning.md) for the full walkthrough.

### Ephemeral Dev Environments

For local development and testing, use the ephemeral workflow to provision a short-lived environment in a shared dev account. See [Provisioning a Development Environment](docs/development-environment.md) for a quick-start guide, or run `make help` for all available targets.

## CI

CI is managed through the [OpenShift CI](https://docs.ci.openshift.org/) system (Prow + ci-operator). The job configuration lives in [openshift/release](https://github.com/openshift/release/tree/master/ci-operator/config/openshift-online/rosa-seaplane).

For the list of jobs, how to trigger them, AWS credentials setup, and local execution, see [ci/README.md](ci/README.md).
