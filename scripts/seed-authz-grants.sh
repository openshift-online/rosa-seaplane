#!/usr/bin/env bash
# Writes an account's first grants straight into the authz tables, in the API storage
# contract format: the account-admin role may manage authz and run every resource action
# except on deny-probe-tagged resources. All tables live in the RC account, so rrp-rc
# writes every account's rows. Each record (a policy, or an attachment's two rows) is its
# own conditional write, matching what the management API deletes, so a rerun recreates
# any deleted record and skips existing ones.
# shortcut: pre-prod seeding until SSO org-admin linking replaces it.
#
# Usage: seed-authz-grants.sh <account-id> <table-prefix>
# The table prefix is the RC deployment_name: the region outside ephemeral.
set -euo pipefail

[[ $# -eq 2 && "$1" =~ ^[0-9]{12}$ && -n "$2" ]] || { echo "usage: $0 <12-digit-account-id> <table-prefix>" >&2; exit 2; }
account=$1 prefix=$2

transactions=$(jq -nc --arg a "${account}" --arg pt "${prefix}-authz-policies" --arg gt "${prefix}-authz-global" '
  def put($t; $pk; $sk; $rev; $rec): {Put: {TableName: $t, ConditionExpression: "attribute_not_exists(pk)",
    Item: {pk: {S: $pk}, sk: {S: $sk}, revision: {S: $rev}, record: {S: ($rec | tojson)}}}};
  "rosa-seaplane-account-admin" as $role | "ACCOUNT#\($a)" as $key
  | [["e2e-all-actions", "permit(principal, action in Seaplane::Action::\"AllActions\", resource) unless { context.requestLabels.hasTag(\"authz-deny-probe\") };"],
     ["e2e-policy-admin", "permit(principal, action in Seaplane::Action::\"PolicyAdmin\", resource);"]]
  | to_entries[] | .value[0] as $id | .value[1] as $content
  | $ARGS.positional[2 * .key] as $policyRev | $ARGS.positional[2 * .key + 1] as $attachmentRev
  | {Policy: {ID: $id, Kind: "custom"}, PrincipalARN: "arn:aws:iam::\($a):role/\($role)", Scope: "global",
     ID: $id, OwnerAccountID: $a, Region: "", Revision: $attachmentRev} as $attachment
  | {TransactItems: [put($pt; $key; "POLICY#\($id)"; $policyRev; {ID: $id, OwnerAccountID: $a, Content: $content, Revision: $policyRev, Kind: "custom"})]},
    {TransactItems: [put($gt; $key; "ATTACHMENT#\($id)"; $attachmentRev; $attachment),
                     put($gt; "\($key)#ROLE#aws/\($a)/\($role)"; "ATTACHMENT#\($id)"; $attachmentRev; $attachment)]}
  ' --args $(python3 -c 'import uuid; [print(uuid.uuid4()) for _ in range(4)]'))

while IFS= read -r transaction; do
  if ! output=$(AWS_PROFILE=rrp-rc aws dynamodb transact-write-items --cli-input-json "${transaction}" 2>&1); then
    [[ "${output}" == *ConditionalCheckFailed* ]] || { echo "ERROR: seeding authz grants for ${account}: ${output}" >&2; exit 1; }
    echo "Authz record $(jq -r '.TransactItems[0].Put.Item.sk.S' <<<"${transaction}") for ${account} already seeded"
  fi
done <<<"${transactions}"
