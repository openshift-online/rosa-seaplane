### Why does cert-manager use kustomize command patches?

The operand chart is [`openshift/cert-manager`](https://github.com/openshift/cert-manager) @ **v1.19.6**, matching `jetstack-cert-manager-rhel9:v1.19.6-1`. That chart is still the upstream templates (args, no command). The RH image has no ENTRYPOINT, so kustomize sets `command`. The cert-manager operator is not installed on EKS. Drop the patches if the chart grows a command value.

### What cluster types does the regional architecture support?

The regional architecture is designed exclusively for **ROSA HCP** (Hosted Control Planes). For the complete scope and architecture overview, see [ROSA Seaplane](README.md#scope).

### What is the Regional Cluster and what services run on it?

The Regional Cluster (RC) is an EKS-based cluster running core regional services (Platform API, seaplane-operator, kube-applier, ArgoCD, Tekton). For the complete three-layer architecture and component details, see [Architecture at a Glance](README.md#architecture-at-a-glance).

### What is the difference between the Regional Cluster and the Regional-Access Cluster?

In this implementation we will **not** use Regional-Access Clusters. Instead, we will use zero-operator access as the default model, with ephemeral boundary containers for break-glass scenarios

### What is the Management Cluster Reconciler (MCR)?

- MCR is a component within the seaplane-operator that orchestrates Management Cluster lifecycle
- It enables scalable management of multiple Management Clusters (MCs) per region, as opposed to having a statically defined list of MCs per region.
- This component will be developed by the Seaplane team.

### Where is the global control plane located?

- The purpose of the Central Control Plane is to run the Regional Provisioning Pipelines.
- As of this writing, the decision has not been made about the technology stack and location of the Central Control Plane.

### Where does the AuthZ service run?

- The decision about the AuthZ service is currently pending.
- The current design envisions AuthZ will be provided by AWS IAM, through Roles/Permissions created by the Customer in their own AWS accounts, therefore no separate AuthZ service might be needed.
- Alternatives such as Kessel are being considered, in which case they would run in the Regional Cluster, and there will be no global AuthZ service.

### Is the Central Data Plane in the regional accounts or the global account?

- The Central Data Plane (IAM, identity, global access control) is **global** and is provided by AWS IAM
- This architecture does not depend on Red Hat SSO to operate the clusters
- However Red Hat SSO is needed once (and only once) in order to link Red Hat identities to AWS IAM identities
- After that linkage, all access control is performed via AWS IAM
- Billing will take place through the AWS Marketplace

### How long can a region operate if Global Services go down?

- The service will depend on AWS IAM, and will be impacted if IAM is unavailable
- However, each region is independent and will continue operating even if any other regions are unavailable
- As of this writing, there are no global services run by Red Hat that are critical for regional operation

### Is there a requirement to bring up a consoledot equivalent in another region within a set timeframe?

- The console is web application that will be served via a CDN (CloudFront). The ConsoleDot team is working on removing any dependencies on Red Hat operated clusters (such as crc).
- The console experience will be similar to that of the AWS Management Console, which is globally available, and connects to regional endpoints. There will be no global ROSA API endpoints.

### What is the path to recovery after a disaster?

- **Source of truth**: seaplane-db (Aurora PostgreSQL) is the single declarative source of truth for cluster state, with regular cross-region backups.
- **etcd state of MCs**: Critical for hosted cluster data; etcd snapshots will be continuously backed up to a dedicated DR AWS account (per region)
- **kube-applier DynamoDB tables**: Can be rebuilt from seaplane-db; kube-applier tables cache desire/status state for resource distribution but seaplane-db is authoritative. Loss of these tables does not prevent recovery, though observability and reconciliation continuity may be temporarily affected until state is rehydrated.
- **Recovery path**:
  - Management Cluster recovery: Restore from etcd backups in the DR account
  - Hosted Cluster recovery: etcd snapshots allow restoration of customer control planes
  - seaplane-db state: Persisted in Aurora PostgreSQL
- **Break-glass access**: On-demand break-glass access for emergency access when normal management flows are unavailable

### What are the key SLOs to maintain during an outage?

This list is not complete, but some key ones are:

- Customer cluster API access (HCP control planes) and CUJs
- Seaplane-operator for cluster lifecycle operations
- MC Reconciler for dynamic scaling of MCs
- Management Cluster availability (hosting control planes)

### What happens when the Kubernetes API on a Management Cluster goes down?

- Management Clusters are EKS clusters managed. We would open a support case with AWS to restore the API.
- If the Management Cluster is unrecoverable, we will have to provision a new MC, and restore all the HCPs from etcd backups, as well as update the single source of truth (seaplane-db).

### How does kube-applier distribute resources to Management Clusters?

A kube-applier controller runs on each Management Cluster, reading desire documents from DynamoDB tables (written by the seaplane-operator in the RC account) via seaplane-dynamo GSI polling and applying them to the local Kubernetes API. If the MC API is non-responsive, observability alerts notify SREs.

For the current architecture, see [Seaplane Architecture](design/regional-control-plane-architecture.md).

### How are new regions deployed?

Regions are deployed on demand via pipelines **fully automatically**: add region configuration to Git, pipelines provision the RC, ArgoCD installs core services, and MCs are provisioned as needed.

For details, see [Pipeline-Based Lifecycle](design/pipeline-based-lifecycle.md) and [Provision a New Environment](environment-provisioning.md).

### Should we use AWS Landing Zone for region setup?

This is a valid consideration. The current approach uses Terraform + pipeline-based provisioning, but AWS Landing Zone could simplify multi-account setup. Decision is TBD.

For the current account minting design, see [Regional Account Minting](design/regional-account-minting.md).

### Is there a canary region for testing new releases?

Yes, the architecture uses a **sector-based progressive deployment** model aligned with [ADR-0032](https://github.com/openshift-online/architecture/blob/main/hcm/decisions/archives/SD-ADR-0032_HyperShift_Change_Management_Strategy.md). Sectors are predefined (e.g. `stage`, `sector 1`, `sector 2`) and each region is assigned to a sector during provisioning.

For details on the configuration hierarchy and commit pinning, see [GitOps Cluster Configuration](design/gitops-cluster-configuration.md).

### Is the Regional API Gateway Red Hat managed?

Yes. It consists of AWS API Gateway + VPC Link v2 + Internal ALB, exposed at `api.<region>.openshift.com`. Deployed via Terraform pipelines.

For implementation details, see the [API Gateway module](../terraform/modules/api-gateway/README.md).

### What is VPC Link v2?

An AWS feature that enables private connectivity between API Gateway and VPC resources, keeping traffic within the AWS network. Request flow: API Gateway → VPC Link v2 → Internal ALB → Platform API.

### How is PrivateLink used in this architecture?

- Regional Cluster and Management Clusters are in separate VPCs, and their Kube APIs are private
- Regional Cluster MUST have **no** network path to the Management Cluster Kube API
- Management Clusters MUST have **no** network path to the Regional Cluster Kube API
- We might need a PrivateLink to expose services running in the Regional Cluster to be accessible from Management Clusters, we are specifically considering this for observability and for ArgoCD, however we are trying to avoid that. This design is TBD.

### Is OCM/CS deployed to each region?

**No** — OCM, CS, and AMS are replaced by the **seaplane-operator**, developed as part of the Seaplane project. One seaplane-operator instance runs in each Regional Cluster, backed by seaplane-db (Aurora PostgreSQL) as the single source of truth for cluster state.

For architecture details, see [Seaplane Architecture](design/regional-control-plane-architecture.md).

### Is this design without App-Interface in favor of ArgoCD?

**Yes** — ArgoCD handles application deployment, Terraform pipelines handle infrastructure. We might still use App-Interface for the Central Control Plane (decision pending).

For the full GitOps design, see [GitOps Cluster Configuration](design/gitops-cluster-configuration.md).

### Is Backplane part of the Regional Cluster or its own cluster?

- Backplane will not be used in this architecture, at least not as it is currently designed
- We will favor instead a zero-operator access model, with ephemeral boundary containers for break-glass scenarios

### What is used for IDS?

We have not explored this decision yet.

### Is Splunk cloud or local to each region?

We have not explored this decision yet.
