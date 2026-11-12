# ROSA Seaplane - ArgoCD Configuration

## Overview

Each cluster's ArgoCD is configured to use a rendered ApplicationSet from `config/templates/argocd-bootstrap/applicationset.yaml.j2` as its entrypoint. This ApplicationSet can be configured in two ways:

1. **Live Config**: Uses Helm charts from `argocd/config/<cluster_type>/` and `argocd/config/shared/` directly from the current git revision (main branch or your development branch passed during cluster provisioning)

2. **Pinned Commits**: Uses specific commit hashes that refer to a snapshotted point in time of the rosa-seaplane repository's charts. This is used for progressive delivery where we "cut releases" by bundling applications.

## Repository Structure

```
argocd/
├── config/
│   ├── shared/                          # Shared charts (ArgoCD, etc.)
│   ├── management-cluster/              # MC-specific charts
│   └── regional-cluster/                # RC-specific charts
└── README.md

config/                                  # Region deployment configuration
└── <env>/
    ├── defaults.yaml                    # Per-environment defaults
    └── <region>.yaml                   # Per-region values (git.revision for pinning)

scripts/
└── render.py                            # Generates values, ApplicationSets, and terraform configs

deploy/                                  # Generated outputs (DO NOT EDIT)
└── {environment}/{region}/
    ├── argocd-values-{cluster_type}.yaml
    └── argocd-bootstrap-{cluster_type}/
        └── applicationset.yaml
```

## Configuration Modes

### Live Config (Integration)

- **Integration environments** run off the dynamic state in the current git revision (main or development branch configured for the cluster's ArgoCD)
- **No commit pinning** - always uses latest changes
- **Fast iteration** - changes appear immediately

### Pinned Commits (Staging/Production)

- **"Cut releases"** by setting `git.revision` to a commit hash in the region config
- **Progressive delivery** - roll through staging region deployments, then production region deployments
- **Immutable deployments** - exact reproducible state

See [Config Directory](../config/README.md) for the full configuration hierarchy and examples.

## Workflow

1. **Development**: Work with integration region deployments using live config (current branch)
2. **Release**: When ready, pin staging region deployments to tested commit hash
3. **Production**: Roll pinned commits through production region deployments
4. **Generate configs**: Run `./scripts/render.py` after changes

## Adding New Helm Charts

Create Helm charts in the appropriate directory based on where they should be deployed:

```bash
# For charts shared by all clusters
argocd/config/shared/my-new-app/
├── Chart.yaml
├── values.yaml
└── templates/

# For management cluster specific charts
argocd/config/management-cluster/my-mc-app/
├── Chart.yaml
├── values.yaml
└── templates/

# For regional cluster specific charts
argocd/config/regional-cluster/my-rc-app/
├── Chart.yaml
├── values.yaml
└── templates/
```

The ApplicationSet will automatically discover and deploy new charts. Run `./scripts/render.py` to generate the required configuration files.

Wrapper charts with `dependencies:` vendor `Chart.lock` and `charts/<name>-<version>.tgz` so ArgoCD does not re-fetch at sync. After changing a dependency version in `Chart.yaml`:

```bash
make helm-deps CHART=argocd/config/shared/argocd   # or make helm-deps for every wrapper
```

Commit the lock and tgz. `make check-helm-locks` (also in `make pre-push`) fails if they drift. Cert-manager is a git submodule, not this Helm lock.

## How It Works

ArgoCD uses a **Matrix Generator** pattern combining a Git Generator (discovers Helm charts) with a Cluster Generator (reads cluster identity). Charts are sourced from either a pinned commit hash or the current git revision, while rendered values always come from the latest revision.

For the full architecture, alternatives considered, and implementation details, see [GitOps Cluster Configuration](../docs/design/gitops-cluster-configuration.md).
