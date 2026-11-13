"""Execute shell boundaries with local fakes, without AWS or containers."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ShellTests(unittest.TestCase):
    def run_shell(self, script, cwd=ROOT, **env):
        return subprocess.run(["bash", "-euc", script], cwd=cwd, capture_output=True, text=True,
                              env={**os.environ, **env})

    def ci_block(self):
        source = (ROOT / "ci/e2e-tests.sh").read_text()
        start = source.index("# Enrollment never supplies")
        return source[start:source.index("platform_rc=0", start)]

    def run_ci(self, directory, transact="", **env):
        """Run the CI enrollment and seeding block with fake aws/awscurl that log every call."""
        log = Path(directory) / "calls"
        script = f"""aws() {{
  if [[ "$1" == configure ]]; then [[ -z "${{NO_CUSTOMER:-}}" ]]; return; fi
  if [[ "$1" == sts ]]; then if [[ "$*" == *rrp-customer* ]]; then echo 222222222222; else echo 111111111111; fi; return; fi
  [[ "$1 $2 $3" == "dynamodb transact-write-items --cli-input-json" ]] || {{ echo "unexpected aws $*" >&2; return 1; }}
  printf 'seed %s %s\\n' "$AWS_PROFILE" "$(jq -c . <<<"$4")" >> "$LOG"
  {transact}
}}
awscurl() {{ printf 'enroll %s\\n' "$*" >> "$LOG"; }}
""" + self.ci_block() + '\necho suite >> "$LOG"\n'
        env = {"E2E_CUSTOMER_ACCOUNT_ID": "", "E2E_ACCOUNT_ID": "", "ZOA_DEPLOYMENT_NAME": "", **env}
        result = self.run_shell(script, BASE_URL="https://example.test", AWS_DEFAULT_REGION="us-east-1",
                                LOG=str(log), **env)
        return result, log.read_text().splitlines() if log.exists() else []

    def test_ci_enrolls_then_seeds_grants(self):
        for prefix, env in (("us-east-1", {}), ("us-east-1-xg4y", {"ZOA_DEPLOYMENT_NAME": "us-east-1-xg4y"})):
            with self.subTest(prefix=prefix), tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_ci(directory, **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('{"accountId":"111111111111"}', calls[0])
                self.assertIn('{"accountId":"222222222222"}', calls[1])
                self.assertEqual(calls[10], "suite")
                for index, account in enumerate(("111111111111", "222222222222")):
                    self.assert_seed(self.seed_transactions(calls[2 + 4 * index:6 + 4 * index]), account, prefix)

    def test_ci_skips_missing_customer_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_ci(directory, NO_CUSTOMER="1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('{"accountId":"111111111111"}', calls[0])
            self.assert_seed(self.seed_transactions(calls[1:5]), "111111111111", "us-east-1")
            self.assertEqual(calls[5:], ["suite"])

    def seed_transactions(self, calls):
        """Return one account's seed rows, checking each record is its own rrp-rc transaction."""
        transactions = []
        for call in calls:
            kind, profile, body = call.split(" ", 2)
            self.assertEqual((kind, profile), ("seed", "rrp-rc"))
            transactions.append(json.loads(body)["TransactItems"])
        # A policy, then its attachment's management and lookup rows, per grant.
        self.assertEqual([len(items) for items in transactions], [1, 2, 1, 2])
        return [item for items in transactions for item in items]

    def assert_seed(self, items, account, prefix):
        """Rows must match the API storage contract exactly (see the API raw-seed contract test)."""
        role_arn = f"arn:aws:iam::{account}:role/rosa-seaplane-account-admin"
        key = f"ACCOUNT#{account}"
        self.assertEqual(len(items), 6)
        for item in items:
            self.assertEqual(item["Put"]["ConditionExpression"], "attribute_not_exists(pk)")
        rows = [{k: v["S"] for k, v in item["Put"]["Item"].items()} | {"table": item["Put"]["TableName"]}
                for item in items]
        contents = {"e2e-all-actions": 'permit(principal, action in Seaplane::Action::"AllActions", resource) '
                                       'unless { context.requestLabels.hasTag("authz-deny-probe") };',
                    "e2e-policy-admin": 'permit(principal, action in Seaplane::Action::"PolicyAdmin", resource);'}
        for index, (policy_id, content) in enumerate(contents.items()):
            policy, attachment, lookup = rows[3 * index:3 * index + 3]
            self.assertEqual((policy["table"], policy["pk"], policy["sk"]),
                             (f"{prefix}-authz-policies", key, f"POLICY#{policy_id}"))
            self.assertEqual(json.loads(policy["record"]), {"ID": policy_id, "OwnerAccountID": account, "Content": content,
                                                            "Revision": policy["revision"], "Kind": "custom"})
            self.assertEqual([(row["table"], row["pk"], row["sk"]) for row in (attachment, lookup)], [
                (f"{prefix}-authz-global", key, f"ATTACHMENT#{policy_id}"),
                (f"{prefix}-authz-global", f"{key}#ROLE#aws/{account}/rosa-seaplane-account-admin", f"ATTACHMENT#{policy_id}")])
            for row in (attachment, lookup):
                self.assertEqual(row["revision"], attachment["revision"])
                self.assertEqual(json.loads(row["record"]), {
                    "Policy": {"ID": policy_id, "Kind": "custom"}, "PrincipalARN": role_arn, "Scope": "global",
                    "ID": policy_id, "OwnerAccountID": account, "Region": "", "Revision": attachment["revision"]})
        revisions = {row["revision"] for row in rows}
        self.assertEqual(len(revisions), 4)
        for revision in revisions:
            self.assertRegex(revision, r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    def test_ci_seeding_reruns_and_failures(self):
        cases = {"seeded": ("echo 'TransactionCanceledException: [ConditionalCheckFailed, None]' >&2; return 255", True),
                 "denied": ("echo 'AccessDeniedException' >&2; return 255", False)}
        for name, (transact, accepted) in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_ci(directory, transact=transact)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                self.assertEqual(calls[-1] == "suite", accepted)
                if accepted:
                    self.assertIn("already seeded", result.stdout)
                else:
                    self.assertIn("AccessDeniedException", result.stderr)

    def test_ci_seeding_repairs_partial_grants(self):
        """An existing record must not stop the account's other records from being written."""
        transact = ('if [[ "$4" == *POLICY#e2e-policy-admin* ]]; then '
                    "echo 'TransactionCanceledException: [ConditionalCheckFailed]' >&2; return 255; fi")
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_ci(directory, transact=transact)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sum(call.startswith("seed ") for call in calls), 8)
            self.assertEqual(result.stdout.count("POLICY#e2e-policy-admin for"), 2)
            self.assertEqual(calls[-1], "suite")

    def test_ci_rejects_customer_account_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_ci(directory, E2E_CUSTOMER_ACCOUNT_ID="111111111111")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rrp-customer account", result.stderr)
            self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
