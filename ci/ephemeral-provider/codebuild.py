import logging
import time
from dataclasses import dataclass, field

import boto3

from __init__ import POLL_INTERVAL, BUILD_COMPLETION_TIMEOUT

log = logging.getLogger(__name__)

BUILD_PROGRESS_LOG_INTERVAL = 300


@dataclass
class BuildResult:
    """Terminal result and diagnostics for one CodeBuild execution."""

    build_id: str
    status: str
    total_duration: float | None
    phases: list[dict] = field(default_factory=list)
    error: str | None = None
    log_url: str | None = None
    source_version: str = ""
    resolved_source_version: str = ""
    initiator: str | None = None


class BuildFailure(RuntimeError):
    """A build failure carrying the CodeBuild result for final reporting."""

    def __init__(self, message: str, result: BuildResult):
        super().__init__(message)
        self.result = result


class BuildMonitor:
    """Monitor AWS CodeBuild builds.

    Monitors the CodeBuild action executed by a CodePipeline.

    No prefix discovery — project names are deterministic (read from rendered config).
    """

    def __init__(self, session: boto3.Session):
        """
        Args:
            session: boto3 Session configured for the target account/region.
        """
        self.session = session
        self.client = session.client("codebuild")

    def active_builds(self, project_names: list[str]) -> list[str]:
        """Return IDs of queued or running builds for the given projects."""
        active = []
        for project_name in project_names:
            try:
                response = self.client.list_builds_for_project(
                    projectName=project_name,
                    sortOrder="DESCENDING",
                )
            except self.client.exceptions.ResourceNotFoundException:
                continue

            build_ids = response.get("ids", [])
            if not build_ids:
                continue

            builds = self.client.batch_get_builds(ids=build_ids).get("builds", [])
            active.extend(
                build["id"]
                for build in builds
                if build.get("buildStatus") in ("QUEUED", "IN_PROGRESS")
            )
        return active

    @staticmethod
    def _timestamp_seconds(value) -> float | None:
        """Return an AWS timestamp as seconds, when one is available."""
        if value is None:
            return None
        if hasattr(value, "timestamp"):
            return value.timestamp()
        if isinstance(value, (int, float)):
            return float(value)
        return None

    @classmethod
    def _phase_duration(cls, phase: dict) -> float | None:
        """Calculate a CodeBuild phase duration from its AWS timestamps."""
        start = cls._timestamp_seconds(phase.get("startTime"))
        if start is None:
            return None
        end = cls._timestamp_seconds(phase.get("endTime")) or time.time()
        return max(0.0, end - start)

    @classmethod
    def _build_duration(cls, build: dict, monitor_start: float) -> float:
        start = cls._timestamp_seconds(build.get("startTime"))
        end = cls._timestamp_seconds(build.get("endTime"))
        if start is not None:
            return max(0.0, (end or time.time()) - start)
        return max(0.0, time.monotonic() - monitor_start)

    @staticmethod
    def _format_duration(seconds: float | None) -> str:
        if seconds is None:
            return "unknown"
        seconds = max(0, int(round(seconds)))
        minutes, remainder = divmod(seconds, 60)
        hours, minutes = divmod(minutes, 60)
        if hours:
            return f"{hours}h {minutes}m {remainder}s"
        if minutes:
            return f"{minutes}m {remainder}s"
        return f"{remainder}s"

    def _build_result(
        self,
        build: dict,
        monitor_start: float,
        error: str | None = None,
    ) -> BuildResult:
        phases = []
        current_phase = build.get("currentPhase")
        for phase in build.get("phases") or []:
            phase_type = phase.get("phaseType")
            if not phase_type:
                continue
            phases.append(
                {
                    "name": phase_type,
                    "status": phase.get("phaseStatus")
                    or ("IN_PROGRESS" if phase_type == current_phase else "UNKNOWN"),
                    "duration": self._phase_duration(phase),
                }
            )

        return BuildResult(
            build_id=build.get("id", "unknown"),
            # An AWS success can still fail our SHA/application contract.
            # Callers also inspect status after recovering a BuildFailure result.
            status=(
                "FAILED"
                if error and build.get("buildStatus") == "SUCCEEDED"
                else build.get("buildStatus", "UNKNOWN")
            ),
            total_duration=self._build_duration(build, monitor_start),
            phases=phases,
            error=error,
            log_url=(build.get("logs") or {}).get("deepLink"),
            source_version=build.get("sourceVersion", ""),
            resolved_source_version=build.get("resolvedSourceVersion", ""),
            initiator=build.get("initiator"),
        )

    @staticmethod
    def _failure_detail(build: dict) -> str:
        """Extract the AWS-provided terminal context without guessing the cause."""
        details = []
        if build.get("initiator"):
            details.append(f"initiator={build['initiator']}")
        if build.get("currentPhase"):
            details.append(f"phase={build['currentPhase']}")

        contexts = []
        for phase in build.get("phases") or []:
            phase_type = phase.get("phaseType", "unknown")
            for context in phase.get("contexts") or phase.get("phaseContext") or []:
                message = context.get("message") or context.get("statusCode")
                if message:
                    contexts.append(f"{phase_type}: {message}")
        if contexts:
            details.append("context=" + " | ".join(contexts[-3:]))

        return "; ".join(details) or "no terminal context was returned by CodeBuild"

    def _log_phase_updates(self, build: dict, phase_states: dict[str, str]) -> None:
        """Log each CodeBuild phase when its status changes."""
        build_id = build.get("id", "unknown")
        current_phase = build.get("currentPhase")
        for phase in build.get("phases") or []:
            phase_type = phase.get("phaseType")
            if not phase_type:
                continue

            phase_status = phase.get("phaseStatus")
            if not phase_status and phase_type == current_phase:
                phase_status = "IN_PROGRESS"
            if not phase_status or phase_states.get(phase_type) == phase_status:
                continue

            phase_states[phase_type] = phase_status
            log.info(
                "Build %s phase %s: %s (duration: %s)",
                build_id,
                phase_type,
                phase_status,
                self._format_duration(self._phase_duration(phase)),
            )

    def _latest_progress_log(self, build: dict) -> str | None:
        """Read the latest useful progress marker from the CodeBuild log stream."""
        logs = build.get("logs") or {}
        group_name = logs.get("groupName")
        stream_name = logs.get("streamName")
        if not group_name or not stream_name:
            return None

        try:
            logs_client = self.session.client("logs")
            response = logs_client.get_log_events(
                logGroupName=group_name,
                logStreamName=stream_name,
                startFromHead=False,
                limit=20,
            )
        except Exception:
            return None

        markers = (
            "provision-step:",
            "/live returned",
            "Waiting for",
            "ERROR:",
        )
        for event in reversed(response.get("events") or []):
            message = " ".join(event.get("message", "").split())
            if message and any(marker in message for marker in markers):
                return message[:300]
        return None

    def _log_progress_heartbeat(self, build: dict, monitor_start: float) -> None:
        current_phase = build.get("currentPhase") or "UNKNOWN"
        phase = next(
            (
                phase
                for phase in build.get("phases") or []
                if phase.get("phaseType") == current_phase
            ),
            {},
        )
        latest_log = self._latest_progress_log(build)
        message = (
            f"Build {build.get('id', 'unknown')} still "
            f"{build.get('buildStatus', 'UNKNOWN')}: phase={current_phase}, "
            f"total elapsed={self._format_duration(self._build_duration(build, monitor_start))}, "
            f"phase elapsed={self._format_duration(self._phase_duration(phase))}"
        )
        if latest_log:
            message += f", latest log: {latest_log}"
        log.info(message)

    def _log_build_summary(
        self,
        build: dict,
        monitor_start: float,
        error: str | None = None,
    ) -> BuildResult:
        """Log total build time and each CodeBuild phase duration."""
        result = self._build_result(build, monitor_start, error)
        log.info(
            "Build %s summary: status=%s, total duration=%s",
            result.build_id,
            result.status,
            self._format_duration(result.total_duration),
        )

        for phase in result.phases:
            log.info(
                "Build %s summary: phase=%s, status=%s, duration=%s",
                result.build_id,
                phase["name"],
                phase["status"],
                self._format_duration(phase["duration"]),
            )

        if result.error:
            log.error("Build %s failure detail: %s", result.build_id, result.error)
        if result.log_url:
            log.info("Build %s CloudWatch logs: %s", result.build_id, result.log_url)
        return result

    def _raise_build_failure(self, build: dict, monitor_start: float, message: str):
        result = self._log_build_summary(build, monitor_start, message)
        raise BuildFailure(message, result)

    def wait_for_build(
        self,
        build_id: str,
        desired_sha: str,
        timeout: int = BUILD_COMPLETION_TIMEOUT,
    ):
        """Wait for a CodeBuild build to complete and verify the success contract.

        Gates on: buildStatus=SUCCEEDED && APPLIED=="true" && APPLIED_SHA==desired_sha.
        Rejects skip builds (APPLIED!="true") and STOPPED builds because the
        requested SHA was not applied by that build.

        Args:
            build_id: CodeBuild build ID (e.g., "project-name:uuid").
            desired_sha: Expected git SHA (must match sourceVersion, resolvedSourceVersion,
                and APPLIED_SHA when those values are available).
            timeout: Max seconds to wait.

        Raises:
            TimeoutError: Build did not complete within timeout.
            RuntimeError: Build failed, or success contract not met.
        """
        log.info(
            "Waiting for build %s (desired SHA: %s, timeout: %ds)",
            build_id,
            desired_sha[:7],
            timeout,
        )
        monitor_start = time.monotonic()
        phase_states: dict[str, str] = {}
        status = "UNKNOWN"
        last_build = None
        last_heartbeat = monitor_start
        while time.monotonic() - monitor_start < timeout:
            try:
                response = self.client.batch_get_builds(ids=[build_id])
                builds = response.get("builds", [])
                if not builds:
                    raise RuntimeError(f"Build not found: {build_id}")

                build = builds[0]
                last_build = build
                status = build.get("buildStatus")
                source_sha = build.get("sourceVersion", "")
                resolved_sha = build.get("resolvedSourceVersion", "")
                self._log_phase_updates(build, phase_states)

                # sourceVersion is the requested version and is available before the
                # source download. It lets us reject an unexpected build early without
                # requiring resolvedSourceVersion, which CodeBuild only populates after
                # DOWNLOAD_SOURCE.
                if self._is_full_commit_sha(source_sha) and source_sha.lower() != desired_sha.lower():
                    raise RuntimeError(
                        f"Build {build_id} was requested for SHA {source_sha[:7]}, "
                        f"expected {desired_sha[:7]}."
                    )

                if status in ("IN_PROGRESS", "QUEUED"):
                    # resolvedSourceVersion is not available until DOWNLOAD_SOURCE
                    # completes, so an empty value here is expected.
                    now = time.monotonic()
                    if now - last_heartbeat >= BUILD_PROGRESS_LOG_INTERVAL:
                        self._log_progress_heartbeat(build, monitor_start)
                        last_heartbeat = now
                    time.sleep(POLL_INTERVAL)
                    continue

                # Terminal statuses
                if status == "SUCCEEDED":
                    # For GitHub/CodeConnections, the resolved commit is available
                    # once the build reaches a terminal state.
                    if not resolved_sha:
                        self._raise_build_failure(
                            build,
                            monitor_start,
                            f"Build {build_id} succeeded without resolvedSourceVersion; "
                            "cannot verify the requested SHA."
                        )

                    if resolved_sha != desired_sha:
                        self._raise_build_failure(
                            build,
                            monitor_start,
                            f"Build {build_id} resolved to SHA {resolved_sha[:7]}, "
                            f"expected {desired_sha[:7]}. This should not happen when "
                            "StartBuild is pinned to the pushed SHA.",
                        )

                    # Check the success contract: APPLIED=="true" && APPLIED_SHA==desired_sha.
                    # A skipped build is not a successful provisioning result.
                    applied = self._exported_var(build, "APPLIED")
                    applied_sha = self._exported_var(build, "APPLIED_SHA")

                    if applied != "true":
                        self._raise_build_failure(
                            build,
                            monitor_start,
                            f"Build {build_id} succeeded but APPLIED={applied!r} (not 'true'). "
                            "The CodeBuild success contract was not satisfied; the build "
                            "failed to export its status variables."
                        )

                    if applied_sha != desired_sha:
                        applied_sha_display = (applied_sha or "")[:7]
                        self._raise_build_failure(
                            build,
                            monitor_start,
                            f"Build {build_id} succeeded but APPLIED_SHA={applied_sha_display!r}, "
                            f"expected {desired_sha[:7]}. State mismatch."
                        )

                    result = self._log_build_summary(build, monitor_start)
                    log.info(
                        "Build %s succeeded: APPLIED=true, APPLIED_SHA=%s",
                        build_id,
                        applied_sha[:7],
                    )
                    return result

                elif status == "STOPPED":
                    self._raise_build_failure(
                        build,
                        monitor_start,
                        f"Build {build_id} ended with status STOPPED; "
                        f"{self._failure_detail(build)}",
                    )

                elif status in ("FAILED", "TIMED_OUT", "FAULT"):
                    self._raise_build_failure(
                        build,
                        monitor_start,
                        f"Build {build_id} failed with status {status}; "
                        f"{self._failure_detail(build)}",
                    )

                else:
                    raise RuntimeError(f"Unknown build status: {status}")

            except self.client.exceptions.ResourceNotFoundException:
                # Project was deleted mid-teardown → treat as gone
                log.warning(
                    "Build %s project deleted (ResourceNotFoundException) — treating as complete",
                    build_id,
                )
                return BuildResult(
                    build_id=build_id,
                    status="NOT_FOUND",
                    total_duration=time.monotonic() - monitor_start,
                    error="CodeBuild project was deleted while waiting",
                )

        timeout_message = (
            f"Build {build_id} did not complete within {timeout}s. "
            f"Last known status: {status}"
        )
        if last_build is not None:
            result = self._log_build_summary(last_build, monitor_start, timeout_message)
            timeout_error = TimeoutError(timeout_message)
            timeout_error.result = result
            raise timeout_error
        raise TimeoutError(timeout_message)

    @staticmethod
    def _is_full_commit_sha(value: str) -> bool:
        """Return whether a source version is a full hexadecimal commit SHA."""
        return len(value) == 40 and all(char in "0123456789abcdefABCDEF" for char in value)

    @staticmethod
    def _exported_var(build: dict, name: str) -> str | None:
        """Read an exported environment variable from a build.

        Args:
            build: Build object from batch_get_builds.
            name: Variable name (e.g., "APPLIED", "APPLIED_SHA").

        Returns:
            Variable value, or None if not exported.
        """
        exported_vars = build.get("exportedEnvironmentVariables", [])
        for var in exported_vars:
            if var.get("name") == name:
                return var.get("value")
        return None
