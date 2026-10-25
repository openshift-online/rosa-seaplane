import logging
import re
import time
from dataclasses import dataclass

import boto3
from botocore.exceptions import ClientError

from __init__ import BUILD_COMPLETION_TIMEOUT, POLL_INTERVAL
from codebuild import BuildMonitor, BuildResult

log = logging.getLogger(__name__)


def _codepipeline_glob_to_regex(pattern: str) -> str:
    """Translate a CodePipeline branches/filePaths glob into a regex string.

    Follows AWS's documented glob semantics, which differ from Python's
    ``fnmatch``: ``*`` matches within a single path segment (never ``/``),
    ``**`` crosses directory boundaries (zero or more segments), ``?`` matches
    one non-separator character, ``[...]`` is a character class, and ``{a,b}``
    is alternation (groups cannot be nested). See
    https://docs.aws.amazon.com/codepipeline/latest/userguide/syntax-glob.html
    """
    i = 0
    n = len(pattern)
    out: list[str] = []
    brace_depth = 0
    while i < n:
        c = pattern[i]
        if c == "*":
            if i + 1 < n and pattern[i + 1] == "*":
                i += 2
                if i < n and pattern[i] == "/":
                    # Match zero or more complete directory components.
                    out.append("(?:[^/]+/)*")
                    i += 1
                else:
                    out.append(".*")
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = i + 1
            if j < n and pattern[j] in "!^":
                j += 1
            if j < n and pattern[j] == "]":
                j += 1
            while j < n and pattern[j] != "]":
                j += 1
            if j >= n:
                out.append(re.escape(c))
            else:
                inner = pattern[i + 1 : j]
                if inner[:1] in ("!", "^"):
                    inner = "^" + inner[1:]
                out.append("[" + inner + "]")
                i = j + 1
                continue
        elif c == "{":
            brace_depth += 1
            out.append("(?:")
        elif c == "}" and brace_depth:
            brace_depth -= 1
            out.append(")")
        elif c == "," and brace_depth:
            out.append("|")
        else:
            out.append(re.escape(c))
        i += 1
    return "".join(out)


def _codepipeline_glob_match(value: str, pattern: str) -> bool:
    """Full-match ``value`` against a CodePipeline glob ``pattern``.

    Passes the regex as a string so the stdlib ``re`` module caches the
    compiled pattern internally (re._cache) — no cache maintained here.
    """
    return re.fullmatch(_codepipeline_glob_to_regex(pattern), value) is not None


PIPELINE_LOOKUP_GRACE_PERIOD = 300
PIPELINE_LOOKUP_NOT_FOUND_ERRORS = {
    "PipelineExecutionNotFoundException",
    "PipelineNotFoundException",
}


@dataclass
class _PipelineWaitState:
    pipeline_name: str
    execution_id: str
    status: str = "PENDING"
    done: bool = False
    not_found_since: float | None = None
    not_found_code: str | None = None
    build_id: str | None = None
    error: str | None = None
    failure_logged: bool = False


class PipelineFailure(RuntimeError):
    """A terminal CodePipeline execution failure."""


class PipelineMonitor:
    """Start and monitor CodePipeline executions backed by CodeBuild actions."""

    def __init__(self, session: boto3.Session):
        self.session = session
        self.client = session.client("codepipeline")
        self.build_monitor = BuildMonitor(session)

    @staticmethod
    def pipeline_name(project_name: str) -> str:
        return f"{project_name}-pipeline"

    def missing_pipelines(self, pipeline_names: list[str]) -> list[str]:
        """Return pipeline names that do not exist yet; fail on other lookup errors."""
        missing = []
        for pipeline_name in pipeline_names:
            try:
                self.client.get_pipeline(name=pipeline_name)
            except ClientError as exc:
                error_code = exc.response.get("Error", {}).get("Code", "Unknown")
                if error_code == "PipelineNotFoundException":
                    missing.append(pipeline_name)
                    continue
                raise RuntimeError(
                    f"Unable to check whether CodePipeline {pipeline_name} exists: {exc}"
                ) from exc
        return missing

    def wait_for_creation_execution(
        self,
        pipeline_name: str,
        source_version: str,
        timeout: int = PIPELINE_LOOKUP_GRACE_PERIOD,
    ) -> str:
        """Find the automatic execution started by CreatePipeline at the expected SHA."""
        return self.wait_for_revision_execution(
            pipeline_name,
            source_version,
            timeout=timeout,
            start_reason="pipeline creation",
        )

    def wait_for_revision_execution(
        self,
        pipeline_name: str,
        source_version: str,
        timeout: int = PIPELINE_LOOKUP_GRACE_PERIOD,
        start_reason: str = "push trigger",
    ) -> str:
        """Wait for an automatically started execution at the requested revision."""
        started_at = time.monotonic()
        while True:
            try:
                response = self.client.list_pipeline_executions(
                    pipelineName=pipeline_name,
                    maxResults=100,
                )
            except ClientError as exc:
                error_code = exc.response.get("Error", {}).get("Code", "Unknown")
                if error_code != "PipelineNotFoundException":
                    raise PipelineFailure(
                        f"Unable to list executions for CodePipeline {pipeline_name} "
                        f"(AWS error {error_code}): {exc}"
                    ) from exc
                response = {}

            matching = [
                execution
                for execution in response.get("pipelineExecutionSummaries", [])
                if any(
                    revision.get("actionName") == "Source"
                    and revision.get("revisionId") == source_version
                    for revision in execution.get("sourceRevisions", [])
                )
            ]
            matching.sort(
                key=lambda execution: str(execution.get("startTime") or ""),
                reverse=True,
            )
            for execution in matching:
                execution_id = execution.get("pipelineExecutionId")
                if execution_id:
                    log.info(
                        "Adopting %s execution %s for pipeline %s at SHA %s",
                        start_reason,
                        execution_id,
                        pipeline_name,
                        source_version[:7],
                    )
                    return execution_id

            elapsed = time.monotonic() - started_at
            if elapsed >= timeout:
                raise PipelineFailure(
                    f"No {start_reason} execution for {pipeline_name} at SHA "
                    f"{source_version[:7]} became visible after {int(elapsed)}s; "
                    "not starting a second execution. Check the pipeline execution history "
                    "and resume after resolving the issue."
                )

            log.info(
                "Waiting for the %s execution for %s at SHA %s (%ds/%ds)",
                start_reason,
                pipeline_name,
                source_version[:7],
                int(elapsed),
                timeout,
            )
            time.sleep(min(POLL_INTERVAL, timeout - elapsed))

    def push_trigger_configs(self, pipeline_names: list[str]) -> dict[str, dict | None]:
        """Read existing pipelines' push-trigger configuration."""
        configs = {}
        for pipeline_name in pipeline_names:
            try:
                response = self.client.get_pipeline(name=pipeline_name)
            except ClientError as exc:
                error_code = exc.response.get("Error", {}).get("Code", "Unknown")
                if error_code == "PipelineNotFoundException":
                    configs[pipeline_name] = None
                    continue
                raise PipelineFailure(
                    f"Unable to inspect push triggers for pipeline {pipeline_name} "
                    f"(AWS error {error_code}): {exc}"
                ) from exc
            configs[pipeline_name] = response.get("pipeline", {})
        return configs

    @staticmethod
    def push_trigger_matches(
        pipeline: dict | None,
        branch: str,
        changed_paths: list[str],
    ) -> bool:
        """Return whether a CodeStar push trigger matches a branch update."""
        if not pipeline or not changed_paths:
            return False

        def matches_filter(value: str, rule: dict | None) -> bool:
            rule = rule or {}
            includes = rule.get("includes", [])
            excludes = rule.get("excludes", [])
            return (
                (not includes or any(_codepipeline_glob_match(value, pattern) for pattern in includes))
                and not any(_codepipeline_glob_match(value, pattern) for pattern in excludes)
            )

        for trigger in pipeline.get("triggers", []):
            if trigger.get("providerType") != "CodeStarSourceConnection":
                continue
            git_config = trigger.get("gitConfiguration", {})
            for push in git_config.get("push", []):
                if not matches_filter(branch, push.get("branches")):
                    continue
                path_filter = push.get("filePaths")
                if path_filter is None or any(
                    matches_filter(path, path_filter) for path in changed_paths
                ):
                    return True
        return False

    def has_successful_execution(self, pipeline_name: str) -> tuple[str, str] | None:
        """Return the latest successful execution ID and source SHA, if any."""
        try:
            response = self.client.list_pipeline_executions(
                pipelineName=pipeline_name,
                maxResults=100,
            )
        except self.client.exceptions.PipelineNotFoundException:
            return None

        executions = response.get("pipelineExecutionSummaries", [])
        executions.sort(
            key=lambda execution: str(execution.get("startTime") or ""),
            reverse=True,
        )
        for execution in executions:
            status = execution.get("status")
            if status in ("InProgress", "Stopping", "Queued"):
                # Skip non-terminal executions; only judge completed ones.
                continue
            if status != "Succeeded":
                # The newest terminal execution did not succeed. Do not fall
                # back to an older success, or a failed latest apply would be
                # reported as a retained success.
                return None
            execution_id = execution.get("pipelineExecutionId")
            source_sha = next(
                (
                    revision.get("revisionId")
                    for revision in execution.get("sourceRevisions", [])
                    if revision.get("actionName") == "Source"
                ),
                None,
            )
            if execution_id and source_sha:
                return execution_id, source_sha
        return None

    def start_pipeline(
        self,
        pipeline_name: str,
        source_version: str,
        environment_variables: dict[str, str] | None = None,
    ) -> str:
        """Start a pipeline at a commit, optionally setting pipeline variables."""
        request = {
            "name": pipeline_name,
            "sourceRevisions": [
                {
                    "actionName": "Source",
                    "revisionType": "COMMIT_ID",
                    "revisionValue": source_version,
                }
            ],
        }
        if environment_variables:
            request["variables"] = [
                {"name": name, "value": value}
                for name, value in environment_variables.items()
            ]

        try:
            response = self.client.start_pipeline_execution(**request)
        except self.client.exceptions.PipelineNotFoundException as exc:
            raise RuntimeError(
                f"CodePipeline not found: {pipeline_name}. "
                "Ensure provision-cluster-resources.sh ran successfully."
            ) from exc

        execution_id = response["pipelineExecutionId"]
        log.info(
            "Started pipeline %s at SHA %s: %s",
            pipeline_name,
            source_version[:7],
            execution_id,
        )
        return execution_id

    def start_or_reuse_pipeline(
        self,
        pipeline_name: str,
        source_version: str,
        start_if_idle: bool = True,
    ) -> str | None:
        """Reuse a matching active execution; start only when idle and requested."""
        try:
            response = self.client.list_pipeline_executions(
                pipelineName=pipeline_name,
                maxResults=100,
            )
        except self.client.exceptions.PipelineNotFoundException:
            return (
                self.start_pipeline(pipeline_name, source_version)
                if start_if_idle
                else None
            )

        active = [
            execution
            for execution in response.get("pipelineExecutionSummaries", [])
            if execution.get("status") in ("InProgress", "Stopping", "Queued")
        ]
        matching_active = [
            execution
            for execution in active
            if any(
                revision.get("actionName") == "Source"
                and revision.get("revisionId") == source_version
                for revision in execution.get("sourceRevisions", [])
            )
        ]
        matching_active.sort(
            key=lambda execution: str(execution.get("startTime") or ""),
            reverse=True,
        )
        if matching_active:
            execution_id = matching_active[0].get("pipelineExecutionId")
            if execution_id:
                log.info(
                    "Reusing active pipeline %s execution %s at SHA %s",
                    pipeline_name,
                    execution_id,
                    source_version[:7],
                )
                return execution_id

        if active:
            active.sort(
                key=lambda item: str(item.get("startTime") or ""),
                reverse=True,
            )
            execution = active[0]
            execution_id = execution.get("pipelineExecutionId")
            active_sha = next(
                (
                    revision.get("revisionId")
                    for revision in execution.get("sourceRevisions", [])
                    if revision.get("actionName") == "Source"
                ),
                None,
            )
            raise PipelineFailure(
                f"Cannot start {pipeline_name} at SHA {source_version[:7]} while execution "
                f"{execution_id or 'unknown'} is active at SHA "
                f"{active_sha[:7] if active_sha else 'unknown'}. "
                "An active execution is at a different or unavailable revision. "
                "Wait for it to finish and retry."
            )

        if not start_if_idle:
            return None
        return self.start_pipeline(pipeline_name, source_version)

    def active_pipelines(self, pipeline_names: list[str]) -> list[str]:
        """Return active execution IDs for the selected pipelines."""
        active = []
        for pipeline_name in pipeline_names:
            try:
                response = self.client.list_pipeline_executions(
                    pipelineName=pipeline_name,
                    maxResults=100,
                )
            except self.client.exceptions.PipelineNotFoundException:
                continue
            for execution in response.get("pipelineExecutionSummaries", []):
                if execution.get("status") in ("InProgress", "Stopping", "Queued"):
                    active.append(
                        f"{pipeline_name}:{execution.get('pipelineExecutionId', 'unknown')}"
                    )
        return active

    def disable_push_triggers(self, pipeline_name: str) -> None:
        """Remove push triggers from a pipeline.

        Used before teardown: under SUPERSEDED execution mode a push to the
        branch during or after a destroy would otherwise queue an apply that
        recreates the cluster. Idempotent and safe if the pipeline is missing.
        Retry an AWS error once with a fresh declaration, then fail closed.
        """
        for attempt in range(2):
            try:
                try:
                    response = self.client.get_pipeline(name=pipeline_name)
                except self.client.exceptions.PipelineNotFoundException:
                    return
                pipeline = response.get("pipeline", {})
                if not pipeline.get("triggers"):
                    return
                pipeline["triggers"] = []
                self.client.update_pipeline(pipeline=pipeline)
            except ClientError:
                if attempt:
                    raise
                log.warning(
                    "Failed to remove push triggers from pipeline %s; "
                    "retrying with a fresh declaration",
                    pipeline_name,
                )
                continue
            log.info("Removed push triggers from pipeline %s", pipeline_name)
            return

    def stop_active_executions(
        self,
        pipeline_names: list[str],
        timeout: int = BUILD_COMPLETION_TIMEOUT,
    ) -> None:
        """Stop and drain active executions before starting infrastructure teardown.

        Abandoning an execution does not stop the provider's running actions.
        Let those actions finish and fail closed if they cannot be drained.
        Safe if a pipeline is already missing.
        """
        deadline = time.monotonic() + timeout
        pending = []
        for pipeline_name in pipeline_names:
            try:
                response = self.client.list_pipeline_executions(
                    pipelineName=pipeline_name,
                    maxResults=100,
                )
            except self.client.exceptions.PipelineNotFoundException:
                continue
            for execution in response.get("pipelineExecutionSummaries", []):
                status = execution.get("status")
                if status not in ("InProgress", "Queued", "Stopping"):
                    continue
                execution_id = execution.get("pipelineExecutionId")
                if not execution_id:
                    raise PipelineFailure(
                        f"Cannot stop active execution without an ID on {pipeline_name}"
                    )
                pending.append((pipeline_name, execution_id))
                if status == "Stopping":
                    continue
                try:
                    self.client.stop_pipeline_execution(
                        pipelineName=pipeline_name,
                        pipelineExecutionId=execution_id,
                        abandon=False,
                        reason="Teardown requested; waiting for active actions to finish",
                    )
                    log.info(
                        "Requested graceful stop of execution %s on %s",
                        execution_id,
                        pipeline_name,
                    )
                except ClientError as exc:
                    error_code = exc.response.get("Error", {}).get("Code", "Unknown")
                    # The execution can finish or enter Stopping after listing.
                    # Re-read its status below instead of proceeding unchecked.
                    if error_code not in (
                        "PipelineExecutionNotStoppableException",
                        "DuplicatedStopRequestException",
                    ):
                        raise PipelineFailure(
                            f"Could not stop execution {execution_id} on "
                            f"{pipeline_name}: {exc}"
                        ) from exc

        while pending:
            remaining_executions = []
            for pipeline_name, execution_id in pending:
                response = self.client.get_pipeline_execution(
                    pipelineName=pipeline_name,
                    pipelineExecutionId=execution_id,
                )
                status = response.get("pipelineExecution", {}).get("status")
                if status in ("Succeeded", "Failed", "Stopped", "Superseded", "Cancelled"):
                    log.info("Execution %s on %s drained (%s)", execution_id, pipeline_name, status)
                    continue
                remaining_executions.append((pipeline_name, execution_id))
            pending = remaining_executions
            if not pending:
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f"Active pipeline executions did not drain within {timeout}s: "
                    + ", ".join(f"{name}:{execution_id}" for name, execution_id in pending)
                    + ". Infrastructure teardown was not started."
                )
            log.info(
                "Waiting for %d stopped pipeline execution(s) to finish active actions",
                len(pending),
            )
            time.sleep(min(POLL_INTERVAL, remaining))

    def _build_execution_id(self, pipeline_name: str, pipeline_execution_id: str) -> str | None:
        response = self.client.list_action_executions(
            pipelineName=pipeline_name,
            filter={"pipelineExecutionId": pipeline_execution_id},
            maxResults=100,
        )
        for action in response.get("actionExecutionDetails", []):
            if action.get("actionName") != "ApplyInfrastructure":
                continue
            result = (action.get("output") or {}).get("executionResult") or {}
            external_id = result.get("externalExecutionId")
            if external_id:
                return external_id
        return None

    def wait_for_pipelines(
        self,
        builds: list[tuple[str, str]],
        desired_sha: str,
        timeout: int = BUILD_COMPLETION_TIMEOUT,
    ) -> dict[str, BuildResult]:
        """Poll pipelines in caller order, then validate their CodeBuild results.

        Each tuple contains a project name and its pipeline execution ID. The
        caller supplies RC first, followed by MC projects, so each poll cycle
        reports the regional pipeline before management-cluster pipelines.
        """
        states = {
            project_name: _PipelineWaitState(
                pipeline_name=self.pipeline_name(project_name),
                execution_id=execution_id,
            )
            for project_name, execution_id in builds
        }
        monitor_start = time.monotonic()

        while not all(state.done for state in states.values()):
            for index, (project_name, _) in enumerate(builds):
                state = states[project_name]
                role = "RC" if index == 0 else "MC"

                if not state.done:
                    try:
                        response = self.client.get_pipeline_execution(
                            pipelineName=state.pipeline_name,
                            pipelineExecutionId=state.execution_id,
                        )
                    except ClientError as exc:
                        error_code = exc.response.get("Error", {}).get("Code", "Unknown")
                        if error_code in PIPELINE_LOOKUP_NOT_FOUND_ERRORS:
                            now = time.monotonic()
                            if state.not_found_since is None:
                                state.not_found_since = now
                            state.not_found_code = error_code
                            not_found_duration = now - state.not_found_since
                            if not_found_duration >= PIPELINE_LOOKUP_GRACE_PERIOD:
                                state.status = "LOOKUP_FAILED"
                                state.error = (
                                    f"AWS returned {state.not_found_code} for pipeline "
                                    f"{state.pipeline_name} execution "
                                    f"{state.execution_id}; it remained unavailable after "
                                    f"{int(not_found_duration)}s"
                                )
                                state.done = True
                            else:
                                state.status = (
                                    f"LOOKUP_PENDING ({int(not_found_duration)}/"
                                    f"{PIPELINE_LOOKUP_GRACE_PERIOD}s)"
                                )
                        else:
                            state.status = "ERROR"
                            state.error = (
                                f"Unable to read pipeline {state.pipeline_name} execution "
                                f"{state.execution_id} status (AWS error {error_code}): {exc}"
                            )
                            state.done = True
                    except Exception as exc:
                        state.status = "ERROR"
                        state.error = (
                            f"Unable to read pipeline {state.pipeline_name} execution "
                            f"{state.execution_id} status: {exc}"
                        )
                        state.done = True
                    else:
                        state.not_found_since = None
                        state.not_found_code = None
                        state.status = response.get("pipelineExecution", {}).get(
                            "status", "Unknown"
                        )
                        if state.status == "Succeeded":
                            try:
                                state.build_id = self._build_execution_id(
                                    state.pipeline_name, state.execution_id
                                )
                            except Exception as exc:
                                state.status = "ERROR"
                                state.error = (
                                    f"Unable to find the CodeBuild execution for pipeline "
                                    f"{state.pipeline_name}: {exc}"
                                )
                                state.done = True
                            else:
                                if not state.build_id:
                                    state.status = "ERROR"
                                    state.error = (
                                        f"Pipeline {state.pipeline_name} succeeded without "
                                        "a CodeBuild execution ID"
                                    )
                                state.done = True
                        elif state.status in ("Failed", "Stopped", "Superseded", "Cancelled"):
                            state.error = (
                                f"Pipeline {state.pipeline_name} execution "
                                f"{state.execution_id} ended with status {state.status}"
                            )
                            state.done = True

                log.info(
                    "%s pipeline %s execution %s status: %s",
                    role,
                    state.pipeline_name,
                    state.execution_id,
                    state.status,
                )
                if state.error and not state.failure_logged:
                    log.error("%s pipeline failure: %s", role, state.error)
                    state.failure_logged = True

            if all(state.done for state in states.values()):
                break

            remaining = timeout - (time.monotonic() - monitor_start)
            if remaining <= 0:
                for index, (project_name, _) in enumerate(builds):
                    state = states[project_name]
                    if state.done:
                        continue
                    role = "RC" if index == 0 else "MC"
                    state.status = "TIMED_OUT"
                    state.error = (
                        f"Pipeline {state.pipeline_name} execution {state.execution_id} "
                        f"did not complete within {timeout}s"
                    )
                    state.done = True
                    log.error("%s pipeline failure: %s", role, state.error)
                    state.failure_logged = True
                break

            time.sleep(min(POLL_INTERVAL, remaining))

        results = {}
        for project_name, execution_id in builds:
            state = states[project_name]
            if state.error:
                results[project_name] = BuildResult(
                    build_id=state.build_id or execution_id,
                    status=state.status.upper().split(" ", 1)[0],
                    total_duration=None,
                    error=state.error,
                )
                continue

            if not state.build_id:
                results[project_name] = BuildResult(
                    build_id=execution_id,
                    status="ERROR",
                    total_duration=None,
                    error=f"Pipeline {state.pipeline_name} has no CodeBuild execution ID",
                )
                continue

            try:
                result = self.build_monitor.wait_for_build(
                    state.build_id,
                    desired_sha,
                    timeout=timeout,
                )
            except Exception as exc:
                result = getattr(exc, "result", None)
                if result is None:
                    result = BuildResult(
                        build_id=state.build_id or execution_id,
                        status="ERROR",
                        total_duration=None,
                        error=str(exc),
                    )
            results[project_name] = result

        return results

    def wait_for_pipeline(
        self,
        pipeline_name: str,
        pipeline_execution_id: str,
        desired_sha: str,
        timeout: int = BUILD_COMPLETION_TIMEOUT,
    ) -> BuildResult:
        """Wait for a pipeline and validate its underlying CodeBuild contract."""
        log.info(
            "Waiting for pipeline %s execution %s (desired SHA: %s)",
            pipeline_name,
            pipeline_execution_id,
            desired_sha[:7],
        )
        monitor_start = time.monotonic()
        execution_not_found_since = None
        execution_not_found_code = None
        while time.monotonic() - monitor_start < timeout:
            try:
                response = self.client.get_pipeline_execution(
                    pipelineName=pipeline_name,
                    pipelineExecutionId=pipeline_execution_id,
                )
            except ClientError as exc:
                error_code = exc.response.get("Error", {}).get("Code", "Unknown")
                if error_code in PIPELINE_LOOKUP_NOT_FOUND_ERRORS:
                    now = time.monotonic()
                    if execution_not_found_since is None:
                        execution_not_found_since = now
                    execution_not_found_code = error_code
                    not_found_duration = now - execution_not_found_since
                    if not_found_duration >= PIPELINE_LOOKUP_GRACE_PERIOD:
                        raise PipelineFailure(
                            f"AWS returned {execution_not_found_code} for pipeline "
                            f"{pipeline_name} execution {pipeline_execution_id} "
                            f"and it remained unavailable after {int(not_found_duration)}s"
                        ) from exc
                    log.warning(
                        "Pipeline %s execution %s is not visible yet; retrying in %ds "
                        "(%.0fs elapsed)",
                        pipeline_name,
                        pipeline_execution_id,
                        POLL_INTERVAL,
                        not_found_duration,
                    )
                    time.sleep(POLL_INTERVAL)
                    continue

                raise PipelineFailure(
                    f"Unable to read pipeline {pipeline_name} execution "
                    f"{pipeline_execution_id} status (AWS error {error_code}): {exc}"
                ) from exc

            execution_not_found_since = None
            execution_not_found_code = None
            execution = response.get("pipelineExecution", {})
            status = execution.get("status", "Unknown")
            log.info(
                "Pipeline %s execution %s status: %s",
                pipeline_name,
                pipeline_execution_id,
                status,
            )

            if status == "Succeeded":
                build_id = self._build_execution_id(pipeline_name, pipeline_execution_id)
                if not build_id:
                    raise PipelineFailure(
                        f"Pipeline {pipeline_name} succeeded without a CodeBuild execution ID"
                    )
                return self.build_monitor.wait_for_build(build_id, desired_sha, timeout)

            if status in ("Failed", "Stopped", "Superseded", "Cancelled"):
                raise PipelineFailure(
                    f"Pipeline {pipeline_name} execution {pipeline_execution_id} ended with "
                    f"status {status}"
                )

            time.sleep(POLL_INTERVAL)

        raise TimeoutError(
            f"Pipeline {pipeline_name} execution {pipeline_execution_id} did not complete "
            f"within {timeout}s"
        )

    @staticmethod
    def _format_duration(seconds: float | None) -> str:
        return BuildMonitor._format_duration(seconds)
