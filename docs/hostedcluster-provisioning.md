# Provision a Hosted Cluster

This guide walks through creating a ROSA HCP cluster on the integration environment.

## Prerequisites

### ROSA CLI

```bash
git clone https://github.com/openshift/rosa.git
cd rosa
git checkout seaplane-v2
make rosa
# optionally
make install
```

`make install` places the `rosa` binary in `$(go env GOPATH)/bin`. Make sure that
directory is on your `PATH` (e.g. `export PATH="$(go env GOPATH)/bin:$PATH"`) so
you run the checked-out `seaplane-v2` build rather than any system-installed
`rosa`.

### Dependencies

```bash
command -v jq >/dev/null || echo "Need jq installed"
```

### Account Allowlisting

Your AWS account must be allowlisted before you can create clusters. Ask `@rrp-team-ic` in `#team-rosa-seaplane` to allowlist your account — provide your **AWS account ID** and the target **environment** (e.g. integration). This is a one-time step per account per environment. Accounts allowlisted before the Cedar authorization rollout must be allowlisted again.

In an ephemeral environment, allowlist it yourself:

```bash
make ephemeral-post-account-shell ACCOUNT_ID=<account-id>
```

<details>
<summary>IC reference: allowlisting command</summary>

Run from a platform API shell (`make int-shell` or `make stage-shell`), which signs as the RC account:

```bash
awscurl --service execute-api --region "$REGION" \
  -X POST "$API_URL/api/v0/accounts" \
  -H "Content-Type: application/json" \
  -d '{"accountId": "<account-id>"}'
```

Returns 204. Revoke with `DELETE $API_URL/api/v0/accounts/<account-id>`. See [Platform API authorization](platform-api-authorization.md#allowlist-an-account-sop).

</details>

## Set Up

```bash
# Verify you are using the correct AWS account — this is where worker nodes
# will be created. You can use a profile, environment variables, etc.
aws sts get-caller-identity

# Platform API URL
# - Integration: https://api.us-east-1.int0.rosa.devshift.net
# - Stage:       https://api.us-east-1.stg0.rosa.devshift.org
API_URL=https://api.us-east-1.int0.rosa.devshift.net

# Cluster variables
REGION=us-east-1
CLUSTER_NAME=<pick-a-name>
```

## Create a Cluster using ROSA CLI

```bash
# Assuming you are running from the ROSA repo folder
./bin/rosa login --seaplane-url $API_URL
I: Logged in to Platform API: $API_URL

rosa whoami
AWS ARN:                      arn:aws:iam::<account-id>:user/<username>
AWS Account ID:               <account-id>
AWS Default Region:           us-east-1
V2 API:                       $API_URL

./bin/rosa list clusters
I: No clusters available

./bin/rosa create oidc-config --managed --mode auto

./bin/rosa list oidc-config
ID                                    TYPE     ISSUER URL                                                          SECRET ARN
<oidc-config-id>                      managed  https://<cloudfront-id>.cloudfront.net/<oidc-config-id>

CLUSTER_NAME=my-cluster
OIDC_ID=<oidc-config-id>

./bin/rosa create operator-roles --hosted-cp --oidc-config-id $OIDC_ID --mode auto --prefix $CLUSTER_NAME

./bin/rosa create network \
    --mode auto \
    --param ClusterName=$CLUSTER_NAME \
    --param Name=$CLUSTER_NAME-vpc \
    --param Region=us-east-1 \
    --param VpcCidr=10.0.0.0/16

SUBNETS=$(aws cloudformation describe-stacks --stack-name $CLUSTER_NAME-vpc --query 'Stacks[0].Outputs' --region us-east-1 | jq -r '[ .[] | select(.OutputKey | contains("Subnets")).OutputValue ] | join(",")')

./bin/rosa create cluster \
    --cluster-name=$CLUSTER_NAME -y \
    --region us-east-1 \
    --operator-roles-prefix $CLUSTER_NAME \
    --subnet-ids $SUBNETS \
    --hosted-cp \
    --compute-machine-type m5.xlarge \
    --oidc-config-id $OIDC_ID \
    --version quay.io/openshift-release-dev/ocp-release:5.0.0-rc.7-multi

./bin/rosa create machinepool --cluster=$CLUSTER_NAME --name=workers --replicas=2 --instance-type=m5.xlarge --subnet <subnet-id> --region us-east-1

./bin/rosa list clusters
ID                                    NAME        STATE         TOPOLOGY
<cluster-id>                          my-cluster  Provisioning  Hosted CP

./bin/rosa list machinepool -c $CLUSTER_NAME
ID       NAME     REPLICAS  INSTANCE TYPE  SUBNET         STATE
workers  workers  2         m5.xlarge      <subnet-id>    Provisioning

./bin/rosa list machinepool -c $CLUSTER_NAME
ID       NAME     REPLICAS  INSTANCE TYPE  SUBNET         STATE
workers  workers  2         m5.xlarge      <subnet-id>    Ready

./bin/rosa delete cluster -c $CLUSTER_NAME
? Are you sure you want to delete cluster my-cluster? Yes
I: Cluster 'my-cluster' will start deleting now
```

## Cluster Lifecycle

**Automatic cleanup:** Clusters are automatically deleted after **24 hours** by a platform cleanup job. You do not need to delete them manually.

**CloudFormation stacks persist:** The three CloudFormation stacks in your AWS account (`cluster-iam`, `cluster-vpc`, `cluster-oidc`) are **not** deleted by the cleanup job. You can reuse them when creating your next cluster with the same name, skipping the `cluster-iam`, `cluster-vpc`, and `cluster-oidc` create steps.

## Notes

- If you create more than 5 hosted clusters, ensure your AWS account has sufficient NAT gateway quota (default limit is 5).
- For ephemeral (dev) environments, see [Development Environment](development-environment.md). The cluster creation flow is the same — only the `API_URL` differs.
- For admin teardown procedures, see [Hosted Cluster Teardown](hostedcluster-teardown.md).
- For assistance, reach out to @rrp-team-ic in #team-rosa-seaplane.
