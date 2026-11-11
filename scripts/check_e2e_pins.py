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
     (single line of history) and sibling pins of the suite must be
     unchanged in the same change.
  P3 pins are full 40-char SHAs (or @sha256:<digest>); short/branch pins
     fail unless the registry entry sets `enforce: false` (warning).

Usage:
  uv run scripts/check_e2e_pins.py [--registry PATH] [--skip-ancestry]
"""

import argparse
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

FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^@?sha256:[0-9a-f]{64}$")
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


def resolve_pin_value(pin: dict[str, Any], env_dir: Path | None) -> Any:
    """P1: resolve a pin the way the deployment does for one env/region."""
    if "ref" in pin:
        return pin["ref"]
    source = pin["source"]
    if "ref" in pin:
        return pin["ref"]
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
    """P3: full SHA / digest. Returns list of error messages (empty = pass)."""
    name = pin["name"]
    if not isinstance(value, str) or not value.strip():
        return [f"{suite}/{name}: pin value is empty or not a string ({value!r})"]
    v = value.strip()
    if FULL_SHA_RE.match(v) or DIGEST_RE.match(v) or SHA_DIGEST_RE.match(v):
        return []
    msg = (
        f"{suite}/{name}: pin {v!r} is not a full 40-char SHA or @sha256:<digest>"
    )
    if enforce:
        return [msg]
    warn(f"{msg} (waived via enforce: false — remove once re-pinned)")
    return []


def git_merge_base_with_default() -> str | None:
    """Base commit to diff against: merge-base with the default branch."""
    default = "origin/main"
    try:
        if run(["git", "rev-parse", "--verify", default], check=False):
            return run(["git", "merge-base", "HEAD", default])
    except Exception:
        pass
    return None


def changed_files(base: str) -> set[str]:
    out = run(["git", "diff", "--name-only", base, "HEAD"])
    return {line for line in out.splitlines() if line}


def pin_changed(pin: dict, changed: set[str]) -> bool:
    source = pin.get("source", {})
    if "ref" in pin:
        return False  # inline refs live in the registry itself; diff not tracked here
    return source.get("file", "") in changed


def is_ancestor(repo_url: str, old: str, new: str, cache: dict[str, Path]) -> bool:
    """P2: is `new` a descendant of `old` in the suite repo's history?"""
    if not (FULL_SHA_RE.match(old) and FULL_SHA_RE.match(new)):
        # Cannot establish ancestry for non-SHA pins (waived or digest pins).
        warn(f"ancestry not checkable for {old[:12]} -> {new[:12]} (non-SHA pin)")
        return True
    if repo_url not in cache:
        tmp = Path(tempfile.mkdtemp(prefix="pin-clone-"))
        run(["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout",
             repo_url, str(tmp)])
        cache[repo_url] = tmp
    repo = cache[repo_url]
    run(["git", "fetch", "--quiet", "origin", old, new], cwd=repo, check=False)
    proc = subprocess.run(
        ["git", "merge-base", "--is-ancestor", old, new], cwd=repo
    )
    return proc.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument(
        "--skip-ancestry",
        action="store_true",
        help="skip the P2 ancestry check (offline / no suite repo access)",
    )
    args = parser.parse_args()

    registry = load_yaml(args.registry)
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
    changed = changed_files(base) if base else set()
    if base is None:
        warn("no origin/main to diff against — P2 change detection skipped")

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

        # P2: bumped pins (value changed vs base) must descend from their
        # previous value, and all other pins of the suite must be unchanged.
        if base is not None:
            bumped = []
            for p in pins:
                if not pin_changed(p, changed):
                    continue
                old_val = previous_pin_value(p, base)
                try:
                    new_val = resolve_config_pin(p, None if "ref" in p else env_dirs[0])
                except (KeyError, FileNotFoundError):
                    bumped.append(p)  # pin is new or unresolvable at HEAD — flag it
                    continue
                if old_val != new_val:
                    bumped.append(p)
            for pin in bumped:
                old = previous_pin_value(pin, base)
                new = resolve_config_pin(pin, None if "ref" in pin else env_dirs[0])
                if old == new:
                    continue  # file touched but pin value unchanged
                if args.skip_ancestry:
                    warn(f"{suite}/{pin['name']}: ancestry check skipped")
                elif not is_ancestor(cfg["repo"], str(old), str(new), clone_cache):
                    errors.append(
                        f"{suite}/{pin['name']}: pin bump {old} -> {new} is not a "
                        f"descendant (diverging history — newest-pin-wins violated)"
                    )
                unchanged = [p["name"] for p in pins if p not in bumped]
                if len(bumped) > 1:
                    errors.append(
                        f"{suite}: multiple pins changed together "
                        f"({', '.join(p['name'] for p in bumped)}); only the "
                        f"newest pin may move per change"
                    )
                elif unchanged:
                    ok(f"{suite}/{pin['name']} bumped; siblings unchanged: "
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


def previous_pin_value(pin: dict, base: str) -> Any:
    """Resolve a pin's value at the base commit."""
    source = pin.get("source", {})
    if "ref" in pin:
        return pin["ref"]
    try:
        content = run(["git", "show", f"{base}:{source['file']}"])
        data = yaml.safe_load(content) or {}
        return dig(data, source["key"])
    except Exception:
        return None


if __name__ == "__main__":
    sys.exit(main())
