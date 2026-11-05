#!/usr/bin/env bash
#
# pre-destroy.sh - Transitional. Detach the account-level API Gateway logging
# resources this state no longer owns, before `terraform destroy`.
#
# The module relinquishes them with `removed` blocks, but a `removed` block
# only takes effect on apply: `terraform destroy` plans and performs the
# destroy regardless. A cluster provisioned before the handover and torn down
# after it would therefore still delete its logging role and — far worse —
# destroy aws_api_gateway_account, which resets cloudwatchRoleArn for the whole
# AWS account and region and stops access log delivery for every other REST API
# in it, including the RHOBS gateway.
#
# Detaching first leaves both the role and the live account setting untouched in
# AWS: this script edits Terraform state only and makes no API Gateway or IAM
# call. A setting
# that is valid beforehand therefore still names the same role afterwards, until
# the account-level owner reconciles it. That is the intended behaviour, not a
# verified no-outage guarantee — the role could have been changed or deleted
# outside Terraform, and nothing here checks delivery.
#
# Safe to run on any environment:
#   - Address managed here: detached, then re-read to prove it is gone
#   - Address not managed here: [absent], no-op (the normal case after the
#     state has applied the handover once)
#   - State unreadable or detach ineffective: the run fails and destroy is
#     skipped, rather than degrading into destroying the account setting
#
# REMOVE THIS FILE once every regional-cluster state has applied the handover
# at least once; from then on all three addresses are already absent.
set -uo pipefail

# state_rm_if_present and tf_state_rm_summary are provided by lib.sh
# (sourced by the parent buildspec script).

echo "--- Detaching relinquished account-level resources from state (Regional Cluster) ---"

state_rm_if_present 'module.api_gateway.aws_api_gateway_account.main'
state_rm_if_present 'module.api_gateway.aws_iam_role_policy_attachment.api_gateway_cloudwatch'
state_rm_if_present 'module.api_gateway.aws_iam_role.api_gateway_cloudwatch'

tf_state_rm_summary
