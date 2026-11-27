#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["PyYAML>=6.0"]
# ///
"""Vendor charts from the Git sources pinned in Chart.sources.yaml."""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

import yaml


def helm_dependency_metadata(dependency: dict) -> dict:
    """Return fields in Helm's chart.Dependency JSON field order."""
    fields = (
        ("name", "name"),
        ("version", "version"),
        ("repository", "repository"),
        ("condition", "condition"),
        ("tags", "tags"),
        ("enabled", "enabled"),
        ("import-values", "import-values"),
        ("alias", "alias"),
    )
    result = {}
    for json_key, yaml_key in fields:
        value = dependency.get(yaml_key)
        if json_key in ("name", "repository") or value not in (None, "", [], False):
            result[json_key] = value
    return result


def sync_chart_lock(chart_dir: Path, dependencies: list[dict]) -> None:
    """Write a Helm-compatible lock for exact-version Git dependencies."""
    locked = [helm_dependency_metadata(dependency) for dependency in dependencies]
    payload = json.dumps([locked, locked], separators=(",", ":")).encode()
    digest = "sha256:" + hashlib.sha256(payload).hexdigest()
    lock_file = chart_dir / "Chart.lock"

    if lock_file.exists():
        current = yaml.safe_load(lock_file.read_text()) or {}
        current_dependencies = current.get("dependencies", [])
        current_metadata = [helm_dependency_metadata(item) for item in current_dependencies]
        if current.get("digest") == digest and current_metadata == locked:
            return

    lock = {
        "dependencies": locked,
        "digest": digest,
        "generated": datetime.now(timezone.utc).isoformat(),
    }
    lock_file.write_text(yaml.safe_dump(lock, sort_keys=False))


def run(*args: str, stdout=None) -> str:
    if stdout is None:
        result = subprocess.run(args, check=True, text=True, capture_output=True)
        return result.stdout.strip()
    subprocess.run(args, check=True, stdout=stdout)
    return ""


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: vendor-git-helm-chart.py CHART_DIR")

    chart_dir = Path(sys.argv[1]).resolve()
    chart_file = chart_dir / "Chart.yaml"
    source_file = chart_dir / "Chart.sources.yaml"
    chart_meta = yaml.safe_load(chart_file.read_text())
    source_meta = yaml.safe_load(source_file.read_text())
    dependencies = chart_meta.get("dependencies", [])
    sources = source_meta.get("sources", [])

    if not dependencies or len(dependencies) != len(sources):
        raise SystemExit("Chart.sources.yaml must pin every dependency in Chart.yaml")
    sync_chart_lock(chart_dir, dependencies)

    source_by_name = {source["name"]: source for source in sources}
    if len(source_by_name) != len(sources):
        raise SystemExit("Chart.sources.yaml contains duplicate dependency names")

    checksums: list[str] = []
    with tempfile.TemporaryDirectory(prefix="helm-git-vendor-") as temp:
        temp_dir = Path(temp)

        for dependency in dependencies:
            name = dependency["name"]
            source = source_by_name.get(name)
            if source is None:
                raise SystemExit(f"missing Git source for dependency {name}")

            repository = source["repository"]
            revision = source["revision"]
            chart_path = source["chartPath"]
            expected_version = str(dependency["version"])

            if dependency.get("repository") != f"git+{repository}":
                raise SystemExit(
                    f"Chart.yaml repository for {name} must be git+{repository}"
                )
            if not re.fullmatch(r"[0-9a-f]{40}", revision):
                raise SystemExit(f"{name} must be pinned to a full 40-character commit SHA")
            chart_subpath = PurePosixPath(chart_path)
            if chart_subpath.is_absolute() or ".." in chart_subpath.parts:
                raise SystemExit(f"invalid chartPath for {name}: {chart_path}")

            clone = temp_dir / f"{name}-repo"
            run("git", "init", "--quiet", str(clone))
            run("git", "-C", str(clone), "remote", "add", "origin", repository)
            print(f"Fetching {repository} at {revision}")
            run("git", "-C", str(clone), "fetch", "--quiet", "--depth=1", "origin", revision)
            resolved = run("git", "-C", str(clone), "rev-parse", "FETCH_HEAD^{commit}")
            if resolved != revision:
                raise SystemExit(f"fetched {resolved}, expected {revision} for {name}")

            source_tar = temp_dir / f"{name}-source.tar"
            with source_tar.open("wb") as output:
                run(
                    "git",
                    "-C",
                    str(clone),
                    "archive",
                    "--format=tar",
                    f"--prefix={name}/",
                    f"{resolved}:{chart_path}",
                    stdout=output,
                )

            archive_name = f"{name}-{expected_version}.tgz"
            packaged = temp_dir / archive_name
            run(
                sys.executable,
                str(Path(__file__).with_name("package-git-helm-chart.py")),
                str(source_tar),
                str(packaged),
            )

            with tarfile.open(packaged, mode="r:gz") as bundle:
                chart_yaml = bundle.extractfile(f"{name}/Chart.yaml")
                if chart_yaml is None:
                    raise SystemExit(f"Git source for {name} does not contain Chart.yaml")
                packaged_meta = yaml.safe_load(chart_yaml.read())
            if packaged_meta.get("name") != name or str(packaged_meta.get("version")) != expected_version:
                raise SystemExit(
                    f"Git chart metadata mismatch for {name}: "
                    f"got {packaged_meta.get('name')}@{packaged_meta.get('version')}, "
                    f"expected {name}@{expected_version}"
                )

            archive = chart_dir / "charts" / archive_name
            archive.parent.mkdir(parents=True, exist_ok=True)
            with gzip.open(packaged, "rb") as packaged_tar:
                digest = hashlib.sha256(packaged_tar.read()).hexdigest()

            existing_digest = None
            if archive.exists():
                try:
                    with gzip.open(archive, "rb") as existing_tar:
                        existing_digest = hashlib.sha256(existing_tar.read()).hexdigest()
                except OSError:
                    pass

            if existing_digest == digest:
                print(f"Keeping existing {archive_name}; chart contents are unchanged")
            else:
                staged_archive = archive.with_name(f".{archive.name}.tmp")
                shutil.copyfile(packaged, staged_archive)
                os.replace(staged_archive, archive)

            checksums.append(f"{digest}  charts/{archive_name}")
            print(f"Vendored {name}@{expected_version} (sha256:{digest})")

    checksum_file = chart_dir / "Chart.sources.sha256"
    checksum_file.write_text(
        "# SHA-256 of the normalized uncompressed tar payload (gzip output can vary by toolchain).\n"
        + "\n".join(sorted(checksums))
        + "\n"
    )


if __name__ == "__main__":
    main()
