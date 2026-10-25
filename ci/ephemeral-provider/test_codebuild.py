import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock

from codepipeline import PipelineMonitor


class BuildSuccessContractTest(unittest.TestCase):
    def _pipeline_result(self, resolved_sha, applied, applied_sha):
        pipeline_client = Mock()
        pipeline_client.get_pipeline_execution.return_value = {
            "pipelineExecution": {"status": "Succeeded"}
        }
        pipeline_client.list_action_executions.return_value = {
            "actionExecutionDetails": [
                {
                    "actionName": "ApplyInfrastructure",
                    "output": {
                        "executionResult": {"externalExecutionId": "cluster:build-123"}
                    },
                }
            ]
        }
        build_client = Mock()
        build_client.exceptions.ResourceNotFoundException = type(
            "ResourceNotFoundException", (Exception,), {}
        )
        build_client.batch_get_builds.return_value = {
            "builds": [
                {
                    "id": "cluster:build-123",
                    "buildStatus": "SUCCEEDED",
                    "resolvedSourceVersion": resolved_sha,
                    "exportedEnvironmentVariables": [
                        {"name": "APPLIED", "value": applied},
                        {"name": "APPLIED_SHA", "value": applied_sha},
                    ],
                }
            ]
        }
        session = Mock()
        session.client.side_effect = lambda service: (
            pipeline_client if service == "codepipeline" else build_client
        )
        return PipelineMonitor(session).wait_for_pipelines(
            [("cluster", "execution-123")], "a" * 40
        )["cluster"]

    def test_rejected_aws_success_is_returned_as_failure(self):
        sha = "a" * 40
        cases = [
            ("", "true", sha, "without resolvedSourceVersion"),
            ("b" * 40, "true", sha, "resolved to SHA"),
            (sha, "false", sha, "APPLIED='false'"),
            (sha, "true", "b" * 40, "APPLIED_SHA="),
        ]
        for resolved_sha, applied, applied_sha, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                result = self._pipeline_result(resolved_sha, applied, applied_sha)
                self.assertEqual(result.status, "FAILED")
                self.assertIn(expected_error, result.error)

    def test_valid_aws_success_remains_successful(self):
        sha = "a" * 40
        result = self._pipeline_result(sha, "true", sha)
        self.assertEqual(result.status, "SUCCEEDED")
        self.assertIsNone(result.error)


class ClusterProjectLifecycleTest(unittest.TestCase):
    """Run the production Bash lifecycle against an offline AWS CLI substitute."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.state_path = self.root / "aws-state.json"
        self.calls_path = self.root / "aws-calls.jsonl"
        self.state_path.write_text(json.dumps({"project": None, "pipeline": None}))
        self.calls_path.write_text("")
        self.scope = "arn:aws:iam::123456789012:role/test-cluster-pipeline-role"
        self.env = {
            "PATH": os.environ["PATH"],
            "TEST_PYTHON": sys.executable,
            "TEST_AWS_MOCK": str(self.root / "aws_mock.py"),
            "TEST_AWS_STATE": str(self.state_path),
            "TEST_AWS_CALLS": str(self.calls_path),
            "ENVIRONMENT": "test",
            "REGION": "us-east-1",
            "REGION_DEPLOYMENT": "us-east-1",
            "AWS_REGION": "us-east-1",
            "GITHUB_REPOSITORY": "example/repository",
            "GITHUB_BRANCH": "test-branch",
            "GITHUB_CONNECTION_ARN": "arn:aws:codeconnections:us-east-1:123456789012:connection/test",
            "PLATFORM_IMAGE": "example.invalid/platform:current",
            "CODEPIPELINE_ROLE_ARN": self.scope,
            "PIPELINE_ARTIFACT_BUCKET": "test-pipeline-artifacts",
        }
        # Only top-level function definitions are evaluated, never the script's
        # main provisioning loop or account-bootstrap side effects.
        self.functions = "\n".join(
            function
            for script in ("provision-cluster-resources.sh", "bootstrap-central-account.sh")
            for function in re.findall(
                r"^[a-zA-Z_][a-zA-Z_0-9]*\(\) \{\n.*?^\}",
                (Path(__file__).resolve().parents[2] / "scripts" / script).read_text(),
                re.M | re.S,
            )
        )
        Path(self.env["TEST_AWS_MOCK"]).write_text(
            '''import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with open(os.environ["TEST_AWS_CALLS"], "a") as calls:
    calls.write(json.dumps(args) + "\\n")
state_path = Path(os.environ["TEST_AWS_STATE"])
state = json.loads(state_path.read_text())
operation = " ".join(args[:2])

def option(name):
    return args[args.index(name) + 1] if name in args else None

error = state.get("errors", {}).get(operation)
if error:
    print(f"An error occurred ({error}) when calling AWS: mocked failure", file=sys.stderr)
    sys.exit(254)

if operation == "codebuild batch-get-projects":
    print(json.dumps(state["project"]))
elif operation in ("codebuild create-project", "codebuild update-project"):
    if option("--cli-input-json"):
        state["project"] = json.loads(option("--cli-input-json"))
    else:
        state["project"]["tags"] = json.loads(option("--tags"))
elif operation == "codepipeline get-pipeline":
    if state["pipeline"] is None:
        print("An error occurred (PipelineNotFoundException)", file=sys.stderr)
        sys.exit(254)
    print(state["pipeline"]["name"] if option("--query") == "pipeline.name"
          else json.dumps(state["pipeline"]))
elif operation in ("codepipeline create-pipeline", "codepipeline update-pipeline"):
    state["pipeline"] = json.loads(option("--cli-input-json"))["pipeline"]
elif operation == "codepipeline list-pipeline-executions":
    print(json.dumps({"pipelineExecutionSummaries": state.get("executions", [])}))
elif operation == "codepipeline delete-pipeline":
    state["pipeline"] = None
elif operation == "codebuild delete-project":
    state["project"] = None
elif operation == "ssm get-parameter":
    print(state["ssm_value"])
else:
    print(f"Unexpected AWS operation: {args}", file=sys.stderr)
    sys.exit(99)
state_path.write_text(json.dumps(state))
'''
        )

    def _run(self, command, state=None):
        if state is not None:
            self.state_path.write_text(json.dumps(state))
        self.calls_path.write_text("")
        return subprocess.run(
            [
                "bash", "-c",
                'set -euo pipefail\n'
                'aws() { "$TEST_PYTHON" "$TEST_AWS_MOCK" "$@"; }\n'
                + self.functions + "\n" + command,
            ],
            env=self.env,
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=20,
        )

    def _desired_project(self):
        result = self._run(
            '_spec=$(generate_project_spec regional custom-cluster '
            'arn:aws:iam::123456789012:role/build-role buildspec.yml 60)\n'
            '_hash=$(compute_spec_hash "$_spec")\n'
            'jq -n --argjson spec "$_spec" --arg hash "$_hash" '
            '\'{spec: $spec, hash: $hash}\''
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        desired = json.loads(result.stdout)
        desired["spec"]["tags"] = [
            {"key": "DefinitionHash", "value": desired["hash"]},
            {"key": "ProvisioningScope", "value": self.scope},
            {"key": "Owner", "value": "custom-owner"},
        ]
        return desired["spec"]

    def _upsert(self, state, cluster_type="regional"):
        return self._run(
            f"upsert_project {cluster_type} custom-cluster "
            "arn:aws:iam::123456789012:role/build-role buildspec.yml 60 custom-cluster",
            state,
        )

    def _calls(self):
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()]

    def _pipeline_with_api_defaults(self):
        result = self._run(
            "generate_pipeline_spec regional custom-cluster-pipeline "
            "custom-cluster custom-cluster us-east-1"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        pipeline = json.loads(result.stdout)["pipeline"]
        pipeline["version"] = 7
        pipeline["stages"][0]["actions"][0]["inputArtifacts"] = []
        pipeline["stages"][1]["actions"][0]["outputArtifacts"] = []
        push = pipeline["triggers"][0]["gitConfiguration"]["push"][0]
        push["branches"]["excludes"] = []
        push["filePaths"]["excludes"] = []
        return pipeline

    def test_create_has_scope_logs_and_only_destroy_pipeline_variable(self):
        for cluster_type in ("regional", "management"):
            with self.subTest(cluster_type=cluster_type):
                result = self._upsert({"project": None, "pipeline": None}, cluster_type)
                self.assertEqual(result.returncode, 0, result.stderr)
                state = json.loads(self.state_path.read_text())
                project = state["project"]
                tags = {tag["key"]: tag["value"] for tag in project["tags"]}
                self.assertEqual(tags["ProvisioningScope"], self.scope)
                self.assertRegex(tags["DefinitionHash"], r"^[0-9a-f]{64}$")
                self.assertEqual(project["logsConfig"]["cloudWatchLogs"], {
                    "status": "ENABLED",
                    "groupName": f"/aws/codebuild/test-cluster-pipeline-role/{cluster_type}",
                })
                pipeline = state["pipeline"]
                self.assertEqual(pipeline["variables"], [
                    {"name": "IS_DESTROY", "defaultValue": "false"},
                ])
                build_action = pipeline["stages"][1]["actions"][0]
                self.assertEqual(
                    json.loads(build_action["configuration"]["EnvironmentVariables"]),
                    [{"name": "IS_DESTROY", "value": "#{variables.IS_DESTROY}", "type": "PLAINTEXT"}],
                )
                operations = [call[:2] for call in self._calls()]
                self.assertLess(
                    operations.index(["codebuild", "create-project"]),
                    operations.index(["codepipeline", "create-pipeline"]),
                )

    def test_missing_scope_with_matching_hash_is_repaired_before_pipeline(self):
        project = self._desired_project()
        project["tags"] = [tag for tag in project["tags"] if tag["key"] != "ProvisioningScope"]
        project["arn"] = "arn:aws:codebuild:us-east-1:123456789012:project/custom-cluster"
        project["environment"]["environmentVariables"].reverse()

        result = self._upsert({"project": project, "pipeline": None})

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self._calls()
        self.assertEqual([call[:2] for call in calls], [
            ["codebuild", "batch-get-projects"],
            ["codebuild", "update-project"],
            ["codepipeline", "get-pipeline"],
            ["codepipeline", "create-pipeline"],
        ])
        self.assertIn("--tags", calls[1])
        self.assertNotIn("--cli-input-json", calls[1])
        tags = json.loads(calls[1][calls[1].index("--tags") + 1])
        self.assertIn({"key": "ProvisioningScope", "value": self.scope}, tags)
        self.assertIn({"key": "Owner", "value": "custom-owner"}, tags)

    def test_foreign_scope_is_rejected_without_modifying_project_or_pipeline(self):
        project = self._desired_project()
        for tag in project["tags"]:
            if tag["key"] == "ProvisioningScope":
                tag["value"] = "arn:aws:iam::123456789012:role/another-owner"

        result = self._upsert({"project": project, "pipeline": None})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different provisioning scope", result.stderr)
        self.assertEqual([call[:2] for call in self._calls()], [
            ["codebuild", "batch-get-projects"],
        ])

    def test_untagged_project_with_different_role_cannot_be_adopted(self):
        project = self._desired_project()
        project["tags"] = [tag for tag in project["tags"] if tag["key"] != "ProvisioningScope"]
        project["serviceRole"] = "arn:aws:iam::123456789012:role/another-build-role"

        result = self._upsert({"project": project, "pipeline": None})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to adopt untagged CodeBuild project", result.stderr)
        self.assertEqual([call[:2] for call in self._calls()], [
            ["codebuild", "batch-get-projects"],
        ])

    def test_live_drift_with_matching_hash_is_repaired_and_custom_tags_retained(self):
        desired = self._desired_project()
        for drift in ("image", "buildspec", "log_group"):
            with self.subTest(drift=drift):
                project = copy.deepcopy(desired)
                if drift == "image":
                    project["environment"]["image"] = "example.invalid/platform:old"
                elif drift == "buildspec":
                    project["source"]["buildspec"] = "old-buildspec.yml"
                else:
                    project["logsConfig"]["cloudWatchLogs"]["groupName"] = "/old/logs"

                result = self._upsert({"project": project, "pipeline": None})

                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self._calls()
                update = next(call for call in calls if call[:2] == ["codebuild", "update-project"])
                repaired = json.loads(update[update.index("--cli-input-json") + 1])
                self.assertEqual(repaired["environment"], desired["environment"])
                self.assertEqual(repaired["source"], desired["source"])
                self.assertEqual(repaired["logsConfig"], desired["logsConfig"])
                self.assertEqual(
                    sorted(repaired["tags"], key=lambda tag: tag["key"]),
                    sorted(desired["tags"], key=lambda tag: tag["key"]),
                )

    def test_failed_scope_repair_prevents_pipeline_creation(self):
        project = self._desired_project()
        project["tags"] = [tag for tag in project["tags"] if tag["key"] != "ProvisioningScope"]

        result = self._upsert({
            "project": project,
            "pipeline": None,
            "errors": {"codebuild update-project": "AccessDeniedException"},
        })

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AccessDeniedException", result.stderr)
        self.assertEqual([call[:2] for call in self._calls()], [
            ["codebuild", "batch-get-projects"],
            ["codebuild", "update-project"],
        ])

    def test_empty_api_defaults_do_not_update_an_active_pipeline(self):
        pipeline = self._pipeline_with_api_defaults()

        result = self._run(
            "upsert_pipeline regional custom-cluster custom-cluster us-east-1",
            {
                "project": None,
                "pipeline": pipeline,
                "executions": [{"status": "InProgress"}],
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CodePipeline unchanged", result.stdout)
        self.assertEqual([call[:2] for call in self._calls()], [
            ["codepipeline", "get-pipeline"],
            ["codepipeline", "get-pipeline"],
        ])

    def test_real_pipeline_drift_is_still_rejected_while_active(self):
        desired = self._pipeline_with_api_defaults()
        for drift in ("core", "trigger"):
            with self.subTest(drift=drift):
                pipeline = copy.deepcopy(desired)
                if drift == "core":
                    pipeline["executionMode"] = "QUEUED"
                    expected_error = "non-trigger settings changed"
                else:
                    push = pipeline["triggers"][0]["gitConfiguration"]["push"][0]
                    push["branches"]["includes"] = ["another-branch"]
                    expected_error = "push-trigger settings changed"

                result = self._run(
                    "upsert_pipeline regional custom-cluster custom-cluster us-east-1",
                    {
                        "project": None,
                        "pipeline": pipeline,
                        "executions": [{"status": "InProgress"}],
                    },
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)
                self.assertEqual([call[:2] for call in self._calls()], [
                    ["codepipeline", "get-pipeline"],
                    ["codepipeline", "get-pipeline"],
                    ["codepipeline", "list-pipeline-executions"],
                ])

    def test_delete_permission_errors_propagate_and_stop_cleanup(self):
        for failed_operation in ("codepipeline delete-pipeline", "codebuild delete-project"):
            with self.subTest(failed_operation=failed_operation):
                result = self._run("delete_project custom-cluster", {
                    "project": None,
                    "pipeline": None,
                    "errors": {failed_operation: "AccessDeniedException"},
                })

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("AccessDeniedException", result.stderr)
                expected = [["codepipeline", "delete-pipeline"]]
                if failed_operation == "codebuild delete-project":
                    expected.append(["codebuild", "delete-project"])
                self.assertEqual([call[:2] for call in self._calls()], expected)

    def test_delete_missing_resources_is_idempotent(self):
        result = self._run("delete_project custom-cluster", {
            "project": None,
            "pipeline": None,
            "errors": {
                "codepipeline delete-pipeline": "PipelineNotFoundException",
                "codebuild delete-project": "ResourceNotFoundException",
            },
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[:2] for call in self._calls()], [
            ["codepipeline", "delete-pipeline"],
            ["codebuild", "delete-project"],
        ])

    def _read_bootstrap_descriptor(self, config, state=None, id_field="regional_id"):
        (self.root / "cluster.json").write_text(json.dumps(config))
        return self._run(
            f"_descriptor=$(read_cluster_iam_descriptor cluster.json {id_field})\n"
            'printf \'%s\\n\' "$_descriptor"',
            state,
        )

    def test_bootstrap_descriptor_accepts_literal_account_without_aws_lookup(self):
        for id_field in ("regional_id", "management_id"):
            with self.subTest(id_field=id_field):
                result = self._read_bootstrap_descriptor({
                    "region": "us-east-1",
                    id_field: "custom-cluster",
                    "account_id": "123456789012",
                    "child_admin_role_name": "rosa-seaplane-account-admin",
                }, id_field=id_field)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {
                    "project_name": "custom-cluster",
                    "account_id": "123456789012",
                    "child_admin_role_name": "rosa-seaplane-account-admin",
                })
                self.assertEqual(self._calls(), [])

    def test_bootstrap_descriptor_resolves_ssm_in_configured_region(self):
        self.env["REGION"] = "eu-west-1"
        result = self._read_bootstrap_descriptor({
            "region": "eu-west-1",
            "management_id": "custom-mc",
            "account_id": "ssm:///infra/test/account_id",
            "child_admin_role_name": "team/rosa-seaplane-account-admin",
        }, {"ssm_value": "210987654321"}, id_field="management_id")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "project_name": "custom-mc",
            "account_id": "210987654321",
            "child_admin_role_name": "team/rosa-seaplane-account-admin",
        })
        self.assertEqual(self._calls(), [[
            "ssm", "get-parameter", "--name", "/infra/test/account_id",
            "--with-decryption", "--query", "Parameter.Value", "--output", "text",
            "--region", "eu-west-1", "--no-cli-pager",
        ]])

    def test_bootstrap_descriptor_fails_closed_when_ssm_lookup_fails(self):
        result = self._read_bootstrap_descriptor({
            "region": "us-east-1",
            "regional_id": "custom-cluster",
            "account_id": "ssm:///infra/test/account_id",
            "child_admin_role_name": "OrganizationAccountAccessRole",
        }, {"errors": {"ssm get-parameter": "AccessDeniedException"}})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not resolve target account", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual([call[:2] for call in self._calls()], [["ssm", "get-parameter"]])

    def test_bootstrap_descriptor_rejects_invalid_accounts_roles_and_region(self):
        for field, value in (
            ("account_id", "12345678901*"),
            ("account_id", "12345678901"),
            ("account_id", 123456789012),
            ("child_admin_role_name", "team/*"),
            ("child_admin_role_name", "team//admin"),
            ("regional_id", "cluster*"),
            ("region", "eu-west-1"),
        ):
            with self.subTest(field=field, value=value):
                config = {
                    "region": "us-east-1",
                    "regional_id": "custom-cluster",
                    "account_id": "123456789012",
                    "child_admin_role_name": "OrganizationAccountAccessRole",
                    field: value,
                }
                result = self._read_bootstrap_descriptor(config)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR:", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(self._calls(), [])

    def test_bootstrap_descriptor_rejects_invalid_resolved_ssm_account(self):
        result = self._read_bootstrap_descriptor({
            "region": "us-east-1",
            "regional_id": "custom-cluster",
            "account_id": "ssm:///infra/test/account_id",
            "child_admin_role_name": "OrganizationAccountAccessRole",
        }, {"ssm_value": "12345678901*"})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Target account must resolve to a 12-digit ID", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_bootstrap_descriptor_rejects_missing_config(self):
        result = self._run("read_cluster_iam_descriptor missing.json regional_id")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid or missing rendered cluster IAM configuration", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self._calls(), [])


if __name__ == "__main__":
    unittest.main()
