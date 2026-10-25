import unittest
from unittest.mock import Mock, call, patch

from botocore.exceptions import ClientError
from codepipeline import (
    PipelineFailure,
    PipelineMonitor,
    _codepipeline_glob_match,
)


class PipelineMonitorTest(unittest.TestCase):
    def test_missing_pipelines_returns_only_not_found_names(self):
        codepipeline_client = Mock()
        codepipeline_client.get_pipeline.side_effect = [
            {"pipeline": {"name": "existing-pipeline"}},
            ClientError(
                {"Error": {"Code": "PipelineNotFoundException"}},
                "GetPipeline",
            ),
        ]
        session = Mock()
        session.client.return_value = codepipeline_client

        monitor = PipelineMonitor(session)

        self.assertEqual(
            monitor.missing_pipelines(["existing-pipeline", "new-pipeline"]),
            ["new-pipeline"],
        )

    def test_wait_for_creation_execution_uses_matching_source_revision(self):
        codepipeline_client = Mock()
        codepipeline_client.list_pipeline_executions.return_value = {
            "pipelineExecutionSummaries": [
                {
                    "pipelineExecutionId": "create-execution",
                    "sourceRevisions": [
                        {"actionName": "Source", "revisionId": "a" * 40}
                    ],
                }
            ]
        }
        session = Mock()
        session.client.return_value = codepipeline_client

        monitor = PipelineMonitor(session)

        self.assertEqual(
            monitor.wait_for_creation_execution("new-pipeline", "a" * 40),
            "create-execution",
        )

    def test_start_pipeline_uses_supported_source_revision_fields(self):
        codepipeline_client = Mock()
        codepipeline_client.start_pipeline_execution.return_value = {
            "pipelineExecutionId": "execution-123"
        }
        session = Mock()
        session.client.side_effect = lambda service: (
            codepipeline_client if service == "codepipeline" else Mock()
        )

        monitor = PipelineMonitor(session)
        execution_id = monitor.start_pipeline("cluster-pipeline", "a" * 40)

        self.assertEqual(execution_id, "execution-123")
        codepipeline_client.start_pipeline_execution.assert_called_once_with(
            name="cluster-pipeline",
            sourceRevisions=[
                {
                    "actionName": "Source",
                    "revisionType": "COMMIT_ID",
                    "revisionValue": "a" * 40,
                }
            ],
        )

    def test_start_or_reuse_pipeline_reuses_active_execution_at_requested_sha(self):
        codepipeline_client = Mock()
        codepipeline_client.list_pipeline_executions.return_value = {
            "pipelineExecutionSummaries": [
                {
                    "pipelineExecutionId": "active-execution",
                    "status": "InProgress",
                    "sourceRevisions": [
                        {"actionName": "Source", "revisionId": "a" * 40}
                    ],
                }
            ]
        }
        session = Mock()
        session.client.return_value = codepipeline_client

        monitor = PipelineMonitor(session)

        self.assertEqual(
            monitor.start_or_reuse_pipeline("cluster-pipeline", "a" * 40),
            "active-execution",
        )
        codepipeline_client.start_pipeline_execution.assert_not_called()

    def test_start_or_reuse_pipeline_rejects_active_execution_at_other_sha(self):
        codepipeline_client = Mock()
        codepipeline_client.list_pipeline_executions.return_value = {
            "pipelineExecutionSummaries": [
                {
                    "pipelineExecutionId": "active-execution",
                    "status": "InProgress",
                    "sourceRevisions": [
                        {"actionName": "Source", "revisionId": "b" * 40}
                    ],
                }
            ]
        }
        session = Mock()
        session.client.return_value = codepipeline_client

        monitor = PipelineMonitor(session)

        with self.assertRaisesRegex(PipelineFailure, "different or unavailable revision"):
            monitor.start_or_reuse_pipeline("cluster-pipeline", "a" * 40)
        codepipeline_client.start_pipeline_execution.assert_not_called()

    def test_cancelled_pipeline_is_terminal(self):
        codepipeline_client = Mock()
        codepipeline_client.get_pipeline_execution.return_value = {
            "pipelineExecution": {"status": "Cancelled"}
        }
        session = Mock()
        session.client.side_effect = lambda service: (
            codepipeline_client if service == "codepipeline" else Mock()
        )

        monitor = PipelineMonitor(session)
        results = monitor.wait_for_pipelines(
            [("eph-test-regional", "execution-123")],
            desired_sha="a" * 40,
            timeout=1,
        )

        self.assertEqual(results["eph-test-regional"].status, "CANCELLED")
        self.assertIn("Cancelled", results["eph-test-regional"].error)
        codepipeline_client.get_pipeline_execution.assert_called_once_with(
            pipelineName="eph-test-regional-pipeline",
            pipelineExecutionId="execution-123",
        )

    def test_cancelled_single_pipeline_raises_failure(self):
        codepipeline_client = Mock()
        codepipeline_client.get_pipeline_execution.return_value = {
            "pipelineExecution": {"status": "Cancelled"}
        }
        session = Mock()
        session.client.side_effect = lambda service: (
            codepipeline_client if service == "codepipeline" else Mock()
        )

        monitor = PipelineMonitor(session)
        with self.assertRaisesRegex(PipelineFailure, "status Cancelled"):
            monitor.wait_for_pipeline(
                "eph-test-regional-pipeline",
                "execution-123",
                desired_sha="a" * 40,
                timeout=1,
            )


class DisablePushTriggersTest(unittest.TestCase):
    def setUp(self):
        self.client = Mock()
        self.client.exceptions.PipelineNotFoundException = type(
            "PipelineNotFoundException", (ClientError,), {}
        )
        session = Mock()
        session.client.return_value = self.client
        self.monitor = PipelineMonitor(session)
        self.pipeline = {
            "name": "cluster-pipeline",
            "version": 3,
            "roleArn": "arn:aws:iam::123456789012:role/pipeline",
            "artifactStore": {"type": "S3", "location": "pipeline-artifacts"},
            "stages": [{"name": "Source", "actions": []}],
            "pipelineType": "V2",
            "executionMode": "SUPERSEDED",
            "triggers": [{"providerType": "CodeStarSourceConnection"}],
        }
        self.client.get_pipeline.return_value = {"pipeline": self.pipeline}

    def test_success_preserves_declaration_and_does_not_retry(self):
        expected = {**self.pipeline, "triggers": []}

        self.monitor.disable_push_triggers("cluster-pipeline")

        self.client.get_pipeline.assert_called_once_with(name="cluster-pipeline")
        self.client.update_pipeline.assert_called_once_with(pipeline=expected)

    def test_retry_refetches_and_preserves_complete_fresh_declaration(self):
        fresh = {
            **self.pipeline,
            "version": 4,
            "roleArn": "arn:aws:iam::123456789012:role/updated-pipeline",
            "stages": [
                {"name": "Source", "actions": []},
                {"name": "Build", "actions": []},
            ],
            "variables": [{"name": "IS_DESTROY", "defaultValue": "false"}],
        }
        expected_initial = {**self.pipeline, "triggers": []}
        expected_fresh = {**fresh, "triggers": []}
        self.client.get_pipeline.side_effect = [
            {"pipeline": self.pipeline},
            {"pipeline": fresh, "metadata": {"created": "ignored"}},
        ]
        self.client.update_pipeline.side_effect = [
            ClientError(
                {"Error": {"Code": "ServiceUnavailableException"}}, "UpdatePipeline"
            ),
            {},
        ]

        self.monitor.disable_push_triggers("cluster-pipeline")

        self.assertEqual(
            self.client.mock_calls,
            [
                call.get_pipeline(name="cluster-pipeline"),
                call.update_pipeline(pipeline=expected_initial),
                call.get_pipeline(name="cluster-pipeline"),
                call.update_pipeline(pipeline=expected_fresh),
            ],
        )

    def test_final_update_error_propagates_without_more_retries(self):
        self.client.get_pipeline.side_effect = [
            {"pipeline": {**self.pipeline}},
            {"pipeline": {**self.pipeline}},
        ]
        first_error = ClientError(
            {"Error": {"Code": "ServiceUnavailableException"}}, "UpdatePipeline"
        )
        final_error = ClientError(
            {"Error": {"Code": "AccessDeniedException"}}, "UpdatePipeline"
        )
        self.client.update_pipeline.side_effect = [first_error, final_error]

        with self.assertRaises(ClientError) as raised:
            self.monitor.disable_push_triggers("cluster-pipeline")

        self.assertIs(raised.exception, final_error)
        self.assertEqual(self.client.get_pipeline.call_count, 2)
        self.assertEqual(self.client.update_pipeline.call_count, 2)

    def test_lookup_permission_errors_are_not_ignored(self):
        error = ClientError(
            {"Error": {"Code": "AccessDeniedException"}}, "GetPipeline"
        )
        self.client.get_pipeline.side_effect = error

        with self.assertRaises(ClientError) as raised:
            self.monitor.disable_push_triggers("cluster-pipeline")

        self.assertIs(raised.exception, error)
        self.assertEqual(self.client.get_pipeline.call_count, 2)
        self.client.update_pipeline.assert_not_called()

    def test_missing_pipeline_is_safe(self):
        self.client.get_pipeline.side_effect = (
            self.client.exceptions.PipelineNotFoundException(
                {"Error": {"Code": "PipelineNotFoundException"}}, "GetPipeline"
            )
        )

        self.monitor.disable_push_triggers("cluster-pipeline")

        self.client.get_pipeline.assert_called_once_with(name="cluster-pipeline")
        self.client.update_pipeline.assert_not_called()

    def test_no_update_if_retry_finds_triggers_already_removed(self):
        self.client.get_pipeline.side_effect = [
            {"pipeline": self.pipeline},
            {"pipeline": {**self.pipeline, "triggers": []}},
        ]
        self.client.update_pipeline.side_effect = ClientError(
            {"Error": {"Code": "ServiceUnavailableException"}}, "UpdatePipeline"
        )

        self.monitor.disable_push_triggers("cluster-pipeline")

        self.assertEqual(self.client.get_pipeline.call_count, 2)
        self.client.update_pipeline.assert_called_once()


class StopActiveExecutionsTest(unittest.TestCase):
    def _monitor(self, status="InProgress"):
        client = Mock()
        client.list_pipeline_executions.return_value = {
            "pipelineExecutionSummaries": [
                {"pipelineExecutionId": "execution-123", "status": status}
            ]
        }
        session = Mock()
        session.client.return_value = client
        return PipelineMonitor(session), client

    @patch("codepipeline.time.sleep")
    def test_waits_for_running_action_after_graceful_stop(self, sleep):
        monitor, client = self._monitor()
        client.get_pipeline_execution.side_effect = [
            {"pipelineExecution": {"status": "Stopping"}},
            {"pipelineExecution": {"status": "Stopped"}},
        ]

        monitor.stop_active_executions(["cluster-pipeline"])

        client.stop_pipeline_execution.assert_called_once_with(
            pipelineName="cluster-pipeline",
            pipelineExecutionId="execution-123",
            abandon=False,
            reason="Teardown requested; waiting for active actions to finish",
        )
        self.assertEqual(client.get_pipeline_execution.call_count, 2)
        sleep.assert_called_once()

    def test_already_stopping_execution_must_finish(self):
        monitor, client = self._monitor(status="Stopping")
        client.get_pipeline_execution.return_value = {
            "pipelineExecution": {"status": "Stopping"}
        }

        with self.assertRaisesRegex(TimeoutError, "Infrastructure teardown was not started"):
            monitor.stop_active_executions(["cluster-pipeline"], timeout=0)

        client.stop_pipeline_execution.assert_not_called()
        client.get_pipeline_execution.assert_called_once()

    def test_requests_all_stops_before_waiting_for_actions(self):
        monitor, client = self._monitor()
        client.get_pipeline_execution.return_value = {
            "pipelineExecution": {"status": "Stopped"}
        }

        monitor.stop_active_executions(["rc-pipeline", "mc-pipeline"])

        operations = [operation[0] for operation in client.mock_calls]
        self.assertEqual(
            operations,
            [
                "list_pipeline_executions", "stop_pipeline_execution",
                "list_pipeline_executions", "stop_pipeline_execution",
                "get_pipeline_execution", "get_pipeline_execution",
            ],
        )

    def test_stop_error_prevents_teardown_from_proceeding(self):
        monitor, client = self._monitor()
        client.stop_pipeline_execution.side_effect = ClientError(
            {"Error": {"Code": "AccessDeniedException"}}, "StopPipelineExecution"
        )

        with self.assertRaisesRegex(PipelineFailure, "Could not stop execution"):
            monitor.stop_active_executions(["cluster-pipeline"])

        client.get_pipeline_execution.assert_not_called()


class CodePipelineGlobTest(unittest.TestCase):
    def test_brace_alternation_matches_each_branch(self):
        pattern = "terraform/config/{management-cluster,kube-applier-dynamodb-provisioning}/**"
        self.assertTrue(
            _codepipeline_glob_match(
                "terraform/config/management-cluster/main.tf", pattern
            )
        )
        self.assertTrue(
            _codepipeline_glob_match(
                "terraform/config/kube-applier-dynamodb-provisioning/x/y.tf", pattern
            )
        )
        self.assertFalse(
            _codepipeline_glob_match("terraform/config/regional-cluster/main.tf", pattern)
        )

    def test_single_star_does_not_cross_separator(self):
        self.assertFalse(_codepipeline_glob_match("a/b/c.txt", "a/*"))
        self.assertTrue(_codepipeline_glob_match("a/b.txt", "a/*"))

    def test_globstar_matches_zero_or_more_segments(self):
        self.assertTrue(_codepipeline_glob_match("a/b", "a/**/b"))
        self.assertTrue(_codepipeline_glob_match("a/x/b", "a/**/b"))
        self.assertTrue(_codepipeline_glob_match("a/x/y/b", "a/**/b"))
        self.assertTrue(_codepipeline_glob_match("a/file", "a/**"))

    def test_globstar_directory_prefix_requires_complete_segments(self):
        for pattern in ("**/b", "a/**/b", "{a,c}/**/b"):
            prefix = "" if pattern == "**/b" else "a/"
            for path in ("b", "x/b", "x/y/b"):
                with self.subTest(pattern=pattern, path=prefix + path):
                    self.assertTrue(_codepipeline_glob_match(prefix + path, pattern))
            for path in ("xb", "x/yb", "x/bc"):
                with self.subTest(pattern=pattern, path=prefix + path):
                    self.assertFalse(_codepipeline_glob_match(prefix + path, pattern))

    def test_push_trigger_matches_real_rc_filter(self):
        pipeline = {
            "triggers": [
                {
                    "providerType": "CodeStarSourceConnection",
                    "gitConfiguration": {
                        "push": [
                            {
                                "branches": {"includes": ["eph-abc"]},
                                "filePaths": {
                                    "includes": [
                                        "terraform/config/regional-cluster/**"
                                    ]
                                },
                            }
                        ]
                    },
                }
            ]
        }
        self.assertTrue(
            PipelineMonitor.push_trigger_matches(
                pipeline, "eph-abc", ["terraform/config/regional-cluster/main.tf"]
            )
        )
        self.assertFalse(
            PipelineMonitor.push_trigger_matches(
                pipeline, "eph-abc", ["docs/README.md"]
            )
        )


class HasSuccessfulExecutionTest(unittest.TestCase):
    def _monitor(self, summaries):
        client = Mock()
        client.list_pipeline_executions.return_value = {
            "pipelineExecutionSummaries": summaries
        }
        session = Mock()
        session.client.return_value = client
        return PipelineMonitor(session)

    def test_newest_failed_does_not_fall_back_to_older_success(self):
        monitor = self._monitor(
            [
                {
                    "pipelineExecutionId": "newer",
                    "status": "Failed",
                    "startTime": "2026-02-02",
                    "sourceRevisions": [{"actionName": "Source", "revisionId": "b" * 40}],
                },
                {
                    "pipelineExecutionId": "older",
                    "status": "Succeeded",
                    "startTime": "2026-01-01",
                    "sourceRevisions": [{"actionName": "Source", "revisionId": "a" * 40}],
                },
            ]
        )
        self.assertIsNone(monitor.has_successful_execution("cluster-pipeline"))

    def test_skips_nonterminal_then_returns_newest_success(self):
        monitor = self._monitor(
            [
                {
                    "pipelineExecutionId": "running",
                    "status": "InProgress",
                    "startTime": "2026-03-03",
                    "sourceRevisions": [{"actionName": "Source", "revisionId": "c" * 40}],
                },
                {
                    "pipelineExecutionId": "newest-success",
                    "status": "Succeeded",
                    "startTime": "2026-02-02",
                    "sourceRevisions": [{"actionName": "Source", "revisionId": "b" * 40}],
                },
            ]
        )
        self.assertEqual(
            monitor.has_successful_execution("cluster-pipeline"),
            ("newest-success", "b" * 40),
        )


if __name__ == "__main__":
    unittest.main()
