#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "PyYAML>=6.0",
#     ]
# ///
"""
check_e2e_pins.py — validate the e2e suite pin registry (ci/e2e-hooks/suite-repos.yaml).

Rules (see the registry header for the full contract):
  P1 pins are resolved like the deployment (rendered merged config +
     ArgoCD env-values layer wins).
  P2 newest-pin-wins: a bumped pin must descend from its previous value
     (single line of history).  Multiple pins of the same suite may
     bump together (they share a repo, so ancestry is per-pin).  Pins
     with an explicit `bump_together: <group>` MUST move together: if
     one member of the group bumps, all members must bump in the same
     change (e.g. zoa's lambda/runner/boundary images, built from one
     commit).
  P3 pins are full 40-char SHAs, optionally followed by
     `@sha256:<digest>` (Konflux form); short/branch pins fail unless
     the registry entry sets `enforce: false` (warning).

Usage:
  uv run scripts/check_e2e_pins.py [--registry PATH] [--skip-ancestry]

--skip-ancestry is the documented offline mode: it skips the P2 ancestry
check AND the P2 change detection (which needs origin/main to diff
against).
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = REPO_ROOT / "ci/e2e-hooks/suite-repos.yaml"
REGISTRY_FILE_REL = "ci/e2e-hooks/suite-repos.yaml"

FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SHA_DIGEST_RE = re.compile(r"^[0-9a-f]{40}@sha256:[0-9a-f]{64}$")


def fail(msg: str) -> None:
    print(f"❌ {msg}")


def warn(msg: str) -> None:
    print(f"⚠️  {msg}")


def ok(msg: str) -> None:
    print(f"✅ {msg}")


def run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> str:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(cmd)}\n{proc.stdout}\n{proc.stderr}"
        )
    return proc.stdout.strip()


class _UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that rejects duplicate mapping keys."""


def _no_dup_keys(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate key {key!r} in mapping", key_node.start_mark
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup_keys
)


def load_registry(path: Path) -> dict[str, Any]:
    """Load the pin registry with a duplicate-key-rejecting loader, so a
    duplicated `suites` key or a later `enforce: false` cannot silently
    shadow earlier entries."""
    with open(path) as f:
        return yaml.load(f, Loader=_UniqueKeyLoader) or {}


def load_yaml(path: Path) -> dict[str, Any]:
    with open(path) as f:
        return yaml.safe_load(f) or {}


def dig(data: Any, dotted_key: str) -> Any:
    """Fetch a nested value by dotted key ('a.b.c')."""
    cur = data
    for part in dotted_key.split("."):
        if not isinstance(cur, dict) or part not in cur:
            raise KeyError(dotted_key)
        cur = cur[part]
    return cur


def merged_overlay(base: dict, overlay: dict) -> dict:
    """Deep-merge overlay onto base; overlay wins."""
    out = dict(base)
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merged_overlay(out[k], v)
        else:
            out[k] = v
    return out


def argocd_env_layers(env_dir: Path) -> list[Path]:
    """deploy/<env>/<region>/argocd-values-*.yaml files that overlay chart values."""
    return sorted(p for p in env_dir.glob("argocd-values-*.yaml") if p.is_file())


def extract_sha(value: str) -> str | None:
    """Extract the 40-char commit SHA, stripping any @sha256:<digest> suffix."""
    sha = value.split("@")[0].strip()
    return sha if FULL_SHA_RE.match(sha) else None


def resolve_pin_value(pin: dict[str, Any], env_dir: Path | None) -> Any:
    """P1: resolve a pin the way the deployment does for one env/region."""
    source = pin["source"]
    if "file" in source:
        base = load_yaml(REPO_ROOT / source["file"])
        value = dig(base, source["key"])
        # ArgoCD values files are overlaid by the env layer (layer wins).
        if env_dir is not None and source["file"].startswith("argocd/"):
            for layer in argocd_env_layers(env_dir):
                overlay = load_yaml(layer)
                try:
                    value = dig(merged_overlay(base, overlay), source["key"])
                except KeyError:
                    pass
        return value
    raise ValueError(f"pin {pin.get('name')} has no usable source")


def resolve_config_pin(pin: dict[str, Any], env_dir: Path | None) -> Any:
    """Resolve a pin: inline refs are env-independent; config pins resolve
    from the rendered merged config (P1)."""
    if "ref" in pin:
        return pin["ref"]
    source = pin["source"]
    if source["file"].startswith("config/"):
        if env_dir is None:
            raise KeyError("config pin requires an env_dir")
        merged = load_yaml(env_dir / "_merged_config.yaml")
        return dig(merged, source["key"])
    return resolve_pin_value(pin, env_dir)


def check_pin_format(value: Any, pin: dict, suite: str, enforce: bool) -> list[str]:
    """P3: full SHA, optionally with @sha256:<digest>. A digest-only value
    is rejected: it cannot identify the suite checkout commit."""
    name = pin["name"]
    if not isinstance(value, str) or not value.strip():
        return [f"{suite}/{name}: pin value is empty or not a string ({value!r})"]
    v = value.strip()
    if FULL_SHA_RE.match(v) or SHA_DIGEST_RE.match(v):
        return []
    msg = (
        f"{suite}/{name}: pin {v!r} is not a full 40-char SHA "
        f"(optionally SHA@sha256:<digest>)"
    )
    if enforce:
        return [msg]
    warn(f"{msg} (waived via enforce: false — remove once re-pinned)")
    return []


def git_merge_base_with_default() -> str | None:
    """Base commit to diff against: merge-base with the default branch.

    In Prow's clonerefs environment, origin/main is not available — the
    PULL_BASE_SHA env var carries the PR's base commit.  When set, use it
    directly (via merge-base so the result is the common ancestor, same
    as the local-dev path).  Fall back to origin/main for local
    development.
    """
    base_sha = os.environ.get("PULL_BASE_SHA")
    if base_sha:
        return run(["git", "merge-base", "HEAD", base_sha])
    for ref in ("origin/main", "main"):
        if run(["git", "rev-parse", "--verify", ref], check=False):
            return run(["git", "merge-base", "HEAD", ref])
    return None


def changed_files(base: str) -> set[str]:
    out = run(["git", "diff", "--name-only", base, "HEAD"])
    return {line for line in out.splitlines() if line}


def pin_changed(pin: dict, changed: set[str]) -> bool:
    """Has anything that feeds this pin changed between base and HEAD?

    For source-file pins: the source file (or, for ArgoCD values, an env
    overlay that can change the effective value). For inline refs: the
    registry file itself, since that is where the value lives.
    """
    if "ref" in pin:
        return REGISTRY_FILE_REL in changed
    source = pin.get("source", {})
    if source.get("file", "").startswith("argocd/"):
        # Any env overlay layer can change the effective value.
        if any(p.startswith("deploy/") and "argocd-values-" in p for p in changed):
            return True
    return source.get("file", "") in changed


def is_ancestor(repo_url: str, old: str, new: str, cache: dict[str, Path]) -> bool:
    """P2: is `new` a descendant of `old` in the suite repo's history?"""
    old_sha, new_sha = extract_sha(old), extract_sha(new)
    if not (old_sha and new_sha):
        # Cannot establish ancestry for non-SHA pins (waived pins).
        warn(f"ancestry not checkable for {old!r} -> {new!r} (non-SHA pin)")
        return True
    if repo_url not in cache:
        tmp = Path(tempfile.mkdtemp(prefix="pin-clone-"))
        run(["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout",
             repo_url, str(tmp)])
        cache[repo_url] = tmp
    repo = cache[repo_url]
    run(["git", "fetch", "--quiet", "origin", old_sha, new_sha], cwd=repo, check=False)
    proc = subprocess.run(
        ["git", "merge-base", "--is-ancestor", old_sha, new_sha], cwd=repo
    )
    return proc.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument(
        "--skip-ancestry",
        action="store_true",
        help="offline mode: skip the P2 ancestry check and change detection "
             "(which need origin/main and suite repo access)",
    )
    args = parser.parse_args()

    try:
        registry = load_registry(args.registry)
    except yaml.YAMLError as exc:
        fail(f"registry has invalid YAML (duplicate keys are rejected): {exc}")
        return 1
    suites: dict[str, Any] = registry.get("suites") or {}
    if not suites:
        fail("registry has no suites")
        return 1

    # Enumerate rendered env/region dirs (P1 resolution targets).
    deploy = REPO_ROOT / "deploy"
    env_dirs: list[Path] = sorted(
        p for p in deploy.glob("*/*") if (p / "_merged_config.yaml").is_file()
    )
    if not env_dirs:
        fail("no rendered deploy/<env>/<region>/_merged_config.yaml found; "
             "run 'uv run scripts/render.py' first")
        return 1

    errors: list[str] = []
    clone_cache: dict[str, Path] = {}

    base = git_merge_base_with_default()
    if base is None and not args.skip_ancestry:
        fail("cannot determine the P2 comparison base: origin/main is not "
             "available. Run 'git fetch origin main', or pass --skip-ancestry "
             "for the documented offline mode.")
        return 1
    if args.skip_ancestry:
        # Offline mode: skip the WHOLE P2 block (change detection AND
        # ancestry), not just the ancestry part — otherwise the group check
        # can produce spurious failures the caller asked to skip.
        base = None
    changed = changed_files(base) if base else set()
    if base is None:
        warn("offline mode — P2 change detection skipped")

    for suite, cfg in sorted(suites.items()):
        pins: list[dict] = cfg.get("pins") or []
        if not pins:
            fail(f"{suite}: no pins registered")
            errors.append(f"{suite}: no pins")
            continue

        # Resolve every pin for every environment (P1). Inline refs are
        # env-independent and resolve once.
        for pin in pins:
            enforce = pin.get("enforce", True)
            targets = [None] if "ref" in pin else env_dirs
            for env_dir in targets:
                label = "inline" if env_dir is None else f"{env_dir.parent.name}/{env_dir.name}"
                try:
                    value = resolve_config_pin(pin, env_dir)
                except (KeyError, FileNotFoundError) as e:
                    errors.append(
                        f"{suite}/{pin['name']}: cannot resolve pin for {label}: {e}"
                    )
                    continue
                errors.extend(
                    check_pin_format(value, pin, f"{suite}[{label}]", enforce)
                )

        # P2: bumped pins must descend from their previous value; sibling
        # pins must be unchanged — except within a bump_together group.
        # The old/new comparison is symmetric (same resolution pipeline at
        # base and HEAD), and ONE bumped environment is enough to flag a
        # pin: record it and stop, so an env that matches the old value
        # cannot silently erase a bump detected earlier.
        if base is None:
            continue
        bumped: dict[str, dict] = {}
        for p in pins:
            if not pin_changed(p, changed):
                continue
            if "ref" in p:
                old_val = previous_pin_value(p, base)
                try:
                    new_val = resolve_config_pin(p, None)
                except (KeyError, FileNotFoundError):
                    new_val = None
                if old_val != new_val:
                    bumped[p["name"]] = {"pin": p, "old": old_val, "new": new_val}
                continue
            if p["source"]["file"].startswith("config/"):
                for env_dir in env_dirs:
                    old_val = previous_pin_value(p, base, env_dir)
                    try:
                        new_val = resolve_config_pin(p, env_dir)
                    except (KeyError, FileNotFoundError):
                        new_val = None
                    if old_val != new_val:
                        bumped[p["name"]] = {"pin": p, "old": old_val, "new": new_val}
                        break  # one bumped env is enough — later envs cannot erase it
            else:
                # ArgoCD pins: raw-to-raw comparison (base file vs HEAD file,
                # no overlay asymmetry); ancestry uses the resolved new value.
                old_val = previous_pin_value(p, base)
                try:
                    new_raw = current_raw_pin_value(p)
                    new_val = resolve_config_pin(p, env_dirs[0])
                except (KeyError, FileNotFoundError, RuntimeError):
                    new_raw, new_val = None, None
                if old_val != new_raw:
                    bumped[p["name"]] = {"pin": p, "old": old_val, "new": new_val}
        if not bumped:
            continue

        # Group check: multiple pins of the SAME suite may bump together —
        # they share a suite repo, so ancestry is checked per pin anyway.
        # Pins with an explicit bump_together group are additionally
        # validated: all bumped pins within a group must move together,
        # i.e. if one member of a group is bumped, all members must be.
        # (The ancestry check below still applies to each pin individually.)
        bump_groups = {p.get("bump_together") for p in
                       (b["pin"] for b in bumped.values())
                       if p.get("bump_together") is not None}
        for grp in bump_groups:
            group_members = [p["name"] for p in pins if p.get("bump_together") == grp]
            bumped_members = [n for n in group_members if n in bumped]
            if len(bumped_members) != len(group_members):
                missing = [n for n in group_members if n not in bumped]
                errors.append(
                    f"{suite}: bump_together group '{grp}' requires all "
                    f"members to move together, but only "
                    f"{', '.join(bumped_members)} changed (missing: "
                    f"{', '.join(missing)})"
                )
                continue

        for name, b in bumped.items():
            old, new = b["old"], b["new"]
            if new is None:
                errors.append(f"{suite}/{name}: pin unresolvable at HEAD")
                continue
            if old is None:
                errors.append(f"{suite}/{name}: new pin added ({new})")
                continue
            if args.skip_ancestry:
                warn(f"{suite}/{name}: ancestry check skipped")
            elif not is_ancestor(cfg["repo"], str(old), str(new), clone_cache):
                errors.append(
                    f"{suite}/{name}: pin bump {old} -> {new} is not a "
                    f"descendant (diverging history — newest-pin-wins violated)"
                )
        unchanged = [p["name"] for p in pins if p["name"] not in bumped]
        if unchanged:
            ok(f"{suite}: bumped {', '.join(bumped)}; unchanged: "
               f"{', '.join(unchanged)}")

    for path in clone_cache.values():
        shutil.rmtree(path, ignore_errors=True)

    if errors:
        print()
        for e in errors:
            fail(e)
        print(f"\n❌ check-e2e-pins failed with {len(errors)} error(s)")
        return 1
    print("\n✅ check-e2e-pins passed")
    return 0


def current_raw_pin_value(pin: dict) -> Any:
    """Resolve a pin's raw source-file value at HEAD (no env overlays) —
    the symmetric counterpart to previous_pin_value for ArgoCD pins."""
    source = pin["source"]
    content = run(["git", "show", f"HEAD:{source['file']}"])
    data = yaml.safe_load(content) or {}
    return dig(data, source["key"])


def previous_pin_value(pin: dict, base: str, env_dir: Path | None = None) -> Any:
    """Resolve a pin's value at the base commit, through the SAME
    resolution pipeline as the new value, so the P2 comparison is symmetric:
    - config/ pins: rendered merged config at base (per env)
    - argocd/ pins: raw values file at base (compared raw-to-raw at HEAD)
    - inline refs: the ref itself
    """
    source = pin.get("source", {})
    if "ref" in pin:
        return pin["ref"]
    try:
        if env_dir is not None and source["file"].startswith("config/"):
            # git resolves paths after BASE: inside the commit tree, so the
            # path must be repository-relative POSIX — env_dir is absolute
            # (derived from REPO_ROOT) and would never match.
            merged_path = env_dir.relative_to(REPO_ROOT).as_posix() \
                + "/_merged_config.yaml"
            content = run(["git", "show", f"{base}:{merged_path}"])
            data = yaml.safe_load(content) or {}
            return dig(data, source["key"])
        content = run(["git", "show", f"{base}:{source['file']}"])
        data = yaml.safe_load(content) or {}
        return dig(data, source["key"])
    except (KeyError, RuntimeError, yaml.YAMLError) as exc:
        warn(f"cannot resolve previous value for {pin.get('name', '?')}: {exc}")
        return None


if __name__ == "__main__":
    sys.exit(main())
