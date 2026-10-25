import base64
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import yaml

log = logging.getLogger(__name__)

GIT_TIMEOUT = 120  # seconds; clone/push can be slow on large repos
HTTP_TIMEOUT = 30  # seconds; GitHub API calls
RENDER_TIMEOUT = 300  # seconds; render.py may run terraform/heavy scripts
UPSTREAM_REPO_NAME = "rosa-seaplane"


class GitManager:
    """Manages git operations for ephemeral branch lifecycle.

    Creates an ephemeral branch from a source repo/branch, handles commits and
    pushes, and deletes the branch on teardown. Ephemeral branches accumulate
    refs on the fork over time, which slows ArgoCD repo-server git operations, so
    a successful teardown removes the branch it created.
    """

    def __init__(self, creds_dir: str, repo: str, branch: str,
                 eph_branch_name: str | None = None):
        self.creds_dir = Path(creds_dir)
        self.source_repo = repo
        self.source_branch = branch
        self.work_dir = None
        self.eph_branch = None
        self.eph_prefix = None
        self.fork_repo = None
        self._auth_header = None
        self._eph_branch_override = eph_branch_name
        self._pre_push_base_sha: str | None = None
        self.pushed_file_paths: list[str] = []

    def _github_token(self) -> str:
        """Read the git token from credentials directory or environment."""
        env_token = (
            os.environ.get("SEAPLANE_CI_GITHUB_TOKEN")
            or os.environ.get("GITHUB_TOKEN")
        )
        if env_token:
            return env_token
        return (self.creds_dir / "github_token").read_text().strip()

    def _setup_auth(self, token: str):
        """Derive and cache the HTTP auth header from a GitHub token."""
        creds = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        self._auth_header = f"Authorization: Basic {creds}"

    def _run_git(self, *args, cwd=None, check=True, auth=False) -> subprocess.CompletedProcess:
        """Run a git command.

        Args:
            auth: When True, inject http.extraHeader for token auth so that
                  remote URLs stay tokenless (no secrets in .git/config or
                  error messages).
        """
        cmd = ["git"]
        if auth and self._auth_header:
            cmd += ["-c", f"http.extraHeader={self._auth_header}"]
        cmd += list(args)
        result = subprocess.run(
            cmd, cwd=cwd or self.work_dir, check=False,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=GIT_TIMEOUT,
        )
        if check and result.returncode != 0:
            stdout = result.stdout
            stderr = result.stderr
            if auth and self._auth_header:
                # Redact the auth header from output to avoid leaking tokens
                stdout = stdout.replace(self._auth_header, "[REDACTED]")
                stderr = stderr.replace(self._auth_header, "[REDACTED]")
            raise RuntimeError(
                f"git {args[0]} failed (exit {result.returncode})\n"
                f"stdout: {stdout}\nstderr: {stderr}"
            )
        return result

    def current_sha(self) -> str:
        """Return the checked-out commit SHA."""
        return self._run_git("rev-parse", "HEAD").stdout.strip()

    def _resolve_fork_owner(self, token: str) -> str:
        """Get the GitHub username associated with the git token."""
        import urllib.request

        url = "https://api.github.com/user"
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"token {token}"},
        )
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            data = json.loads(resp.read())
        return data["login"]

    def create_eph_branch(self, eph_prefix: str):
        """Clone source repo/branch and create an ephemeral branch.

        Clones from the source (upstream) repo, then adds the token owner's
        fork as a 'ci' remote and pushes the ephemeral branch there.

        Args:
            eph_prefix: Unique prefix for this run (e.g. 'eph-a1b2c3d4').
                        Used in branch name, resource names, and state keys.
        """
        self.eph_prefix = eph_prefix
        sanitized = re.sub(r"[/]", "-", self.source_branch)
        self.eph_branch = f"{self.eph_prefix}-{sanitized}-ci"

        token = self._github_token()
        self._setup_auth(token)
        clone_url = f"https://github.com/{self.source_repo}.git"

        tmpdir = tempfile.mkdtemp(prefix="ephemeral-")
        self.work_dir = Path(tmpdir) / "repo"

        log.info("Cloning %s (branch: %s)", self.source_repo, self.source_branch)
        self._run_git(
            "clone", "--branch", self.source_branch, "--single-branch", clone_url, str(self.work_dir),
            cwd=".", auth=True,
        )
        head = self._run_git("rev-parse", "HEAD")
        log.info("Cloned at %s (https://github.com/%s/tree/%s)", head.stdout.strip(), self.source_repo, head.stdout.strip())

        # Configure git identity
        self._run_git("config", "user.email", "ci-bot@rosa-seaplane.dev")
        self._run_git("config", "user.name", "ROSA CI Bot")

        # Add the token owner's fork as the push remote
        fork_owner = self._resolve_fork_owner(token)
        self.fork_repo = f"{fork_owner}/{UPSTREAM_REPO_NAME}"
        fork_url = f"https://github.com/{self.fork_repo}.git"
        self._run_git("remote", "add", "ci", fork_url)
        log.info("Push remote: %s (fork of %s)", self.fork_repo, self.source_repo)

        # Create and push ephemeral branch to the fork
        self._run_git("checkout", "-b", self.eph_branch)

        # Strip .github/workflows/ before pushing: the bot PAT lacks the
        # `workflow` scope that GitHub requires to push branches containing
        # workflow files, and ephemeral branches don't run Actions in the fork.
        workflows_dir = self.work_dir / ".github" / "workflows"
        if workflows_dir.exists():
            shutil.rmtree(workflows_dir)
            self._run_git("add", "-A")
            self._run_git("commit", "-m", "ci: strip .github/workflows (bot PAT lacks workflow scope)")

        self._run_git("push", "-u", "ci", self.eph_branch, auth=True)

        log.info("Created ephemeral branch: %s on %s", self.eph_branch, self.fork_repo)

    def checkout_eph_branch(self, eph_prefix: str):
        """Clone the fork and check out an existing ephemeral branch.

        Used for reconnecting to a previously provisioned environment (e.g. teardown).

        Args:
            eph_prefix: The ephemeral prefix used during provisioning (e.g. 'eph-a1b2c3d4').
        """
        self.eph_prefix = eph_prefix
        if self._eph_branch_override:
            if not self._eph_branch_override.startswith(f"{eph_prefix}-"):
                log.warning(
                    "Ephemeral branch override '%s' does not match expected prefix '%s-'",
                    self._eph_branch_override, eph_prefix,
                )
            self.eph_branch = self._eph_branch_override
        else:
            sanitized = re.sub(r"[/]", "-", self.source_branch)
            self.eph_branch = f"{self.eph_prefix}-{sanitized}-ci"

        token = self._github_token()
        self._setup_auth(token)

        # Resolve fork
        fork_owner = self._resolve_fork_owner(token)
        self.fork_repo = f"{fork_owner}/{UPSTREAM_REPO_NAME}"
        fork_url = f"https://github.com/{self.fork_repo}.git"

        tmpdir = tempfile.mkdtemp(prefix="ephemeral-")
        self.work_dir = Path(tmpdir) / "repo"

        log.info("Cloning %s (branch: %s)", self.fork_repo, self.eph_branch)
        self._run_git(
            "clone", "--branch", self.eph_branch, "--single-branch", fork_url, str(self.work_dir),
            cwd=".", auth=True,
        )

        # Configure git identity
        self._run_git("config", "user.email", "ci-bot@rosa-seaplane.dev")
        self._run_git("config", "user.name", "ROSA CI Bot")

        # Add fork as push remote (same repo for ephemeral branches)
        self._run_git("remote", "add", "ci", fork_url)

        log.info("Checked out existing ephemeral branch: %s on %s", self.eph_branch, self.fork_repo)

    def resync_eph_branch(self, eph_prefix: str):
        """Reset the ephemeral branch to the latest source branch tip.

        Checks out the fork's ephemeral branch, fetches the latest source branch,
        and hard-resets to it. Does NOT push — the caller is expected to
        re-inject config, render, and push in a single commit via
        render_and_push().

        Args:
            eph_prefix: The ephemeral prefix used during provisioning (e.g. 'eph-a1b2c3d4').
        """
        self.checkout_eph_branch(eph_prefix)

        source_url = f"https://github.com/{self.source_repo}.git"
        self._run_git("remote", "add", "upstream", source_url)

        log.info("Fetching latest %s from upstream (%s)", self.source_branch, self.source_repo)
        self._run_git("fetch", "upstream", self.source_branch, auth=True)

        head_before = self._run_git("rev-parse", "HEAD").stdout.strip()
        self._pre_push_base_sha = head_before
        log.info("Resetting %s to upstream/%s", self.eph_branch, self.source_branch)
        self._run_git("reset", "--hard", f"upstream/{self.source_branch}")
        head_after = self._run_git("rev-parse", "HEAD").stdout.strip()

        if head_before == head_after:
            log.info("Reset: %s is already up to date with upstream/%s", self.eph_branch, self.source_branch)
        else:
            count = self._run_git("rev-list", "--count", f"{head_before}..{head_after}").stdout.strip()
            log.info("Reset: %s new commits from upstream/%s", count, self.source_branch)

        # Strip .github/workflows/ again after reset — same reason as
        # create_eph_branch: bot PAT lacks `workflow` scope.
        workflows_dir = self.work_dir / ".github" / "workflows"
        if workflows_dir.exists():
            shutil.rmtree(workflows_dir)

        branch_url = f"https://github.com/{self.fork_repo}/commits/{self.eph_branch}/"
        log.info("Resync complete: %s", branch_url)

    def push(
        self,
        message: str,
        force: bool = False,
        force_push_if_clean: bool = False,
    ) -> str | None:
        """Stage all changes, commit, and push to the ephemeral branch.

        Returns:
            Full git SHA of the pushed commit, or None if nothing to commit.
        """
        base_sha = self._pre_push_base_sha or self.current_sha()
        self.pushed_file_paths = []
        self._run_git("add", "-A")

        result = self._run_git("diff", "--cached", "--quiet", check=False)
        if result.returncode == 0:
            if not force_push_if_clean:
                log.info("No changes to commit, skipping push")
                return None

            log.info("No changes to commit; force-updating the ephemeral branch")
            pushed_sha = self.current_sha()
            self.pushed_file_paths = self._changed_paths(base_sha, pushed_sha)
            push_cmd = ["push", "ci", self.eph_branch]
            if force:
                push_cmd.insert(1, "--force")
            self._run_git(*push_cmd, auth=True)
            self._pre_push_base_sha = None
            return pushed_sha

        self._run_git("commit", "-m", message)
        push_cmd = ["push", "ci", self.eph_branch]
        if force:
            push_cmd.insert(1, "--force")
        self._run_git(*push_cmd, auth=True)
        sha_result = self._run_git("rev-parse", "HEAD")
        pushed_sha = sha_result.stdout.strip()
        self.pushed_file_paths = self._changed_paths(base_sha, pushed_sha)
        log.info("Pushed: %s (SHA: %s)", message, pushed_sha[:7])
        self._pre_push_base_sha = None
        return pushed_sha

    def delete_eph_branch(self):
        """Delete the ephemeral branch from the fork (best-effort).

        Reuses the already-configured ``ci`` remote and token auth. Failures are
        logged but never raised, so a leftover branch cannot fail an otherwise
        successful teardown; stale branches can be pruned separately.
        """
        if not self.eph_branch:
            log.warning("No ephemeral branch recorded; skipping branch deletion")
            return
        try:
            result = self._run_git(
                "push", "ci", "--delete", self.eph_branch, auth=True, check=False
            )
        except (subprocess.TimeoutExpired, OSError) as e:
            log.warning(
                "Failed to delete ephemeral branch '%s' (%s); prune it manually",
                self.eph_branch, e,
            )
            return
        if result.returncode != 0:
            log.warning(
                "Failed to delete ephemeral branch '%s' (exit %s); prune it manually",
                self.eph_branch, result.returncode,
            )
            return
        log.info("Deleted ephemeral branch: %s", self.eph_branch)

    def _changed_paths(self, base_sha: str, target_sha: str) -> list[str]:
        if base_sha == target_sha:
            return []
        tree_diff = self._run_git(
            "diff", "--no-renames", "--name-only", f"{base_sha}..{target_sha}"
        )
        pushed_commits = self._run_git(
            "log",
            "--format=",
            "--name-only",
            "--no-renames",
            f"{base_sha}..{target_sha}",
        )
        return sorted(
            path
            for path in set(tree_diff.stdout.splitlines())
            | set(pushed_commits.stdout.splitlines())
            if path
        )

    def render_and_push(
        self,
        message: str,
        force: bool = False,
        force_push_if_clean: bool = False,
    ) -> str | None:
        """Run render.py in the work directory, then commit and push.

        Returns:
            Full git SHA of the pushed commit, or None if nothing to commit.
        """
        render_script = self.work_dir / "scripts" / "render.py"
        log.info("Running render.py (eph_prefix=%s)", self.eph_prefix)
        env = os.environ.copy()
        if self.eph_prefix:
            env["EPH_PREFIX"] = self.eph_prefix
        result = subprocess.run(
            ["uv", "run", "--no-cache", str(render_script)],
            cwd=self.work_dir,
            env=env,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=RENDER_TIMEOUT,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"render.py failed (exit {result.returncode})\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}"
            )
        return self.push(
            message,
            force=force,
            force_push_if_clean=force_push_if_clean,
        )

    def modify_config(self, environment: str, region: str, callback, force: bool = False) -> str | None:
        """Load a region config file, apply callback modifications, render, and push.

        Args:
            environment: Environment name (e.g. "ci").
            region: AWS region (e.g. "us-east-1"), maps to config/<env>/<region>.yaml.
            callback: A function that receives and modifies the region config dict.

        Returns:
            Full git SHA of the pushed commit, or None if nothing to commit.
        """
        region_file = self.work_dir / "config" / environment / f"{region}.yaml"
        if not region_file.exists():
            raise FileNotFoundError(
                f"Region config not found: {region_file}"
            )

        with open(region_file) as f:
            region_config = yaml.safe_load(f) or {}

        callback(region_config)

        with open(region_file, "w") as f:
            yaml.dump(region_config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

        return self.render_and_push(f"ci: update {environment}/{region} config", force=force)
