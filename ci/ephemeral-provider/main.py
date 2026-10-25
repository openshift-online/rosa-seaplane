#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = ["boto3", "PyYAML"]
# ///
"""
Ephemeral environment manager for ROSA Seaplane.

Provisions an ephemeral environment or tears one down. Designed for multi-step
CI pipelines where provision, tests, and teardown are separate steps:

    # Step 1: Provision (CI — BUILD_ID from Prow, hashed for collision safety)
    BUILD_ID=abc123 ./ci/ephemeral-provider/main.py

    # Step 1: Provision (local — explicit ID, used directly in prefix)
    ./ci/ephemeral-provider/main.py --id a1b2c3d4

    # Step 2: Run tests (separate CI step, same BUILD_ID)

    # Step 3: Teardown
    BUILD_ID=abc123 ./ci/ephemeral-provider/main.py --teardown

If neither --id nor BUILD_ID is set, a random ID is generated and used
directly (same as --id with a random value).
"""

import argparse
import hashlib
import logging
import os
import re
import sys
import uuid
from pathlib import Path

from __init__ import TARGET_ENVIRONMENT
from orchestrator import EphemeralEnvOrchestrator, discover_region

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


def make_eph_prefix(env_id: str, externally_set: bool) -> str:
    """Generate an ephemeral environment prefix from an ID.

    When the ID is externally set (e.g. BUILD_ID from Prow), it is hashed
    to avoid collisions between sequential IDs. For locally generated or
    explicitly passed IDs (already random), the ID is used directly for
    traceability.
    """
    if externally_set:
        short_id = hashlib.sha256(env_id.encode()).hexdigest()[:6]
    else:
        short_id = env_id
    return f"eph-{short_id}"


def main():
    parser = argparse.ArgumentParser(description="Ephemeral environment manager for ROSA Seaplane")
    lifecycle_group = parser.add_mutually_exclusive_group()
    lifecycle_group.add_argument(
        "--teardown",
        action="store_true",
        help="Tear down a previously provisioned ephemeral environment",
    )
    lifecycle_group.add_argument(
        "--teardown-fire-and-forget",
        action="store_true",
        help=(
            "Start MC and RC teardown together, then exit without waiting "
            "for completion"
        ),
    )
    parser.add_argument(
        "--resync",
        action="store_true",
        help="With --teardown: sync CI branch from --branch then destroy. Alone: resync (apply).",
    )
    lifecycle_group.add_argument(
        "--resume",
        action="store_true",
        help="Resume provisioning using an existing ephemeral branch",
    )
    parser.add_argument(
        "--resync-before-resume",
        action="store_true",
        help="Resync the existing ephemeral branch before resuming provisioning",
    )
    parser.add_argument(
        "--id",
        default=None,
        dest="env_id",
        help="Explicit environment ID (used directly in prefix, no hashing). "
             "If omitted, falls back to BUILD_ID env var (hashed) or generates a random ID.",
    )
    parser.add_argument(
        "--repo",
        default=os.environ.get("REPOSITORY_URL", "openshift-online/rosa-seaplane"),
        help="GitHub repository in owner/name format (default: from REPOSITORY_URL env var)",
    )
    parser.add_argument(
        "--branch",
        default=os.environ.get("REPOSITORY_BRANCH", "main"),
        help="Source branch to test (default: from REPOSITORY_BRANCH env var)",
    )
    parser.add_argument(
        "--eph-branch",
        default=None,
        help="Explicit ephemeral branch name (overrides derivation from --branch). "
             "Used after swap-branch to preserve the ephemeral branch identity.",
    )
    parser.add_argument(
        "--creds-dir",
        default=os.environ.get("CREDS_DIR", "/var/run/rosa-credentials/"),
        help="Directory containing CI credentials (optional if credentials are passed as env vars)",
    )
    parser.add_argument(
        "--override-dir",
        default=os.environ.get("EPHEMERAL_OVERRIDE_DIR", ""),
        help="Path to local config overrides directory that replaces config/ephemeral/ "
             "(default: from EPHEMERAL_OVERRIDE_DIR env var)",
    )
    parser.add_argument(
        "--provision-override-file",
        action="append",
        default=[],
        metavar="TARGET:OVERRIDE",
        help="Deep-merge a YAML override file into a repo file before committing. "
             "Format: <target-path>:<override-file>. Can be specified multiple times. "
             "List items are matched by 'name' key. "
             "Example: argocd/config/regional-cluster/platform-api/values.yaml:override.yaml",
    )
    parser.add_argument(
        "--save-regional-state",
        metavar="PATH",
        help="Save RC terraform outputs (JSON) to PATH after provisioning",
    )
    parser.add_argument(
        "--save-management-state",
        metavar="PATH",
        help="Save MC terraform outputs (JSON) to PATH after provisioning",
    )
    args = parser.parse_args()

    if args.resync_before_resume and not args.resume:
        parser.error("--resync-before-resume requires --resume")

    if args.resume and args.resync:
        parser.error("--resume uses --resync-before-resume, not --resync")

    # Normalize repo format (strip github.com prefix and .git suffix if present)
    repo = re.sub(r".*github\.com/", "", args.repo)
    repo = re.sub(r"\.git$", "", repo)

    is_teardown = args.teardown or args.teardown_fire_and_forget

    # Resolve environment ID: --id flag > BUILD_ID env var > random generation
    if args.env_id:
        env_id = args.env_id
        externally_set = False
    elif os.environ.get("BUILD_ID"):
        env_id = os.environ["BUILD_ID"]
        externally_set = True
    else:
        if is_teardown or args.resync or args.resume:
            log.error("--id or BUILD_ID must be set for %s (needed to identify the ephemeral environment)",
                       "teardown" if is_teardown else "resume" if args.resume else "resync")
            sys.exit(1)
        env_id = uuid.uuid4().hex[:8]
        externally_set = False

    eph_prefix = make_eph_prefix(env_id, externally_set)
    log.info("Ephemeral prefix: %s (ID: %s)", eph_prefix, env_id)

    # Discover region from config files (override dir takes precedence).
    # For teardown, region is discovered from the ephemeral branch after checkout
    # (inside the orchestrator), so we pass a placeholder here.
    override_dir = args.override_dir or None
    if is_teardown or args.resume:
        region = ""  # discovered from the existing ephemeral branch
    else:
        if override_dir and Path(override_dir).exists():
            env_config_dir = Path(override_dir)
        else:
            workspace = Path(os.environ.get("WORKSPACE_DIR", "."))
            env_config_dir = workspace / "config" / TARGET_ENVIRONMENT
        region = discover_region(env_config_dir)
        log.info("Region: %s (from %s)", region, env_config_dir)

    # Parse --provision-override-file args into (target_path, override_file) tuples
    provision_overrides = []
    for entry in args.provision_override_file:
        if ":" not in entry:
            log.error("Invalid --provision-override-file format (expected target:override): %s", entry)
            sys.exit(1)
        target, override = entry.split(":", 1)
        if not target.strip() or not override.strip():
            log.error("Invalid --provision-override-file: target and override must both be non-empty: %s", entry)
            sys.exit(1)
        provision_overrides.append((target, override))

    env = EphemeralEnvOrchestrator(
        repo=repo,
        branch=args.branch,
        creds_dir=args.creds_dir,
        region=region,
        eph_prefix=eph_prefix,
        override_dir=override_dir,
        provision_overrides=provision_overrides,
        eph_branch_name=args.eph_branch,
    )

    try:
        if args.resume:
            env.resume(
                save_rc_state=args.save_regional_state,
                save_mc_state=args.save_management_state,
                resync_before_resume=args.resync_before_resume,
            )
            if args.save_regional_state:
                region_file = Path(args.save_regional_state).parent / "region"
                region_file.write_text(env.region)
            log.info("")
            log.info("==========================================")
            log.info("Provisioning resume completed successfully!")
            log.info("==========================================")
        elif args.resync and not is_teardown:
            env.resync()
            log.info("")
            log.info("==========================================")
            log.info("Resync completed successfully!")
            log.info("==========================================")
        elif is_teardown:
            env.teardown(
                fire_and_forget=args.teardown_fire_and_forget,
                with_resync=args.resync,
            )
            log.info("")
            log.info("==========================================")
            if args.teardown_fire_and_forget:
                log.info("MC and RC teardown were started asynchronously.")
            else:
                log.info("Teardown completed successfully!")
            log.info("==========================================")
        else:
            env.provision(
                save_rc_state=args.save_regional_state,
                save_mc_state=args.save_management_state,
            )
            # Write discovered region to output dir so the Makefile can capture it
            if args.save_regional_state:
                region_file = Path(args.save_regional_state).parent / "region"
                region_file.write_text(region)
            log.info("")
            log.info("==========================================")
            log.info("Provisioning completed successfully!")
            log.info("==========================================")
            log.info("")
            log.info("To tear down this environment, run:")
            log.info("")
            log.info("    ./ci/ephemeral-provider/main.py --teardown --id %s", env_id)
            log.info("")
    except Exception:
        operation = (
            "teardown" if is_teardown else
            "resume" if args.resume else
            "resync" if args.resync else
            "provision"
        )
        log.exception("Ephemeral environment %s failed", operation)
        sys.exit(1)


if __name__ == "__main__":
    main()
