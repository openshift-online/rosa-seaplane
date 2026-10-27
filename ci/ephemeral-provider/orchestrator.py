import json
import logging
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import boto3
import yaml

from __init__ import TARGET_ENVIRONMENT
from aws import AWSCredentials
from codebuild import BuildMonitor, BuildResult
from codebuild_logs import download_codebuild_logs
from codepipeline import PipelineMonitor
from git import GitManager
from yaml_utils import deep_merge, load_and_merge

PROVISION_TIMEOUT = 3600  # seconds (1 hour); total time for provisioning
TEARDOWN_TIMEOUT = 3600  # seconds (1 hour); total time for teardown
PURGE_TIMEOUT = 600  # seconds (10 min); budget for cluster/bundle purge before infra teardown

log = logging.getLogger(__name__)


def discover_region(env_config_dir: Path) -> str:
    """Find the single region YAML in an env config directory.

    Returns the region name (stem of the YAML file, e.g. "us-east-1").
    Errors if zero or more than one region file exists.
    """
    region_files = [f for f in env_config_dir.glob("*.yaml") if f.name != "defaults.yaml"]
    if len(region_files) == 0:
        raise ValueError(f"No region YAML file found in {env_config_dir}")
    if len(region_files) > 1:
        names = sorted(f.name for f in region_files)
        raise ValueError(
            f"Ephemeral provisioner supports exactly 1 region, found {len(region_files)}: {names}"
        )
    return region_files[0].stem


class EphemeralEnvOrchestrator:
    """Orchestrates an ephemeral environment lifecycle.

    Provision and teardown are independent operations that can run in separate
    processes. They share state via the eph_prefix (which determines branch names,
    pipeline names, and terraform state keys).

    Usage from CI steps:
        # Step 1: provision
        env = EphemeralEnvOrchestrator(repo, branch, creds_dir, region, eph_prefix)
        env.provision()

        # Step 2: run tests (separate process, same eph_prefix)

        # Step 3: teardown
        env = EphemeralEnvOrchestrator(repo, branch, creds_dir, region, eph_prefix)
        env.teardown()
    """

    def __init__(self, repo: str, branch: str, creds_dir: str, region: str, eph_prefix: str,
                 override_dir: str | None = None,
                 provision_overrides: list[tuple[str, str]] | None = None,
                 eph_branch_name: str | None = None):
        self.repo = repo
        self.branch = branch
        self.creds_dir = creds_dir
        self.region = region
        self.eph_prefix = eph_prefix
        self.override_dir = Path(override_dir) if override_dir else None
        self.provision_overrides = provision_overrides or []
        self.eph_branch_name = eph_branch_name
        self.aws: AWSCredentials | None = None
        self.central_monitor: BuildMonitor | None = None
        self.target_monitor: PipelineMonitor | None = None
        self.git: GitManager | None = None
        # CodeBuild project names (read from rendered config after bootstrap)
        self.rc_project: str | None = None
        self.mc_projects: list[str] = []
        self._codebuild_logs_collected = False
        self._operation_started_at: float | None = None
        self._operation_failed = False
        self._timing_steps: list[dict[str, object]] = []
        self._provision_builds: list[tuple[str, str]] = []
        self._provision_results: dict[str, BuildResult] = {}
        self._provision_artifact_path: Path | None = None

    def _reset_provision_report(self) -> None:
        self._operation_started_at = time.monotonic()
        self._operation_failed = False
        self._timing_steps = []
        self._provision_builds = []
        self._provision_results = {}
        self._provision_artifact_path = None
        self._codebuild_logs_collected = False

    def _record_timing(self, label: str, duration: float, status: str) -> None:
        self._timing_steps.append(
            {
                "scope": "ORCHESTRATOR",
                "step": label,
                "status": status,
                "duration": duration,
            }
        )

    @contextmanager
    def _timed_step(self, label: str):
        start = time.monotonic()
        status = "SUCCEEDED"
        try:
            yield
        except Exception:
            status = "FAILED"
            raise
        finally:
            self._record_timing(label, time.monotonic() - start, status)

    def provision(self, save_rc_state: str | None = None, save_mc_state: str | None = None):
        self._reset_provision_report()
        try:
            self._provision_impl(save_rc_state, save_mc_state)
        except Exception:
            self._operation_failed = True
            raise
        finally:
            self._log_provision_timing_summary()

    def _provision_impl(
        self, save_rc_state: str | None = None, save_mc_state: str | None = None
    ):
        """Provision the ephemeral environment (setup + bootstrap + wait for pipelines).

        Args:
            save_rc_state: If set, save RC terraform outputs JSON to this path after provisioning.
            save_mc_state: If set, save MC terraform outputs JSON to this path after provisioning.
        """
        with self._timed_step("AWS credential setup"):
            self._setup_aws()

        with self._timed_step("Ephemeral branch and config setup"):
            git = GitManager(self.creds_dir, self.repo, self.branch)
            self.git = git
            git.create_eph_branch(self.eph_prefix)

            # Inject ephemeral environment into config.yaml (not checked into the repo)
            self._inject_ephemeral_config(git)

            # Apply provision override files (deep-merge YAML fragments into repo files)
            self._apply_provision_overrides(git)

        with self._timed_step("Render and push deployment config"):
            desired_sha = git.render_and_push("ci: add ephemeral environment and render deploy files")
            if not desired_sha:
                raise RuntimeError("render_and_push returned no SHA — no changes committed")

        self.central_monitor = BuildMonitor(self.aws.session)
        self.target_monitor = PipelineMonitor(self.aws.target_session)
        self._read_project_names(git)
        pipeline_names = [
            self.target_monitor.pipeline_name(name)
            for name in [self.rc_project, *self.mc_projects]
            if name
        ]
        push_trigger_configs = self.target_monitor.push_trigger_configs(pipeline_names)
        created_pipeline_names = set(self.target_monitor.missing_pipelines(pipeline_names))

        # Bootstrap provisioner (terraform + provision-cluster-resources.sh creates RC/MC resources)
        with self._timed_step("Provisioner bootstrap"):
            self._bootstrap_provisioner(git)

        # Read RC/MC project names from rendered config
        with self._timed_step("Discover RC/MC CodeBuild projects"):
            self._read_project_names(git)

        desired_push_trigger_configs = (
            self.target_monitor.push_trigger_configs(pipeline_names)
            if push_trigger_configs is not None
            else None
        )
        # Wait for provisioning builds
        self._wait_for_provision(
            desired_sha,
            created_pipeline_names,
            push_trigger_configs=push_trigger_configs,
            branch=git.eph_branch,
            changed_paths=git.pushed_file_paths,
            desired_push_trigger_configs=desired_push_trigger_configs,
        )

        if save_rc_state:
            with self._timed_step("Save and validate RC outputs"):
                self._save_terraform_outputs(git, save_rc_state)
                self._validate_saved_outputs(save_rc_state, "RC")
        if save_mc_state:
            with self._timed_step("Save and validate MC outputs"):
                self._save_mc_terraform_outputs(git, save_mc_state)
                if self.mc_projects:
                    self._validate_saved_outputs(save_mc_state, "MC")

    def resume(
        self,
        save_rc_state: str | None = None,
        save_mc_state: str | None = None,
        resync_before_resume: bool = False,
    ):
        self._reset_provision_report()
        try:
            self._resume_impl(save_rc_state, save_mc_state, resync_before_resume)
        except Exception:
            self._operation_failed = True
            raise
        finally:
            self._log_provision_timing_summary()

    def _resume_impl(
        self,
        save_rc_state: str | None = None,
        save_mc_state: str | None = None,
        resync_before_resume: bool = False,
    ):
        """Resume provisioning from an existing ephemeral branch.

        This retries the bootstrap and CodeBuild stages without creating a new
        branch or appending another environment record. When requested, the
        existing branch is first reset to the latest source branch, ephemeral
        configuration is re-injected, and the rendered result is force-pushed.
        Existing Terraform state and CodeBuild projects are reused.
        """
        with self._timed_step("Checkout ephemeral branch and discover region"):
            git = GitManager(
                self.creds_dir,
                self.repo,
                self.branch,
                eph_branch_name=self.eph_branch_name,
            )
            self.git = git
            git.checkout_eph_branch(self.eph_prefix)

            env_config_dir = git.work_dir / "config" / TARGET_ENVIRONMENT
            self.region = discover_region(env_config_dir)
            log.info("Region (from ephemeral branch): %s", self.region)

        with self._timed_step("AWS credential setup"):
            self._setup_aws()
        self.central_monitor = BuildMonitor(self.aws.session)
        self.target_monitor = PipelineMonitor(self.aws.target_session)

        if resync_before_resume:
            with self._timed_step("Resync and render deployment config"):
                self._read_project_names(git)
                pipeline_names = [
                    self.target_monitor.pipeline_name(name)
                    for name in [self.rc_project, *self.mc_projects]
                    if name
                ]
                active_builds = self.target_monitor.active_pipelines(pipeline_names)
                active_builds.extend(
                    self.central_monitor.active_builds(
                        [f"{git.eph_prefix}-build-platform-image"]
                    )
                )
                if active_builds:
                    raise RuntimeError(
                        "Cannot automatically resync while CodeBuild builds are active: "
                        f"{', '.join(active_builds)}. Wait for them to finish, or rerun "
                        "with RESYNC=false to resume without force-pushing the branch."
                    )

                log.info("Resyncing ephemeral branch before resuming provisioning")
                git.resync_eph_branch(self.eph_prefix)
                self._inject_ephemeral_config(git)
                self._apply_provision_overrides(git)
                desired_sha = git.render_and_push(
                    "ci: resync ephemeral environment config",
                    force=True,
                    force_push_if_clean=True,
                )
                push_trigger_configs = self.target_monitor.push_trigger_configs(pipeline_names)
        else:
            push_trigger_configs = None
            with self._timed_step("Resolve resume commit"):
                desired_sha = git.current_sha()

        log.info("Resuming provisioning at commit: %s", desired_sha)

        self._read_project_names(git)
        pipeline_names = [
            self.target_monitor.pipeline_name(name)
            for name in [self.rc_project, *self.mc_projects]
            if name
        ]
        created_pipeline_names = set(self.target_monitor.missing_pipelines(pipeline_names))

        with self._timed_step("Provisioner bootstrap"):
            self._bootstrap_provisioner(git)
        with self._timed_step("Discover RC/MC CodeBuild projects"):
            self._read_project_names(git)
        desired_push_trigger_configs = (
            self.target_monitor.push_trigger_configs(pipeline_names)
            if push_trigger_configs is not None
            else None
        )
        self._wait_for_provision(
            desired_sha,
            created_pipeline_names,
            push_trigger_configs=push_trigger_configs,
            branch=git.eph_branch if push_trigger_configs is not None else None,
            changed_paths=git.pushed_file_paths if push_trigger_configs is not None else None,
            skip_untriggered_pushes=push_trigger_configs is not None,
            desired_push_trigger_configs=desired_push_trigger_configs,
        )

        if save_rc_state:
            with self._timed_step("Save and validate RC outputs"):
                self._save_terraform_outputs(git, save_rc_state)
                self._validate_saved_outputs(save_rc_state, "RC")
        if save_mc_state:
            with self._timed_step("Save and validate MC outputs"):
                self._save_mc_terraform_outputs(git, save_mc_state)
                if self.mc_projects:
                    self._validate_saved_outputs(save_mc_state, "MC")

    def teardown(self, fire_and_forget: bool = False, with_resync: bool = False):
        """Tear down a previously provisioned ephemeral environment.

        Can run independently of provision() — reconnects to the existing
        ephemeral branch and pipeline resources using the eph_prefix. The region is
        discovered from the ephemeral branch's config (not the local workspace),
        so teardown always matches the provisioned environment.

        Args:
            fire_and_forget: If True, starts MC and RC destruction together,
                then exits without waiting for either to finish. Phase 2
                (delete pipelines/projects) and Phase 3 (provisioner destruction)
                are intentionally skipped — teardown is expected to be driven to
                completion by the in-account aws-nuke-cf janitor.
            with_resync: Refresh the ephemeral branch from the source branch before
                destruction, with push triggers disabled to prevent an apply.
        """
        # Check out the ephemeral branch first to discover region from its config
        git = GitManager(self.creds_dir, self.repo, self.branch,
                         eph_branch_name=self.eph_branch_name)
        self.git = git
        git.checkout_eph_branch(self.eph_prefix)

        # Discover region from the ephemeral branch's config
        env_config_dir = git.work_dir / "config" / TARGET_ENVIRONMENT
        self.region = discover_region(env_config_dir)
        log.info("Region (from ephemeral branch): %s", self.region)

        self._setup_aws()

        self.central_monitor = BuildMonitor(self.aws.session)
        self.target_monitor = PipelineMonitor(self.aws.target_session)

        # Read RC/MC project names from rendered config before any teardown side effects.
        self._read_project_names(git)

        if with_resync:
            pipeline_names = [
                self.target_monitor.pipeline_name(project)
                for project in [self.rc_project, *self.mc_projects]
                if project
            ]
            for pipeline_name in pipeline_names:
                self.target_monitor.disable_push_triggers(pipeline_name)
            self.target_monitor.stop_active_executions(pipeline_names)
            log.info("Teardown: refresh CI branch from %s@%s", self.repo, self.branch)
            git.resync_eph_branch(self.eph_prefix)
            self._inject_ephemeral_config(git)
            refreshed_region = discover_region(env_config_dir)
            if refreshed_region != self.region:
                raise RuntimeError("Teardown resync cannot change the provisioned region")
            git.render_and_push(
                "ci: refresh ephemeral environment for teardown",
                force=True,
                force_push_if_clean=True,
            )

        # Purge clusters and resource bundles before infrastructure teardown.
        # Deleting bundles triggers ManifestWork removal on the MC, which is
        # what actually tears down the HostedClusters. Without this, terraform
        # destroy on the MC can be blocked by active HCPs.
        self._purge_clusters(git)

        self._run_teardown(git, fire_and_forget=fire_and_forget)

    def resync(self):
        """Resync the ephemeral branch: rebase onto latest source, re-inject config, re-render.

        Re-reads the environment config (including .ephemeral-env/ overrides if
        mounted) so that config changes are picked up alongside code changes.
        """
        git = GitManager(self.creds_dir, self.repo, self.branch,
                         eph_branch_name=self.eph_branch_name)
        self.git = git
        git.checkout_eph_branch(self.eph_prefix)
        env_config_dir = git.work_dir / "config" / TARGET_ENVIRONMENT
        self.region = discover_region(env_config_dir)
        self._setup_aws()
        self.target_monitor = PipelineMonitor(self.aws.target_session)
        self._read_project_names(git)
        pipeline_names = [
            self.target_monitor.pipeline_name(name)
            for name in [self.rc_project, *self.mc_projects]
            if name
        ]
        active_pipelines = self.target_monitor.active_pipelines(pipeline_names)
        if active_pipelines:
            raise RuntimeError(
                "Cannot resync while CodePipeline executions are active: "
                f"{', '.join(active_pipelines)}. Wait for them to finish and retry."
            )
        git.resync_eph_branch(self.eph_prefix)

        self._inject_ephemeral_config(git)
        desired_sha = git.render_and_push(
            "ci: resync ephemeral environment config",
            force=True,
            force_push_if_clean=True,
        )
        if not desired_sha:
            raise RuntimeError("render_and_push returned no SHA during ephemeral resync")

        push_trigger_configs = self.target_monitor.push_trigger_configs(pipeline_names)
        self._read_project_names(git)
        started = self._start_provision_pipelines(
            desired_sha,
            push_trigger_configs=push_trigger_configs,
            branch=git.eph_branch,
            changed_paths=git.pushed_file_paths,
            skip_untriggered_pushes=True,
        )
        log.info(
            "Adopted or started %d ephemeral pipeline execution(s) for resynced commit %s",
            len(started),
            desired_sha[:7],
        )

    def collect_codebuild_logs(self):
        """Download CloudWatch logs for all CodeBuild projects matching our ephemeral prefix.

        Writes each log group to a separate file in ARTIFACT_DIR (set by Prow)
        so they appear in the Prow artifacts UI. Sensitive values (AWS keys,
        session tokens) are redacted before writing.
        """
        artifact_dir = os.environ.get("ARTIFACT_DIR")
        if not artifact_dir:
            log.warning("ARTIFACT_DIR not set — skipping CodeBuild log collection")
            return

        if self._codebuild_logs_collected:
            artifact_path = Path(artifact_dir) / "codebuild-logs"
            log.info("CodeBuild logs already collected: %s", artifact_path)
            return artifact_path

        if not self.aws or not self.aws.session:
            log.warning("AWS session not available — skipping log collection")
            return

        artifact_path = Path(artifact_dir) / "codebuild-logs"
        # Both sessions use the central account in the current setup; they only
        # differ by region. Avoid downloading the same account/region twice when
        # the target region is also us-east-1.
        files = []
        seen_sessions = set()
        for session in (self.aws.session, self.aws.target_session):
            if session is None:
                continue
            session_key = (self.aws.central_account_id, session.region_name)
            if session_key in seen_sessions:
                log.info(
                    "Skipping duplicate CodeBuild log session: account=%s region=%s",
                    session_key[0],
                    session_key[1],
                )
                continue
            seen_sessions.add(session_key)
            files.extend(download_codebuild_logs(session, self.eph_prefix, artifact_path))

        # Redact sensitive values (AWS keys, session tokens) from Prow artifacts
        for f in files:
            content = f.read_text()
            content = _redact_sensitive(content)
            f.write_text(content)

        # Only mark collection complete once downloads and redaction succeed, so
        # a failure above leaves the flag false and a later call can retry.
        self._codebuild_logs_collected = True
        log.info("CodeBuild artifact directory: %s", artifact_path)
        return artifact_path

    def _setup_aws(self):
        """Set up AWS credentials and trust policies."""
        log.info("")
        log.info("==========================================")
        log.info("Setup: AWS Credentials")
        log.info("==========================================")

        self.aws = AWSCredentials(self.region)
        self.aws.setup_central_account()

    def _inject_ephemeral_config(self, git: GitManager):
        """Inject the ephemeral environment config into the cloned repo.

        If an override directory (.ephemeral-env/) is provided, region YAML
        files in config/ephemeral/ are replaced with the override's, while
        defaults.yaml is deep-merged with the override (not replaced) to
        preserve existing environment settings the override omits. Otherwise
        the repo's default config/ephemeral/ is used as-is.

        In both cases, AWS account IDs are injected into the region config from
        the runtime credentials (never from config files).
        """
        env_config_dir = git.work_dir / "config" / TARGET_ENVIRONMENT

        # Replace config with overrides if provided
        if self.override_dir and self.override_dir.exists():
            log.info("Applying environment overrides from %s", self.override_dir)
            env_config_dir.mkdir(parents=True, exist_ok=True)
            # Delete only region files (not defaults.yaml) to purge stale configs.
            # defaults.yaml is merged rather than replaced to preserve env-level
            # settings (e.g. dns.domain) that the override file omits.
            for existing in env_config_dir.glob("*.yaml"):
                if existing.name != "defaults.yaml":
                    existing.unlink()
            for override_file in self.override_dir.glob("*.yaml"):
                target = env_config_dir / override_file.name
                if override_file.name == "defaults.yaml" and target.exists():
                    load_and_merge(target, override_file)
                else:
                    shutil.copy2(override_file, target)

        # Validate: exactly 1 region file must exist (enforced by discover_region
        # at startup, but re-check after override replacement)
        region = discover_region(env_config_dir)
        if region != self.region:
            raise ValueError(
                f"Region in config ({region}) does not match expected region ({self.region}). "
                "This should not happen — region is derived from the same config."
            )

        # Read and validate the region config
        region_file = env_config_dir / f"{self.region}.yaml"
        with open(region_file) as f:
            region_config = yaml.safe_load(f) or {}

        # Validate provision_mcs
        if "provision_mcs" not in region_config:
            raise ValueError(
                f"Region config {region_file.name} must define 'provision_mcs'. "
                "Example:\n  provision_mcs:\n    mc01: {}"
            )

        # Inject runtime AWS account IDs
        regional_account_id = self.aws.get_target_account_id("regional")
        management_account_id = self.aws.get_target_account_id("management")

        log.info(
            "Injecting ephemeral environment: region=%s, regional=%s, management=%s",
            self.region,
            regional_account_id,
            management_account_id,
        )

        if "aws" not in region_config:
            region_config["aws"] = {}
        region_config["aws"]["account_id"] = regional_account_id
        region_config["aws"]["management_cluster_account_id"] = management_account_id

        with open(region_file, "w") as f:
            yaml.dump(region_config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

    def _apply_provision_overrides(self, git: GitManager):
        """Deep-merge provision override files into the cloned repo.

        Each override is a (target_path, override_file) tuple where target_path
        is relative to the repo root and override_file is an absolute path to a
        YAML fragment. The fragment is deep-merged into the target file —
        dict keys are merged recursively, and list items are matched by 'name'
        field when present.
        """
        if not self.provision_overrides:
            return

        log.info("")
        log.info("Applying %d provision override(s):", len(self.provision_overrides))

        for target_path, override_file in self.provision_overrides:
            root = git.work_dir.resolve()
            target = (root / target_path).resolve()
            if not target.is_relative_to(root):
                raise ValueError(
                    f"Override target escapes repo root: {target_path}"
                )
            if not target.exists():
                raise FileNotFoundError(
                    f"Override target not found: {target_path} "
                    f"(resolved to {target})"
                )

            log.info("  %s <- %s", target_path, override_file)
            load_and_merge(target, override_file)

    def _bootstrap_provisioner(self, git: GitManager):
        """Bootstrap the provisioner (terraform + provision-cluster-resources.sh creates RC/MC resources).

        Push triggers stay enabled. The provider adopts matching push executions
        and only starts executions for explicit retries or unmatched changes.
        """
        log.info("")
        log.info("==========================================")
        log.info("Bootstrapping Provisioner")
        log.info("==========================================")

        bootstrap_script = git.work_dir / "scripts" / "bootstrap-central-account.sh"

        if not bootstrap_script.exists():
            raise FileNotFoundError(f"Bootstrap script not found at: {bootstrap_script}")

        env = os.environ.copy()
        env.update(self.aws.subprocess_env)
        env["GITHUB_REPOSITORY"] = git.fork_repo
        env["GITHUB_BRANCH"] = git.eph_branch
        env["TARGET_ENVIRONMENT"] = TARGET_ENVIRONMENT
        env["NAME_PREFIX"] = git.eph_prefix
        env["ENABLE_CODEPIPELINE_PUSH_TRIGGERS"] = "true"

        log.info("Executing: %s", bootstrap_script)
        log.info("Env: REPO=%s, BRANCH=%s", git.fork_repo, git.eph_branch)

        sys.stdout.flush()
        sys.stderr.flush()

        try:
            subprocess.run(
                ["/bin/bash", str(bootstrap_script)],
                cwd=git.work_dir,
                env=env,
                stdout=sys.stdout,
                stderr=sys.stderr,
                text=True,
                check=True,
                timeout=PROVISION_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                f"bootstrap-central-account.sh timed out after {PROVISION_TIMEOUT}s"
            )
        except subprocess.CalledProcessError as e:
            raise RuntimeError(
                f"bootstrap-central-account.sh failed with exit code {e.returncode}. "
                "Check the logs above for the specific shell error."
            )
        log.info("Provisioner bootstrapped (RC/MC projects created): %s", git.eph_branch)

    def _read_project_names(self, git: GitManager):
        """Read RC and MC CodeBuild project names from rendered config.

        Project names are deterministic (computed by render.py using the configurable
        naming pattern), stored in the rendered JSON files. We read them here to
        avoid hardcoding the pattern in Python.
        """
        log.info("Reading CodeBuild project names from rendered config...")
        self.rc_project = None
        self.mc_projects = []

        deploy_dir = git.work_dir / "deploy" / TARGET_ENVIRONMENT / self.region

        # Read RC project name
        rc_config_path = deploy_dir / "pipeline-regional-cluster-inputs" / "terraform.json"
        if not rc_config_path.exists():
            raise FileNotFoundError(
                f"RC config not found: {rc_config_path}. "
                "Ensure render.py ran successfully during bootstrap."
            )

        with open(rc_config_path) as f:
            rc_config = json.load(f)
            self.rc_project = rc_config.get("regional_id")
            if not self.rc_project:
                raise ValueError(f"regional_id not found in {rc_config_path}")

        log.info("  RC project: %s", self.rc_project)

        # Read MC project names
        mc_config_dir = deploy_dir / "pipeline-provisioner-inputs"
        if mc_config_dir.exists():
            for mc_file in sorted(mc_config_dir.glob("management-cluster-*.json")):
                with open(mc_file) as f:
                    mc_config = json.load(f)
                    mc_id = mc_config.get("management_id")
                    if mc_id:
                        self.mc_projects.append(mc_id)
                        log.info("  MC project: %s", mc_id)

        if not self.mc_projects:
            log.info("  No MC projects found (RC-only deployment)")

    def _start_provision_pipelines(
        self,
        desired_sha: str,
        created_pipeline_names: set[str] | None = None,
        push_trigger_configs: dict[str, dict | None] | None = None,
        branch: str | None = None,
        changed_paths: list[str] | None = None,
        skip_untriggered_pushes: bool = False,
        desired_push_trigger_configs: dict[str, dict | None] | None = None,
    ) -> list[tuple[str, str]]:
        """Adopt push/create executions; explicitly start only provider-owned retries."""
        if not self.rc_project:
            raise RuntimeError("Cannot start provisioning: RC project name is unavailable")

        created_pipeline_names = created_pipeline_names or set()
        projects = [self.rc_project, *self.mc_projects]
        execution_ids = {}

        for project_name in projects:
            pipeline_name = self.target_monitor.pipeline_name(project_name)
            if pipeline_name in created_pipeline_names:
                continue

            push_matched = (
                push_trigger_configs is not None
                and self.target_monitor.push_trigger_matches(
                    push_trigger_configs.get(pipeline_name),
                    branch or "",
                    changed_paths or [],
                )
            )
            desired_filter_matches = (
                push_trigger_configs is not None
                and self.target_monitor.push_trigger_matches(
                    (desired_push_trigger_configs or push_trigger_configs).get(pipeline_name),
                    branch or "",
                    changed_paths or [],
                )
            )
            if push_matched:
                execution_ids[project_name] = self.target_monitor.wait_for_revision_execution(
                    pipeline_name,
                    desired_sha,
                )
            elif desired_filter_matches:
                log.info(
                    "Starting %s pipeline %s at SHA %s: its current push filter matches, "
                    "but the filter was not active when this branch update was pushed",
                    "RC" if project_name == self.rc_project else "MC",
                    pipeline_name,
                    desired_sha[:7],
                )
                execution_ids[project_name] = self.target_monitor.start_or_reuse_pipeline(
                    pipeline_name,
                    desired_sha,
                )
            elif skip_untriggered_pushes:
                active_execution = self.target_monitor.start_or_reuse_pipeline(
                    pipeline_name,
                    desired_sha,
                    start_if_idle=False,
                )
                if active_execution:
                    execution_ids[project_name] = active_execution
                    continue
                previous_success = self.target_monitor.has_successful_execution(pipeline_name)
                if previous_success:
                    log.info(
                        "Skipping %s pipeline %s: changed paths do not match its push filter; "
                        "retaining successful execution %s at SHA %s",
                        "RC" if project_name == self.rc_project else "MC",
                        pipeline_name,
                        previous_success[0],
                        previous_success[1][:7],
                    )
                    continue
                execution_ids[project_name] = self.target_monitor.start_or_reuse_pipeline(
                    pipeline_name,
                    desired_sha,
                )
            else:
                execution_ids[project_name] = self.target_monitor.start_or_reuse_pipeline(
                    pipeline_name,
                    desired_sha,
                )

        for project_name in projects:
            pipeline_name = self.target_monitor.pipeline_name(project_name)
            if pipeline_name in created_pipeline_names:
                execution_ids[project_name] = self.target_monitor.wait_for_creation_execution(
                    pipeline_name,
                    desired_sha,
                )

        return [
            (project_name, execution_ids[project_name])
            for project_name in projects
            if project_name in execution_ids
        ]

    def _wait_for_provision(
        self,
        desired_sha: str,
        created_pipeline_names: set[str] | None = None,
        push_trigger_configs: dict[str, dict | None] | None = None,
        branch: str | None = None,
        changed_paths: list[str] | None = None,
        skip_untriggered_pushes: bool = False,
        desired_push_trigger_configs: dict[str, dict | None] | None = None,
    ):
        """Monitor RC + MC executions in RC-first order."""
        log.info("")
        log.info("==========================================")
        log.info("Provision: Reconciling RC and MC CodePipeline executions for this revision")
        log.info("==========================================")

        build_window_start = time.monotonic()

        # The MC build scripts discover RC outputs directly; they do not need a
        # direct CodeBuild build-ID override when invoked by CodePipeline.
        builds = self._start_provision_pipelines(
            desired_sha,
            created_pipeline_names,
            push_trigger_configs,
            branch,
            changed_paths,
            skip_untriggered_pushes,
            desired_push_trigger_configs,
        )

        log.info("Tracking %d pipeline execution(s) at SHA %s", len(builds), desired_sha[:7])

        if not builds:
            self._record_timing(
                "RC/MC CodePipeline window (overlap)",
                time.monotonic() - build_window_start,
                "SUCCEEDED",
            )
            self._provision_builds = []
            self._provision_results = {}
            log.info("No RC/MC changes require a pipeline run; retaining prior successful state.")
            return

        # Poll pipeline status in the same RC-first order used to start them.
        # The CodeBuild executions themselves are already running concurrently.
        log.info("")
        log.info("==========================================")
        log.info("Provision: Waiting for CodePipelines")
        log.info("==========================================")

        results = self.target_monitor.wait_for_pipelines(builds, desired_sha)
        failed = [
            project_name
            for project_name, _ in builds
            if results[project_name].status != "SUCCEEDED" or results[project_name].error
        ]
        for project_name, _ in builds:
            result = results[project_name]
            if project_name in failed:
                log.error("Build '%s' failed: %s", project_name, result.error or result.status)
                continue
            log.info(
                "✓ Build completed: %s (status=%s, duration=%s)",
                project_name,
                result.status,
                self.target_monitor._format_duration(result.total_duration),
            )

        build_window_duration = time.monotonic() - build_window_start
        self._record_timing(
            "RC/MC CodePipeline window (overlap)",
            build_window_duration,
            "FAILED" if failed else "SUCCEEDED",
        )

        artifact_path = None
        artifact_collection_start = time.monotonic()
        artifact_collection_status = "SUCCEEDED"
        try:
            artifact_path = self.collect_codebuild_logs()
        except Exception:
            artifact_collection_status = "FAILED"
            log.exception("Failed to collect CodeBuild logs")
        artifact_collection_duration = time.monotonic() - artifact_collection_start
        self._record_timing(
            "CodeBuild artifact collection",
            artifact_collection_duration,
            artifact_collection_status,
        )
        self._provision_builds = builds
        self._provision_results = results
        self._provision_artifact_path = artifact_path

        if failed:
            rc_failed = self.rc_project in failed
            mc_failed = [project for project in failed if project != self.rc_project]
            resume_command = self._provision_resume_command()
            if rc_failed:
                mc_detail = (
                    f"; dependent MC build(s) also failed: "
                    f"{self._format_failed_builds(mc_failed, results)}"
                    if mc_failed
                    else "; MC build(s) completed, but overall provisioning is failed because RC failed"
                )
                raise RuntimeError(
                    f"RC provisioning failed: "
                    f"{self._format_failed_builds([self.rc_project], results)}{mc_detail}. "
                    f"Fix the RC failure and resume with: {resume_command}"
                )
            raise RuntimeError(
                f"MC provisioning failed: {self._format_failed_builds(mc_failed, results)}. "
                f"Fix the MC failure and resume with: {resume_command}"
            )

        log.info("All builds completed successfully.")

    def _provision_resume_command(self) -> str:
        """Return the local command that retries this environment's provisioning."""
        env_id = self.eph_prefix.removeprefix("eph-")
        return f"make ephemeral-provision-resume ID={env_id}"

    @staticmethod
    def _format_failed_builds(
        projects: list[str | None], results: dict[str, BuildResult]
    ) -> str:
        """Format concise terminal details for failed RC/MC builds."""
        details = []
        for project in projects:
            result = results.get(project) if project else None
            if result is None:
                details.append(f"{project or '<unknown>'}: no result")
                continue
            detail = result.error or f"status={result.status}"
            details.append(f"{project}: {' '.join(detail.split())[:300]}")
        return "; ".join(details)

    def _log_provision_timing_summary(self) -> None:
        """Print one table covering orchestration and CodeBuild timings."""
        operation_start = self._operation_started_at or time.monotonic()
        total_duration = time.monotonic() - operation_start
        format_duration = (
            self.target_monitor._format_duration
            if self.target_monitor
            else BuildMonitor._format_duration
        )

        rows = []
        for timing in self._timing_steps:
            rows.append(
                (
                    timing["scope"],
                    timing["step"],
                    timing["status"],
                    timing["status"],
                    format_duration(timing["duration"]),
                    "",
                )
            )

        for project_name, build_id in self._provision_builds:
            result = self._provision_results.get(
                project_name,
                BuildResult(
                    build_id=build_id,
                    status="UNKNOWN",
                    total_duration=None,
                    error="No result was returned by the build monitor",
                ),
            )
            outcome = "SUCCEEDED" if result.error is None else "FAILED"
            short_build_id = result.build_id.rsplit(":", 1)[-1][:8]
            rows.append(
                (
                    project_name,
                    "CodeBuild total",
                    outcome,
                    result.status,
                    format_duration(result.total_duration),
                    short_build_id,
                )
            )

            for phase in result.phases:
                phase_status = phase["status"] or "UNKNOWN"
                phase_outcome = (
                    "SUCCEEDED"
                    if phase_status == "SUCCEEDED"
                    else "FAILED"
                    if phase_status in {"FAILED", "FAULT", "STOPPED", "TIMED_OUT"}
                    else phase_status
                )
                rows.append(
                    (
                        project_name,
                        f"phase: {phase['name']}",
                        phase_outcome,
                        phase_status,
                        format_duration(phase["duration"]),
                        short_build_id,
                    )
                )

        rows.append(
            (
                "ORCHESTRATOR",
                "TOTAL operation",
                "FAILED" if self._operation_failed else "SUCCEEDED",
                "FAILED" if self._operation_failed else "SUCCEEDED",
                format_duration(total_duration),
                "",
            )
        )

        report_lines = [
            "",
            "==========================================",
            "Provision: Timing and Build Summary",
            "==========================================",
            "Provision timing and build report:",
            "%-32s %-42s %-10s %-10s %-10s %-8s" % (
                "SCOPE", "STEP / PHASE", "OUTCOME", "STATUS", "DURATION", "BUILD"
            ),
            "%-32s %-42s %-10s %-10s %-10s %-8s" % (
                "-----", "-----------", "-------", "------", "--------", "-----"
            ),
        ]
        report_lines.extend(
            "%-32s %-42s %-10s %-10s %-10s %-8s" % row for row in rows
        )

        for project_name, build_id in self._provision_builds:
            result = self._provision_results.get(project_name)
            if result is None:
                continue
            if result.log_url:
                report_lines.append(
                    f"Build report: project={project_name} CloudWatch={result.log_url}"
                )

        if self._provision_artifact_path:
            report_lines.append(f"Build report: artifacts={self._provision_artifact_path}")
        else:
            report_lines.append("Build report: artifacts=unavailable (ARTIFACT_DIR is not set)")

        report_text = "\n".join(report_lines) + "\n"
        for line in report_lines:
            log.info("%s", line)
        self._write_provision_timing_artifact(report_text)

    def _write_provision_timing_artifact(self, report_text: str) -> None:
        """Write the unified provisioning report to the configured artifact directory."""
        artifact_dir = os.environ.get("ARTIFACT_DIR")
        if not artifact_dir:
            return

        report_path = Path(artifact_dir) / "provision-timing-summary.txt"
        try:
            report_path.parent.mkdir(parents=True, exist_ok=True)
            report_path.write_text(report_text)
            log.info("Build report: timing summary=%s", report_path)
        except OSError as exc:
            log.warning("Unable to write provisioning timing artifact %s: %s", report_path, exc)

    def _save_terraform_outputs(self, git: GitManager, dest: str):
        """Fetch RC terraform outputs and write them to a file.

        Connects to the regional-cluster remote state in the RC account's
        S3 bucket and runs ``terraform output --json``.
        """
        log.info("")
        log.info("==========================================")
        log.info("Saving Terraform Outputs")
        log.info("==========================================")

        regional_account_id = self.aws.get_target_account_id("regional")
        state_bucket = f"terraform-state-{regional_account_id}-{self.region}"
        if not self.rc_project:
            raise RuntimeError("Cannot read RC state: RC project name is unavailable")
        state_key = f"regional-cluster/{self.rc_project}.tfstate"
        tf_dir = git.work_dir / "terraform" / "config" / "regional-cluster"

        env = os.environ.copy()
        env.update(self.aws.target_subprocess_env("regional"))

        log.info("State bucket: %s  key: %s", state_bucket, state_key)

        try:
            subprocess.run(
                [
                    "terraform", "init", "-reconfigure",
                    f"-backend-config=bucket={state_bucket}",
                    f"-backend-config=key={state_key}",
                    f"-backend-config=region={self.region}",
                    "-backend-config=use_lockfile=true",
                ],
                cwd=tf_dir,
                env=env,
                check=True,
                timeout=120,
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(
                f"terraform init timed out for {tf_dir} "
                f"(bucket={state_bucket}, key={state_key})"
            ) from e

        try:
            result = subprocess.run(
                ["terraform", "output", "--json"],
                cwd=tf_dir,
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(
                f"terraform output timed out for {tf_dir} "
                f"(bucket={state_bucket}, key={state_key})"
            ) from e

        dest_path = Path(dest)
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        dest_path.write_text(result.stdout)
        log.info("Terraform outputs written to %s", dest)

    def _save_mc_terraform_outputs(self, git: GitManager, dest: str):
        """Fetch MC terraform outputs and write them to a file.

        Connects to the management-cluster remote state in the MC account's
        S3 bucket and runs ``terraform output --json``.
        """
        log.info("")
        log.info("==========================================")
        log.info("Saving MC Terraform Outputs")
        log.info("==========================================")

        management_account_id = self.aws.get_target_account_id("management")
        state_bucket = f"terraform-state-{management_account_id}-{self.region}"

        # The state-file interface currently stores one MC output file. Use the
        # first rendered project so state lookup and output validation agree.
        if not self.mc_projects:
            log.warning("No MCs in provision_mcs — skipping MC state save")
            return
        mc_id = self.mc_projects[0]

        state_key = f"management-cluster/{mc_id}.tfstate"
        tf_dir = git.work_dir / "terraform" / "config" / "management-cluster"

        env = os.environ.copy()
        env.update(self.aws.target_subprocess_env("management"))

        log.info("MC state bucket: %s  key: %s", state_bucket, state_key)

        try:
            subprocess.run(
                [
                    "terraform", "init", "-reconfigure",
                    f"-backend-config=bucket={state_bucket}",
                    f"-backend-config=key={state_key}",
                    f"-backend-config=region={self.region}",
                    "-backend-config=use_lockfile=true",
                ],
                cwd=tf_dir,
                env=env,
                check=True,
                timeout=120,
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(
                f"terraform init timed out for MC {mc_id} "
                f"(bucket={state_bucket}, key={state_key})"
            ) from e

        try:
            result = subprocess.run(
                ["terraform", "output", "--json"],
                cwd=tf_dir,
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(
                f"terraform output timed out for MC {mc_id} "
                f"(bucket={state_bucket}, key={state_key})"
            ) from e

        dest_path = Path(dest)
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        dest_path.write_text(result.stdout)
        log.info("MC terraform outputs written to %s", dest)

    def _validate_saved_outputs(
        self,
        output_path: str,
        cluster_type: str,
    ):
        """Validate and summarize the outputs exposed to downstream workflows.

        CodeBuild success only proves that the build command exited zero. This
        check makes the saved Terraform-output contract explicit, so a
        successful provision cannot be recorded as ready with missing URLs or
        missing RC-to-MC hand-off data.
        """
        try:
            outputs = json.loads(Path(output_path).read_text())
        except (OSError, json.JSONDecodeError) as e:
            raise RuntimeError(
                f"Unable to validate {cluster_type} provisioning outputs at {output_path}: {e}"
            ) from e

        required = [
            "cluster_name",
            "cluster_endpoint",
            "vpc_id",
        ]
        if cluster_type == "RC":
            required.extend(["api_gateway_invoke_url", "rhobs_api_url"])
        else:
            required.extend(["oidc_bucket_name", "oidc_cloudfront_domain"])

        invalid = []
        for name in required:
            value = outputs.get(name, {}).get("value")
            if value in (None, ""):
                invalid.append(f"{name}=empty")
                continue
            if name.endswith("_endpoint") or name.endswith("_url"):
                if not str(value).startswith("https://"):
                    invalid.append(f"{name}=invalid-url")
            if name == "vpc_id" and not str(value).startswith("vpc-"):
                invalid.append(f"{name}=invalid-vpc-id")

        log.info("")
        log.info("==========================================")
        log.info("Provision: %s Output Summary", cluster_type)
        log.info("==========================================")
        log.info("  source=%s", output_path)

        if invalid:
            raise RuntimeError(
                f"Required {cluster_type} Terraform outputs are missing or invalid: "
                f"{', '.join(invalid)}"
            )

        for name in required:
            log.info("  ✓ %s", name)

    def _purge_clusters(self, git: GitManager):
        """Delete all clusters and resource bundles via Platform API before infra teardown.

        Follows the same pattern as the cluster-cleanup cronjob but operates
        externally via the Platform API Gateway:
          1. Fetch the API URL from terraform state
          2. Delete all clusters (removes DB entries)
          3. Delete all resource bundles (triggers ManifestWork removal → HC teardown)
          4. Poll until both clusters and bundles are confirmed gone

        Best-effort with timeout: if the API is unreachable or purge exceeds
        PURGE_TIMEOUT, logs a warning and returns so infra teardown can proceed.
        """
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Cluster & Bundle Purge")
        log.info("==========================================")

        deadline = time.time() + PURGE_TIMEOUT

        # --- Get API URL from terraform state ---
        api_url = self._get_api_url(git)
        if not api_url:
            log.warning("Could not determine API URL — skipping cluster purge")
            return
        api_url = api_url.rstrip("/")
        log.info("Platform API: %s", api_url)

        # --- Set up SigV4-signed request helper ---
        rc_session = boto3.Session(
            profile_name="rrp-rc",
            region_name=self.region,
        )
        credentials = rc_session.get_credentials().get_frozen_credentials()
        account_id = rc_session.client("sts").get_caller_identity()["Account"]

        def sigv4_request(method: str, path: str) -> dict | None:
            """Make a SigV4-signed request to the Platform API. Returns parsed JSON or None."""
            from botocore.auth import SigV4Auth
            from botocore.awsrequest import AWSRequest

            url = f"{api_url}{path}"
            request = AWSRequest(method=method, url=url, headers={
                "X-Amz-Account-Id": account_id,
            })
            SigV4Auth(credentials, "execute-api", self.region).add_auth(request)

            req = urllib.request.Request(
                url,
                method=method,
                headers=dict(request.headers),
            )
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    body = resp.read().decode()
                    return json.loads(body) if body else {}
            except urllib.error.HTTPError as e:
                if e.code in (404, 410):
                    return {"_gone": True}
                log.warning("API %s %s returned HTTP %d", method, path, e.code)
                return None
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                log.warning("API %s %s failed: %s", method, path, e)
                return None

        def timed_out() -> bool:
            if time.time() >= deadline:
                log.warning("Purge timeout (%ds) reached — proceeding with infra teardown", PURGE_TIMEOUT)
                return True
            return False

        # TODO: remove the manual resource bundle deletion in favor of just
        # calling the API Endpoint which does the full deletion on its own.

        # --- 1. Delete all clusters ---
        log.info("Listing clusters...")
        clusters_resp = sigv4_request("GET", "/api/v0/clusters?limit=100")
        if clusters_resp is None:
            log.warning("Could not list clusters — skipping purge")
            return

        cluster_items = clusters_resp.get("items", [])
        if cluster_items:
            log.info("Found %d cluster(s) — deleting...", len(cluster_items))
            for cluster in cluster_items:
                if timed_out():
                    return
                cid = cluster.get("id", "")
                cname = cluster.get("name", "unknown")
                log.info("  Deleting cluster: %s (%s)", cname, cid)
                sigv4_request("DELETE", f"/api/v0/clusters/{cid}")
        else:
            log.info("No clusters found.")

        if timed_out():
            return

        # --- 2. Delete all resource bundles ---
        log.info("Listing resource bundles...")
        all_bundle_ids = []
        page = 1
        while not timed_out():
            bundles_resp = sigv4_request("GET", f"/api/v0/resource_bundles?page={page}&size=100")
            if bundles_resp is None:
                log.warning("Could not list resource bundles — skipping bundle deletion")
                break
            items = bundles_resp.get("items", [])
            if not items:
                break
            for item in items:
                bid = item.get("id", "")
                if bid:
                    all_bundle_ids.append(bid)
            total = bundles_resp.get("total", 0)
            if len(all_bundle_ids) >= total:
                break
            page += 1

        if all_bundle_ids:
            log.info("Found %d resource bundle(s) — deleting...", len(all_bundle_ids))
            for bid in all_bundle_ids:
                if timed_out():
                    return
                log.info("  Deleting bundle: %s", bid)
                sigv4_request("DELETE", f"/api/v0/resource_bundles/{bid}")
        else:
            log.info("No resource bundles found.")

        if timed_out():
            return

        # --- 3. Verify clusters gone ---
        log.info("Verifying cluster deletion...")
        while not timed_out():
            resp = sigv4_request("GET", "/api/v0/clusters?limit=100")
            if resp is None:
                break
            remaining = len(resp.get("items", []))
            if remaining == 0:
                log.info("All clusters confirmed deleted.")
                break
            log.info("  %d cluster(s) still present — waiting 10s...", remaining)
            time.sleep(10)

        if timed_out():
            return

        # --- 4. Verify bundles gone ---
        log.info("Verifying resource bundle removal...")
        while not timed_out():
            resp = sigv4_request("GET", "/api/v0/resource_bundles?page=1&size=100")
            if resp is None:
                break
            remaining = len(resp.get("items", []))
            if remaining == 0:
                log.info("All resource bundles confirmed removed.")
                break
            log.info("  %d bundle(s) still present — waiting 10s...", remaining)
            time.sleep(10)

        log.info("Cluster & bundle purge complete.")

    def _get_api_url(self, git: GitManager) -> str | None:
        """Fetch the API Gateway URL from terraform state.

        Returns the URL string, or None if it cannot be determined.
        """
        try:
            regional_account_id = self.aws.get_target_account_id("regional")
            state_bucket = f"terraform-state-{regional_account_id}-{self.region}"
            if not self.rc_project:
                raise RuntimeError("Cannot read RC state: RC project name is unavailable")
            state_key = f"regional-cluster/{self.rc_project}.tfstate"
            tf_dir = git.work_dir / "terraform" / "config" / "regional-cluster"

            env = os.environ.copy()
            env.update(self.aws.target_subprocess_env("regional"))

            subprocess.run(
                [
                    "terraform", "init", "-reconfigure",
                    f"-backend-config=bucket={state_bucket}",
                    f"-backend-config=key={state_key}",
                    f"-backend-config=region={self.region}",
                    "-backend-config=use_lockfile=true",
                ],
                cwd=tf_dir,
                env=env,
                check=True,
                capture_output=True,
                timeout=120,
            )

            result = subprocess.run(
                ["terraform", "output", "-raw", "api_gateway_invoke_url"],
                cwd=tf_dir,
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            url = result.stdout.strip()
            if result.returncode == 0 and url.startswith("http"):
                return url

            log.warning("terraform output api_gateway_invoke_url returned empty or failed (rc=%d)", result.returncode)
            return None
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError, RuntimeError) as e:
            log.warning("Failed to fetch API URL from terraform state: %s", e)
            return None

    def _run_teardown(self, git: GitManager, fire_and_forget: bool = False):
        """Tear down infrastructure via GitOps and destroy the bootstrap infrastructure."""

        # Phase 1: Infrastructure teardown
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Infrastructure Destroy")
        log.info("==========================================")

        # Use the existing branch revision without pushing delete flags. The
        # IS_DESTROY pipeline variable makes every build phase honor teardown
        # semantics without requiring a source-triggered execution.
        desired_sha = git.current_sha()
        destroy_overrides = {"IS_DESTROY": "true"}

        if not self.rc_project:
            raise RuntimeError("Cannot start RC teardown: RC project name is unavailable")

        # Start all cluster destroys before waiting for any to finish.
        destroy_projects = [p for p in [self.rc_project, *self.mc_projects] if p]
        pipeline_names = [self.target_monitor.pipeline_name(p) for p in destroy_projects]

        # Remove push triggers before starting any destroy: under SUPERSEDED a
        # push during/after the destroy would queue an apply that recreates the
        # cluster. Then abandon any execution still running (e.g. a provision step
        # that timed out mid-apply) so the destroy isn't blocked.
        for pipeline_name in pipeline_names:
            self.target_monitor.disable_push_triggers(pipeline_name)
        self.target_monitor.stop_active_executions(pipeline_names)

        teardown_builds = []
        for project in destroy_projects:
            pipeline = self.target_monitor.pipeline_name(project)
            execution_id = self.target_monitor.start_pipeline(
                pipeline,
                desired_sha,
                environment_variables=destroy_overrides,
            )
            teardown_builds.append((project, execution_id))

        if fire_and_forget:
            log.info(
                "Fire-and-forget mode: MC and RC teardown started and "
                "will continue asynchronously. Phases 2 (delete projects) and 3 "
                "(terraform destroy) will NOT run."
            )
            return

        failed = self._wait_for_teardown_builds(teardown_builds, desired_sha)
        self._raise_teardown_failure(failed)

        # Phase 2: Delete CodePipelines and CodeBuild projects through the
        # same per-cluster lifecycle commands used by the autoscaler.
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Delete Cluster Resources")
        log.info("==========================================")

        self._delete_cluster_resources(git)

        log.info("CodePipelines and CodeBuild projects deleted.")

        # Phase 3: Destroy bootstrap infrastructure via terraform destroy
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Destroy Bootstrap Infrastructure")
        log.info("==========================================")
        self._destroy_provisioner(git)

        # Delete the ephemeral branch last, once infra and pipelines are gone.
        # Pipelines source config from this branch, so it must survive until the
        # destroys and deletes above complete. Skipped in fire-and-forget mode.
        git.delete_eph_branch()

        log.info("Teardown complete.")

    def _run_cluster_resource_action(self, git: GitManager, action: str, config_path: Path):
        """Run one explicit cluster-resource lifecycle action."""
        script = git.work_dir / "scripts" / "provision-cluster-resources.sh"
        if not script.exists():
            raise FileNotFoundError(f"Cluster resource script not found at {script}")

        env = os.environ.copy()
        env.update(self.aws.subprocess_env)
        env["ENVIRONMENT"] = TARGET_ENVIRONMENT

        log.info("Running cluster resource action: %s (%s)", action, config_path)
        subprocess.run(
            [
                "/bin/bash",
                str(script),
                action,
                "--config",
                str(config_path),
                "--region-deployment",
                self.region,
            ],
            cwd=git.work_dir,
            env=env,
            stdout=sys.stdout,
            stderr=sys.stderr,
            check=True,
            timeout=TEARDOWN_TIMEOUT,
        )

    def _delete_cluster_resources(self, git: GitManager):
        """Delete all rendered MC resources, followed by the RC resources."""
        deploy_dir = git.work_dir / "deploy" / TARGET_ENVIRONMENT / self.region
        resource_config_dir = deploy_dir / "pipeline-provisioner-inputs"

        for config_path in sorted(resource_config_dir.glob("management-cluster-*.json")):
            self._run_cluster_resource_action(git, "delete-mc", config_path)

        rc_config_path = resource_config_dir / "regional-cluster.json"
        if rc_config_path.exists():
            self._run_cluster_resource_action(git, "delete-rc", rc_config_path)

    def _wait_for_teardown_builds(
        self,
        builds: list[tuple[str, str]],
        desired_sha: str,
    ) -> list[str]:
        """Wait for a teardown phase and return projects that failed."""
        if not builds:
            return []

        failed = []
        with ThreadPoolExecutor(max_workers=len(builds)) as executor:
            future_to_build = {
                executor.submit(
                    self.target_monitor.wait_for_pipeline,
                    self.target_monitor.pipeline_name(project_name),
                    execution_id,
                    desired_sha,
                ): project_name
                for project_name, execution_id in builds
            }

            for future in as_completed(future_to_build):
                project_name = future_to_build[future]
                try:
                    result = future.result()
                except Exception:
                    # Catch everything (e.g. botocore ClientError) so one failed
                    # future doesn't abort monitoring of the remaining teardowns.
                    log.exception("Teardown build '%s' failed", project_name)
                    failed.append(project_name)
                    continue

                if result.status != "SUCCEEDED" or result.error:
                    log.error(
                        "Teardown build '%s' did not succeed (status=%s): %s",
                        project_name,
                        result.status,
                        result.error or "no failure detail returned",
                    )
                    failed.append(project_name)
                    continue
                log.info("✓ Teardown build succeeded: %s", project_name)
        return failed

    def _raise_teardown_failure(self, failed: list[str]) -> None:
        if failed:
            try:
                self.collect_codebuild_logs()
            except Exception:
                log.exception("Failed to collect teardown CodeBuild logs")
            raise RuntimeError(
                f"{len(failed)} teardown build(s) failed: {', '.join(failed)}"
            )

    def _destroy_provisioner(self, git: GitManager):
        """Destroy bootstrap infrastructure via terraform destroy.

        Removes the connection from state first so it persists across CI runs,
        then destroys everything else (platform image ECR, build-platform-image
        CodeBuild, RC/MC IAM roles).
        """
        bootstrap_dir = git.work_dir / "terraform" / "config" / "central-account-bootstrap"

        account_id = self.aws.session.client("sts").get_caller_identity()["Account"]
        state_bucket = f"terraform-state-{account_id}"
        state_key = f"{git.eph_prefix}-central-account-bootstrap/terraform.tfstate"

        env = os.environ.copy()
        env.update(self.aws.subprocess_env)

        try:
            subprocess.run(
                [
                    "terraform",
                    "init",
                    "-reconfigure",
                    f"-backend-config=bucket={state_bucket}",
                    f"-backend-config=key={state_key}",
                    f"-backend-config=region={self.aws.central_region}",
                    "-backend-config=use_lockfile=true",
                ],
                cwd=bootstrap_dir,
                env=env,
                check=True,
                timeout=TEARDOWN_TIMEOUT,
            )

            # The connection is shared across environments. An unsuccessful
            # state removal must never turn into deletion of that connection.
            connection_resource = "aws_codestarconnections_connection.github"

            def connection_in_state():
                result = subprocess.run(
                    ["terraform", "state", "list"],
                    cwd=bootstrap_dir,
                    env=env,
                    check=True,
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                return connection_resource in result.stdout.splitlines()

            if connection_in_state():
                subprocess.run(
                    ["terraform", "state", "rm", connection_resource],
                    cwd=bootstrap_dir,
                    env=env,
                    check=True,
                    timeout=60,
                )
            if connection_in_state():
                raise RuntimeError(
                    "Refusing bootstrap destruction: the shared GitHub connection "
                    "is still managed by this Terraform state"
                )

            # Full destroy (connection already removed from state)
            subprocess.run(
                ["terraform", "destroy", "-auto-approve",
                 f"-var=github_repository={git.fork_repo}"],
                cwd=bootstrap_dir,
                env=env,
                check=True,
                timeout=TEARDOWN_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                f"Terraform teardown timed out after {TEARDOWN_TIMEOUT}s"
            )
        log.info("Bootstrap infrastructure destroyed.")


# Patterns that match AWS secrets we don't want in Prow artifacts
_SENSITIVE_PATTERNS = [
    (re.compile(r"(?:AKIA|ASIA)[A-Z0-9]{16}"), "[REDACTED_AWS_KEY]"),
    (re.compile(r"(?i)(aws_secret_access_key|secret_key)\s*[=:]\s*\S+"), r"\1=[REDACTED]"),
    (re.compile(r"(?i)(aws_session_token|security_token)\s*[=:]\s*\S+"), r"\1=[REDACTED]"),
]


def _redact_sensitive(text: str) -> str:
    for pattern, replacement in _SENSITIVE_PATTERNS:
        text = pattern.sub(replacement, text)
    return text
