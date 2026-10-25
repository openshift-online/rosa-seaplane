import json
import subprocess
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest

import main as provider_main
from orchestrator import EphemeralEnvOrchestrator


def make_env():
    env = EphemeralEnvOrchestrator("owner/repo", "feature", "/unused", "us-east-1", "eph-test")
    env.rc_project = "eph-test-regional"
    env.mc_projects = ["eph-test-mc01", "eph-test-mc02"]
    env.target_monitor = Mock()
    env.target_monitor.pipeline_name.side_effect = lambda project: f"{project}-pipeline"
    env.target_monitor.start_pipeline.side_effect = lambda pipeline, *a, **kw: pipeline
    env._delete_cluster_resources = Mock()
    env._destroy_provisioner = Mock()
    env.collect_codebuild_logs = Mock()
    return env


@pytest.mark.parametrize("fire_and_forget", [False, True])
@pytest.mark.parametrize("mc_count", [0, 2])
def test_teardown_starts_all_clusters_before_waiting(fire_and_forget, mc_count):
    env = make_env()
    env.mc_projects = env.mc_projects[:mc_count]
    git = Mock()
    git.current_sha.return_value = "a" * 40
    projects = [env.rc_project, *env.mc_projects]
    pipelines = [f"{project}-pipeline" for project in projects]
    events = Mock()
    events.attach_mock(env.target_monitor.disable_push_triggers, "disable")
    events.attach_mock(env.target_monitor.stop_active_executions, "stop")
    events.attach_mock(env.target_monitor.start_pipeline, "start")

    def wait(builds, sha):
        assert sha == "a" * 40
        assert builds == list(zip(projects, pipelines))
        started = [c.args[0] for c in env.target_monitor.start_pipeline.call_args_list]
        assert started == pipelines
        env._delete_cluster_resources.assert_not_called()
        env._destroy_provisioner.assert_not_called()
        git.delete_eph_branch.assert_not_called()
        return []

    env._wait_for_teardown_builds = Mock(side_effect=wait)
    env._run_teardown(git, fire_and_forget=fire_and_forget)

    assert [c[0] for c in events.mock_calls] == [
        *(["disable"] * len(projects)), "stop", *(["start"] * len(projects)),
    ]
    env.target_monitor.stop_active_executions.assert_called_once_with(pipelines)
    for call, pipeline in zip(env.target_monitor.start_pipeline.call_args_list, pipelines):
        assert call.args == (pipeline, "a" * 40)
        assert call.kwargs == {"environment_variables": {"IS_DESTROY": "true"}}
    assert env._wait_for_teardown_builds.call_count == (0 if fire_and_forget else 1)
    assert env._delete_cluster_resources.called is not fire_and_forget
    assert env._destroy_provisioner.called is not fire_and_forget
    assert git.delete_eph_branch.called is not fire_and_forget


@pytest.mark.parametrize("failed_project", ["eph-test-regional", "eph-test-mc01"])
def test_failed_teardown_preserves_pipeline_and_bootstrap_resources(failed_project):
    env = make_env()
    env._wait_for_teardown_builds = Mock(return_value=[failed_project])
    git = Mock()
    git.current_sha.return_value = "a" * 40

    with pytest.raises(RuntimeError, match="teardown build.*failed"):
        env._run_teardown(git)

    assert env.target_monitor.start_pipeline.call_count == 3
    env.collect_codebuild_logs.assert_called_once()
    env._delete_cluster_resources.assert_not_called()
    env._destroy_provisioner.assert_not_called()
    git.delete_eph_branch.assert_not_called()


@pytest.mark.parametrize(
    "state_failure",
    [None, "already_absent", "initial_read", "remove", "verification_read", "still_present"],
)
def test_bootstrap_destroy_requires_shared_connection_detached(tmp_path, state_failure):
    env = make_env()
    env.aws = Mock(subprocess_env={}, central_region="us-east-1")
    env.aws.session.client.return_value.get_caller_identity.return_value = {
        "Account": "000000000000",
    }
    git = Mock(work_dir=tmp_path, eph_prefix="eph-test", fork_repo="owner/repo")
    connection = "aws_codestarconnections_connection.github"
    state_reads = 0
    destroyed = False

    def run(command, **kwargs):
        nonlocal state_reads, destroyed
        if command[:3] == ["terraform", "state", "list"]:
            state_reads += 1
            if state_failure == ("initial_read" if state_reads == 1 else "verification_read"):
                raise subprocess.CalledProcessError(1, command)
            present = state_failure != "already_absent" and (
                state_reads == 1 or state_failure == "still_present"
            )
            return subprocess.CompletedProcess(command, 0, stdout=connection if present else "")
        if command[:3] == ["terraform", "state", "rm"] and state_failure == "remove":
            if kwargs.get("check"):
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 1)
        if command[:2] == ["terraform", "destroy"]:
            destroyed = True
        return subprocess.CompletedProcess(command, 0)

    with patch("orchestrator.subprocess.run", side_effect=run):
        if state_failure in (None, "already_absent"):
            EphemeralEnvOrchestrator._destroy_provisioner(env, git)
            assert destroyed
        else:
            with pytest.raises((subprocess.CalledProcessError, RuntimeError)):
                EphemeralEnvOrchestrator._destroy_provisioner(env, git)
            assert not destroyed


def test_teardown_resync_disables_applies_before_pushing(tmp_path):
    env = make_env()
    region_dir = tmp_path / "config" / "ephemeral"
    region_dir.mkdir(parents=True)
    (region_dir / "us-east-1.yaml").write_text("{}\n")
    git = Mock(work_dir=tmp_path)
    env.aws = SimpleNamespace(session=Mock(), target_session=Mock())
    env._setup_aws = Mock()
    env._read_project_names = Mock()
    env._inject_ephemeral_config = Mock()
    env._purge_clusters = Mock()
    env._run_teardown = Mock()
    events = Mock()
    events.attach_mock(env.target_monitor.disable_push_triggers, "disable")
    events.attach_mock(env.target_monitor.stop_active_executions, "stop")
    events.attach_mock(git.render_and_push, "push")
    events.attach_mock(env._run_teardown, "destroy")

    with patch("orchestrator.GitManager", return_value=git), \
            patch("orchestrator.BuildMonitor"), \
            patch("orchestrator.PipelineMonitor", return_value=env.target_monitor):
        env.teardown(with_resync=True)

    assert [c[0] for c in events.mock_calls] == [
        "disable", "disable", "disable", "stop", "push", "destroy",
    ]
    git.render_and_push.assert_called_once_with(
        "ci: refresh ephemeral environment for teardown", force=True, force_push_if_clean=True,
    )


def test_cli_teardown_resync_dispatches_destroy(monkeypatch):
    monkeypatch.setattr("sys.argv", ["provider", "--teardown", "--resync", "--id", "test"])
    with patch.object(provider_main, "EphemeralEnvOrchestrator") as cls:
        provider_main.main()
    cls.return_value.teardown.assert_called_once_with(fire_and_forget=False, with_resync=True)
    cls.return_value.resync.assert_not_called()
    cls.return_value.provision.assert_not_called()


def test_cli_resume_rejects_resync(monkeypatch):
    monkeypatch.setattr("sys.argv", ["provider", "--resume", "--resync", "--id", "test"])
    with pytest.raises(SystemExit) as exc:
        provider_main.main()
    assert exc.value.code == 2


@pytest.mark.parametrize("operation", ["outputs", "api_url"])
def test_rc_state_reads_use_rendered_cluster_name(tmp_path, operation):
    env = make_env()
    env.rc_project = "eph-test-custom-rc"
    env.aws = Mock()
    env.aws.get_target_account_id.return_value = "000000000000"
    env.aws.target_subprocess_env.return_value = {}
    git = Mock(work_dir=tmp_path)
    result = SimpleNamespace(stdout="https://example.com", returncode=0)
    with patch("orchestrator.subprocess.run", return_value=result) as run:
        if operation == "outputs":
            env._save_terraform_outputs(git, str(tmp_path / "outputs.json"))
        else:
            assert env._get_api_url(git) == "https://example.com"
    assert "-backend-config=key=regional-cluster/eph-test-custom-rc.tfstate" in run.call_args_list[0].args[0]


@pytest.mark.parametrize("cluster_type", ["RC", "MC"])
def test_saved_outputs_need_no_zoa_enablement_metadata(tmp_path, cluster_type):
    env = make_env()
    values = {
        "cluster_name": "eph-test-cluster",
        "cluster_endpoint": "https://cluster.example.com",
        "vpc_id": "vpc-12345678",
        "api_gateway_invoke_url": "https://api.example.com",
        "rhobs_api_url": "https://rhobs.example.com",
        "oidc_bucket_name": "eph-test-oidc",
        "oidc_cloudfront_domain": "oidc.example.com",
        "zoa_api_function_url": "https://zoa.example.com",
    }
    output_path = tmp_path / "outputs.json"
    output_path.write_text(json.dumps({key: {"value": value} for key, value in values.items()}))

    # Saved outputs remain usable without a rendered tree or a zoa-enabled file.
    env._validate_saved_outputs(str(output_path), cluster_type)


@pytest.mark.parametrize("cluster_type,missing", [("RC", "rhobs_api_url"), ("MC", "oidc_bucket_name")])
def test_saved_outputs_still_require_cluster_dependencies(tmp_path, cluster_type, missing):
    env = make_env()
    values = {
        "cluster_name": "eph-test-cluster",
        "cluster_endpoint": "https://cluster.example.com",
        "vpc_id": "vpc-12345678",
        "api_gateway_invoke_url": "https://api.example.com",
        "oidc_cloudfront_domain": "oidc.example.com",
        "zoa_api_function_url": "https://zoa.example.com",
    }
    output_path = tmp_path / "outputs.json"
    output_path.write_text(json.dumps({key: {"value": value} for key, value in values.items()}))

    with pytest.raises(RuntimeError, match=f"{missing}=empty"):
        env._validate_saved_outputs(str(output_path), cluster_type)


@pytest.mark.parametrize("resume", [False, True])
def test_cli_saves_region_without_zoa_enablement_metadata(tmp_path, monkeypatch, resume):
    output_path = tmp_path / "outputs.json"
    args = ["provider", "--id", "test", "--save-regional-state", str(output_path)]
    if resume:
        args.append("--resume")
    monkeypatch.setattr("sys.argv", args)
    env = Mock(spec=make_env(), region="us-east-1")

    with patch.object(provider_main, "EphemeralEnvOrchestrator", return_value=env), \
            patch.object(provider_main, "discover_region", return_value="us-east-1"):
        provider_main.main()

    operation = env.resume if resume else env.provision
    assert operation.call_args.kwargs["save_rc_state"] == str(output_path)
    assert (tmp_path / "region").read_text() == "us-east-1"
    assert not (tmp_path / "zoa-enabled").exists()
