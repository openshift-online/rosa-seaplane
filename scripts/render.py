#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "PyYAML>=6.0",
#     "Jinja2>=3.1",
#     "ruamel.yaml>=0.18",
# ]
# ///
"""
Renders deploy/ output files from config/ values + Jinja2 templates.

Config inheritance: defaults.yaml -> <env>/defaults.yaml -> <env>/<region>.yaml
"""

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any

import yaml
from jinja2 import ChainableUndefined, Environment, Undefined
from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap


# -- Core utilities -----------------------------------------------------------

_ruamel = YAML()
_ruamel.preserve_quotes = True
_ruamel.width = 4096


def load_yaml(path: Path) -> dict[str, Any]:
    """Load a YAML file, returning {} if missing or empty."""
    if not path.exists():
        return {}
    with open(path) as f:
        return yaml.safe_load(f) or {}


def load_yaml_ruamel(path: Path) -> CommentedMap:
    """Load a YAML file with ruamel, preserving comments."""
    if not path.exists():
        return CommentedMap()
    with open(path) as f:
        result = _ruamel.load(f)
        return result if isinstance(result, CommentedMap) else CommentedMap()


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    """Recursively merge two dicts. Overlay wins on conflicts."""
    result = base.copy()
    for key, value in overlay.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def deep_merge_ruamel(base: CommentedMap, overlay: CommentedMap) -> CommentedMap:
    """Recursively merge CommentedMaps, preserving comments from base."""
    result = base.copy()
    for key in overlay:
        if key in result and isinstance(result[key], CommentedMap) and isinstance(overlay[key], CommentedMap):
            result[key] = deep_merge_ruamel(result[key], overlay[key])
        else:
            result[key] = overlay[key]
    return result


_UNDEFINED_SENTINEL = "__UNDEFINED__"
_PURE_VAR_RE = re.compile(r"^\{\{\s*([\w.]+)\s*(?:\|.*)?\}\}$")
_DEFAULT_RE = re.compile(r"\|\s*default\(\s*(.+?)\s*\)")
_MISSING = object()


def _parse_default_type(default_arg: str, context: dict) -> type | None:
    """Determine the Python type of a default() filter argument.

    Handles literals (true/false, numbers, quoted strings) and falls back
    to a context variable lookup.  Returns None when the type cannot be
    determined.
    """
    arg = default_arg.strip()
    if arg in ("true", "false", "True", "False"):
        return bool
    if (arg.startswith('"') and arg.endswith('"')) or (
        arg.startswith("'") and arg.endswith("'")
    ):
        return str
    try:
        int(arg)
        return int
    except ValueError:
        pass
    try:
        float(arg)
        return float
    except ValueError:
        pass
    native = _resolve_var_path(context, arg)
    if native is not _MISSING and isinstance(native, (int, float, bool)):
        return type(native)
    return None


class _StrictChainableUndefined(ChainableUndefined):
    """Undefined that chains attribute access but fails loudly when rendered."""

    def __str__(self) -> str:
        return _UNDEFINED_SENTINEL

    def __iter__(self):
        return iter([])

    def __bool__(self) -> bool:
        return False


def _check_no_undefined(value: Any) -> None:
    if isinstance(value, Undefined):
        raise ValueError(
            f"undefined variable passed to tojson: {value._undefined_name!r}"
            f" — ensure it's defined in config/defaults.yaml"
        )
    if isinstance(value, dict):
        for v in value.values():
            _check_no_undefined(v)
    elif isinstance(value, (list, tuple, set)):
        for item in value:
            _check_no_undefined(item)


def _tojson_strict(value: Any, indent: int | None = None) -> str:
    _check_no_undefined(value)
    return json.dumps(value, sort_keys=True, indent=indent)


def _make_jinja_env() -> "Environment":
    env = Environment(undefined=_StrictChainableUndefined)
    env.filters["tojson"] = _tojson_strict
    return env


def _resolve_var_path(context: dict, path: str) -> Any:
    """Resolve a dotted path (e.g. 'a.b.c') against a context dict."""
    current: Any = context
    for part in path.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
        else:
            return _MISSING
    return current


def resolve_templates(value: Any, context: dict[str, Any]) -> Any:
    """Recursively resolve Jinja2 expressions in config values."""
    if isinstance(value, str):
        native_type = None
        m = _PURE_VAR_RE.match(value)
        if m:
            native = _resolve_var_path(context, m.group(1))
            if native is not _MISSING and isinstance(native, (list, dict)):
                return native
            if native is not _MISSING and native is None:
                # Preserve None values instead of converting to string "None"
                return None
            if native is not _MISSING and isinstance(native, (int, float, bool)):
                native_type = type(native)
            elif native is _MISSING:
                dm = _DEFAULT_RE.search(value)
                if dm:
                    native_type = _parse_default_type(dm.group(1), context)
        rendered = _make_jinja_env().from_string(value).render(context)
        if _UNDEFINED_SENTINEL in rendered:
            raise ValueError(
                f"undefined variable in template: {value!r} rendered to {rendered!r}"
            )
        if native_type is bool:
            return rendered.lower() == "true"
        if native_type is int:
            return int(rendered)
        if native_type is float:
            return float(rendered)
        return rendered
    elif isinstance(value, dict):
        return {k: resolve_templates(v, context) for k, v in value.items()}
    elif isinstance(value, list):
        return [resolve_templates(item, context) for item in value]
    return value


# -- Discovery ----------------------------------------------------------------


def discover_environments(config_dir: Path) -> list[str]:
    """Find environment directories (those with defaults.yaml)."""
    return sorted(
        d.name
        for d in config_dir.iterdir()
        if d.is_dir()
        and not d.name.startswith(".")
        and d.name != "templates"
        and (d / "defaults.yaml").exists()
    )


def discover_regions(env_dir: Path) -> list[str]:
    """Find region files in an environment directory."""
    return sorted(f.stem for f in env_dir.glob("*.yaml") if f.name != "defaults.yaml")


# -- Rendering ----------------------------------------------------------------


def render_template(template_path: Path, context: dict[str, Any]) -> str:
    """Render a Jinja2 template file with context."""
    env = _make_jinja_env()
    env.filters["toyaml"] = _toyaml
    rendered = env.from_string(template_path.read_text()).render(context)
    if _UNDEFINED_SENTINEL in rendered:
        raise ValueError(
            f"undefined variable in template {template_path}: "
            f"rendered output contains unresolved references"
        )
    return rendered


def _toyaml(value: Any) -> str:
    if not value:
        return "{}"
    return yaml.dump(
        value, default_flow_style=False, sort_keys=False, width=float("inf")
    ).rstrip()


def write_output(content: str, path: Path) -> None:
    """Write content to a file, ensuring trailing newline."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content if content.endswith("\n") else content + "\n")


def render_file(templates_dir: Path, template_rel: str, context: dict[str, Any], output_path: Path) -> bool:
    """Render a template to an output file. Returns True if the template exists."""
    tpl = templates_dir / f"{template_rel}.j2"
    if not tpl.exists():
        return False
    write_output(render_template(tpl, context), output_path)
    print(f"  [OK] {output_path}")
    return True


# -- Cleanup ------------------------------------------------------------------


def cleanup_stale_files(
    valid_envs: set[str],
    env_regions: dict[str, set[str]],
    env_region_mcs: dict[str, dict[str, set[str]]],
    deploy_dir: Path,
) -> None:
    """Remove stale environment/region/MC directories from deploy/."""
    if not deploy_dir.exists():
        return

    for env_dir in deploy_dir.iterdir():
        if not env_dir.is_dir() or env_dir.name.startswith("."):
            continue
        if env_dir.name not in valid_envs:
            print(f"  [CLEANUP] Removing stale environment: deploy/{env_dir.name}/")
            shutil.rmtree(env_dir)
            continue

        for region_dir in env_dir.iterdir():
            if not region_dir.is_dir() or region_dir.name.startswith("."):
                continue
            if region_dir.name not in env_regions.get(env_dir.name, set()):
                print(f"  [CLEANUP] Removing stale region: deploy/{env_dir.name}/{region_dir.name}/")
                shutil.rmtree(region_dir)
                continue

            valid_mcs = env_region_mcs.get(env_dir.name, {}).get(region_dir.name, set())
            valid_input_dirs = {
                "pipeline-provisioner-inputs",
                "pipeline-regional-cluster-inputs",
                *(f"pipeline-management-cluster-{mc}-inputs" for mc in valid_mcs),
            }
            for item in region_dir.iterdir():
                if item.is_dir() and item.name.endswith("-inputs") and item.name not in valid_input_dirs:
                    print(f"  [CLEANUP] Removing stale generated input dir: {item}")
                    shutil.rmtree(item)

            prov_dir = region_dir / "pipeline-provisioner-inputs"
            if prov_dir.exists():
                for mc_file in prov_dir.glob("management-cluster-*.json"):
                    mc_name = mc_file.stem.removeprefix("management-cluster-")
                    if mc_name not in valid_mcs:
                        print(f"  [CLEANUP] Removing stale MC file: {mc_file}")
                        mc_file.unlink()


# -- Context building ---------------------------------------------------------


def _format_cluster_id(pattern: str, prefix: str, mc_key: str = "") -> str:
    """Format a cluster ID without leading separators for shared environments."""
    cluster_id = pattern.format(prefix=prefix, mc_key=mc_key).strip("-")
    if not cluster_id:
        raise ValueError(f"cluster naming pattern produced an empty ID: {pattern!r}")
    return cluster_id


def validate_cluster_topology(
    merged: dict[str, Any], ctx: dict[str, Any], mc_list: list[dict],
    env_name: str, region: str,
) -> None:
    """Validate rendered RC/MC identities and their required account hand-off."""
    provision_mcs = merged.get("provision_mcs", {})
    if not isinstance(provision_mcs, dict):
        raise ValueError(
            f"{env_name}/{region}: provision_mcs must be a mapping of MC keys to config"
        )

    errors = []
    regional_id = str(ctx.get("regional_id", ""))
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", regional_id):
        errors.append(f"regional_id={regional_id!r} is not a lowercase cluster ID")

    seen_ids = {regional_id: "RC"}
    for mc_key, mc in zip(provision_mcs, mc_list, strict=True):
        management_id = str(mc.get("management_id", ""))
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", management_id):
            errors.append(
                f"MC {mc_key!r} management_id={management_id!r} is not a lowercase cluster ID"
            )
        elif management_id in seen_ids:
            errors.append(
                f"cluster ID {management_id!r} is used by both "
                f"{seen_ids[management_id]} and MC {mc_key!r}"
            )
        else:
            seen_ids[management_id] = f"MC {mc_key}"

        if mc.get("account_id") in (None, ""):
            errors.append(
                f"MC {mc_key!r} has no account_id and no "
                "aws.management_cluster_account_id default"
            )

    if errors:
        raise ValueError(
            f"Invalid RC/MC topology for {env_name}/{region}: " + "; ".join(errors)
        )


def build_context(
    merged: dict[str, Any], env_name: str, region: str, eph_prefix: str,
) -> dict[str, Any]:
    """Build the template context from merged config values."""
    ctx = dict(merged)
    # ci: true when rendering an ephemeral environment during CI provisioning
    # (both EPH_PREFIX and BUILD_ID set). Ephemeral environments are templates
    # instantiated into shared account pools — CI pools use a different DNS
    # domain (ci00) than developer pools (dev0). Requires both flags so that
    # CI lint/render checks (BUILD_ID set, no EPH_PREFIX) produce the same
    # output as local renders, avoiding spurious diffs.
    ci = env_name == "ephemeral" and bool(eph_prefix) and bool(os.environ.get("BUILD_ID"))
    ctx.update(environment=env_name, aws_region=region, eph_prefix=eph_prefix, ci=ci)

    # deployment_name is an explicit config field (default: "{{ aws_region }}").
    # Resolve it after aws_region is in context so templates can reference it.
    ctx["deployment_name"] = resolve_templates(
        ctx.get("deployment_name", region), ctx
    )

    # Resolve templated config values that other templates depend on
    aws = ctx.get("aws", {})
    ctx["account_id"] = resolve_templates(aws.get("account_id", ""), ctx)
    ctx["child_admin_role_name"] = resolve_templates(
        aws.get("child_admin_role_name", "OrganizationAccountAccessRole"), ctx
    )
    ctx["zoa_access_trusted_assumer_role_names"] = aws.get(
        "zoa_access_trusted_assumer_role_names", []
    )
    ctx["zoa_access_trusted_assumer_role_name_suffixes"] = aws.get(
        "zoa_access_trusted_assumer_role_name_suffixes", []
    )
    ctx["terraform_tags"] = resolve_templates(ctx.get("terraform_tags", {}), ctx)
    ctx["regional_cluster"] = resolve_templates(ctx.get("regional_cluster", {}), ctx)
    ctx["management_cluster_defaults"] = resolve_templates(ctx.get("management_cluster_defaults", {}), ctx)
    ctx["dns"] = resolve_templates(ctx.get("dns", {}), ctx)

    # Compute regional_id using configurable naming pattern
    cluster_naming = ctx.get("cluster_naming", {})
    rc_pattern = cluster_naming.get("rc_pattern", "{prefix}-regional")
    ctx["regional_id"] = _format_cluster_id(rc_pattern, eph_prefix)

    if ctx["regional_cluster"].get("enable_write_sre_tools") and env_name != "ephemeral":
        raise ValueError(
            f"regional_cluster.enable_write_sre_tools can only be true for ephemeral "
            f"environments, got environment '{env_name}'"
        )

    return ctx


def build_mc_list(
    ctx: dict[str, Any], merged: dict[str, Any], eph_prefix: str
) -> list[dict]:
    """Build management cluster entries with resolved template values."""
    mc_dict = merged.get("provision_mcs", {})
    default_mc_account = merged.get("aws", {}).get("management_cluster_account_id")
    mc_list = []

    # Get MC naming pattern from config
    cluster_naming = merged.get("cluster_naming", {})
    mc_pattern = cluster_naming.get("mc_pattern", "{prefix}-{mc_key}")

    if not isinstance(mc_dict, dict):
        raise ValueError("provision_mcs must be a mapping of MC keys to config")

    for mc_key, mc_val in mc_dict.items():
        if mc_val is not None and not isinstance(mc_val, dict):
            raise ValueError(f"MC {mc_key!r} must use a mapping value or {{}}")
        mc = dict(mc_val) if mc_val else {}
        # Compute management_id using configurable naming pattern
        mc["management_id"] = _format_cluster_id(mc_pattern, eph_prefix, mc_key)
        if "account_id" not in mc and default_mc_account:
            mc["account_id"] = default_mc_account
        mc = resolve_templates(mc, {**ctx, "cluster_prefix": mc_key})
        mc_list.append(mc)

    return mc_list


# -- Documentation ------------------------------------------------------------

# Variables injected by render.py, not from config files.
# Note: Go template keywords (if/else/end) that appear in escaped Go template strings
# (e.g., {{ '{{ if ... }}X{{ else }}Y{{ end }}' }}) are automatically filtered by
# scan_template_variables() and do not need to be listed here.
CONTEXT_VARS = {
    "environment", "aws_region",
    "account_id",
    "child_admin_role_name",
    "zoa_access_trusted_assumer_role_names",
    "zoa_access_trusted_assumer_role_name_suffixes",
    "management_clusters",
    "cluster_type",
    "application_values", "region_configs", "eph_prefix",
    "mc_key", "region",
    "pinned", "mc_account_ids", "ci",
}

_DOC_RE = re.compile(r"^\s*#\s*(?:#\s*)?@doc\s+(\S+)\s+(.+)$", re.MULTILINE)
_USED_BY_RE = re.compile(r"^\s*#\s*(?:#\s*)?@used-by\s+(\S+)\s+(.+)$", re.MULTILINE)

# Jinja2 variable patterns: {{ var.path }} and {% if var.path %}
# The first pattern excludes bracket-string access (e.g. var['key']) to avoid
# capturing the bare root variable; those are handled by _TPL_BRACKET_PATTERN.
_TPL_PATTERNS = [
    re.compile(r"\{\{[\s-]*([a-zA-Z_][\w.]*?)(?:\s*(?:[|}]|\[(?!')))"),
    re.compile(r"\{%[\s-]*(?:if|elif)\s+([a-zA-Z_][\w.]*?)[\s%]"),
]
# Matches bracket-string access: {{ var['key'].rest }} → var.key.rest
_TPL_BRACKET_PATTERN = re.compile(r"\{\{[\s-]*([a-zA-Z_]\w*)\['([^']+)'\]([\w.]*)")
# Matches escaped Go template strings wrapped in single or double quotes:
#   {{ '{{ ... }}' }},  {{ "{{ ... }}" }},  {% '{{ ... }}' %},  {% "{{ ... }}" %}
# These contain Go template keywords (if/else/end) that should not be treated as Jinja2 variables.
_ESCAPED_GO_TEMPLATE_RE = re.compile(
    r"""\{\{[\s-]*(?:'[^']*\{\{[^}]*\}\}[^']*'|"[^"]*\{\{[^}]*\}\}[^"]*")[\s-]*\}\}"""
    r"""|\{%[\s-]*(?:'[^']*\{\{[^}]*\}\}[^']*'|"[^"]*\{\{[^}]*\}\}[^"]*")[\s-]*%\}"""
)


def scan_annotations(content: str) -> dict[str, dict[str, Any]]:
    """Parse @doc and @used-by annotations. Returns {key: {doc, used_by}}."""
    result: dict[str, dict[str, Any]] = {}
    for match in _DOC_RE.finditer(content):
        key, desc = match.group(1), match.group(2).strip()
        result[key] = {"doc": desc, "used_by": []}
    for match in _USED_BY_RE.finditer(content):
        key, consumer = match.group(1), match.group(2).strip()
        if key not in result:
            result[key] = {"doc": "", "used_by": []}
        result[key]["used_by"].append(consumer)
    return result


def _is_inside_escaped_go_template(pos: int, skip_ranges: list[tuple[int, int]]) -> bool:
    """Check if a position falls inside an escaped Go template string."""
    return any(start <= pos < end for start, end in skip_ranges)


def scan_template_variables(templates_dir: Path) -> dict[str, list[str]]:
    """Scan templates for variable references. Returns {var: [template_paths]}.

    Variables inside escaped Go template strings (e.g., {{ '{{ if ... }}X{{ else }}Y{{ end }}' }})
    are filtered out, as they are Go template keywords, not Jinja2 variables.
    """
    var_to_templates: dict[str, list[str]] = {}
    for tpl in sorted(templates_dir.rglob("*.j2")):
        rel = str(tpl.relative_to(templates_dir))
        content = tpl.read_text()

        # Build a set of character ranges to skip (escaped Go template strings)
        skip_ranges: list[tuple[int, int]] = []
        for match in _ESCAPED_GO_TEMPLATE_RE.finditer(content):
            skip_ranges.append((match.start(), match.end()))

        for pattern in _TPL_PATTERNS:
            for match in pattern.finditer(content):
                # Skip variables inside escaped Go template strings
                if _is_inside_escaped_go_template(match.start(), skip_ranges):
                    continue
                var = match.group(1)
                if var.startswith("_") or var.split(".")[0] in ("true", "false", "none", "loop"):
                    continue
                if var not in var_to_templates:
                    var_to_templates[var] = []
                if rel not in var_to_templates[var]:
                    var_to_templates[var].append(rel)
        for match in _TPL_BRACKET_PATTERN.finditer(content):
            # Skip variables inside escaped Go template strings
            if _is_inside_escaped_go_template(match.start(), skip_ranges):
                continue
            var = match.group(1) + "." + match.group(2) + match.group(3)
            if var.startswith("_"):
                continue
            if var not in var_to_templates:
                var_to_templates[var] = []
            if rel not in var_to_templates[var]:
                var_to_templates[var].append(rel)
    return var_to_templates


def collect_leaf_paths(data: dict[str, Any], prefix: str = "") -> set[str]:
    """Collect dot-separated paths to all leaf (non-dict) values."""
    paths: set[str] = set()
    for key, value in data.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict) and value:
            paths.update(collect_leaf_paths(value, path))
        else:
            paths.add(path)
    return paths


def _is_covered(key_path: str, annotations: dict[str, dict[str, Any]]) -> bool:
    """Check if a key path is covered by a @doc annotation (direct or ancestor)."""
    parts = key_path.split(".")
    for i in range(len(parts)):
        if ".".join(parts[: i + 1]) in annotations:
            return True
    return False


def check_docs(config_dir: Path, templates_dir: Path) -> int:
    """Validate @doc/@used-by annotations against templates and config."""
    defaults_path = config_dir / "defaults.yaml"
    if not defaults_path.exists():
        print("Error: defaults.yaml not found", file=sys.stderr)
        return 1

    content = defaults_path.read_text()
    defaults = load_yaml(defaults_path)
    annotations = scan_annotations(content)
    template_vars = scan_template_variables(templates_dir)
    leaf_paths = collect_leaf_paths(defaults)
    errors: list[str] = []

    # 1. Every leaf in defaults.yaml must be covered by a @doc
    for leaf in sorted(leaf_paths):
        if not _is_covered(leaf, annotations):
            errors.append(f"Undocumented config key: {leaf}")

    # 2. Every @doc must have at least one @used-by
    for key, info in sorted(annotations.items()):
        if not info["used_by"]:
            errors.append(f"Missing @used-by for: @doc {key}")

    # 3. Non-_context @used-by must point to existing templates that reference the key
    for key, info in sorted(annotations.items()):
        for consumer in info["used_by"]:
            if consumer == "_context":
                continue
            if not (templates_dir / consumer).exists():
                errors.append(f"@used-by {key}: template not found: {consumer}")
                continue
            # Verify the template actually references this key or a child of it
            referenced = False
            for var in template_vars:
                if (var == key or var.startswith(key + ".")) and consumer in template_vars[var]:
                    referenced = True
                    break
            if not referenced:
                errors.append(f"@used-by {key}: not actually referenced in {consumer}")

    # 4. Every template referencing a documented key must appear in its @used-by
    for var, consumers in sorted(template_vars.items()):
        root = var.split(".")[0]
        if root in CONTEXT_VARS:
            continue
        # Find the annotation that covers this variable
        for key, info in annotations.items():
            if var == key or var.startswith(key + "."):
                for consumer in consumers:
                    if consumer not in info["used_by"]:
                        errors.append(
                            f"Missing @used-by {key} {consumer} "
                            f"(template references {var})"
                        )

    # 5. Leaf values under non-_context docs must be used by at least one template
    for key, info in sorted(annotations.items()):
        if "_context" in info["used_by"]:
            continue
        key_leaves = [lp for lp in leaf_paths if lp == key or lp.startswith(key + ".")]
        for leaf in sorted(key_leaves):
            found = any(var == leaf or var.startswith(leaf + ".") for var in template_vars)
            if not found:
                errors.append(f"Unused config key: {leaf} (not referenced by any template)")

    # 6. Every template variable must be covered by a @doc or be a context var
    for var in sorted(template_vars):
        root = var.split(".")[0]
        if root in CONTEXT_VARS:
            continue
        if not _is_covered(var, annotations):
            templates = ", ".join(template_vars[var])
            errors.append(f"Undocumented template variable: {var} (in {templates})")

    if errors:
        print("Documentation check failed:\n")
        for err in errors:
            print(f"  - {err}")
        print(f"\nRun 'uv run scripts/render.py --update-docs' to regenerate @used-by lines.")
        return 1

    print("Documentation check passed")
    return 0


def update_docs(config_dir: Path, templates_dir: Path) -> int:
    """Regenerate @used-by lines based on template scanning. Preserves _context entries."""
    defaults_path = config_dir / "defaults.yaml"
    if not defaults_path.exists():
        print("Error: defaults.yaml not found", file=sys.stderr)
        return 1

    content = defaults_path.read_text()
    annotations = scan_annotations(content)
    template_vars = scan_template_variables(templates_dir)

    # Build actual consumers for each documented key
    key_consumers: dict[str, list[str]] = {}
    for key in annotations:
        consumers: set[str] = set()
        for var, templates in template_vars.items():
            if var == key or var.startswith(key + "."):
                consumers.update(templates)
        key_consumers[key] = sorted(consumers)

    # Rebuild file: keep @doc lines, regenerate @used-by lines
    lines = content.splitlines()
    new_lines: list[str] = []

    for line in lines:
        stripped = line.strip()

        # Skip existing @used-by lines (will be regenerated after @doc)
        if _USED_BY_RE.match(stripped):
            continue

        new_lines.append(line)

        # After a @doc line, insert @used-by lines
        doc_match = _DOC_RE.match(stripped)
        if doc_match:
            key = doc_match.group(1)
            # Extract the prefix (indent + comment chars) from the @doc line so
            # that @used-by lines are aligned identically, even inside commented
            # YAML blocks where lines begin with "# " rather than whitespace.
            prefix_match = re.match(r"(.*#\s*)@doc\s", line)
            prefix = prefix_match.group(1) if prefix_match else "  # "
            if key in annotations and "_context" in annotations[key]["used_by"]:
                new_lines.append(f"{prefix}@used-by {key} _context")
            for consumer in key_consumers.get(key, []):
                new_lines.append(f"{prefix}@used-by {key} {consumer}")

    new_content = "\n".join(new_lines)
    if not new_content.endswith("\n"):
        new_content += "\n"
    defaults_path.write_text(new_content)
    print(f"Updated @used-by annotations in {defaults_path}")
    return 0


# -- Main ---------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Render deploy/ directory from config/ values and templates"
    )
    parser.add_argument(
        "--eph-prefix", default=os.environ.get("EPH_PREFIX", ""),
        help="Optional prefix for resource names in CI/test environments",
    )
    parser.add_argument("--config-dir", default=None, help="Path to config directory")
    parser.add_argument(
        "--check-docs", action="store_true",
        help="Validate @doc/@used-by annotations in defaults.yaml",
    )
    parser.add_argument(
        "--update-docs", action="store_true",
        help="Regenerate @used-by lines from template scanning",
    )
    args = parser.parse_args()
    eph_prefix = args.eph_prefix

    project_root = Path(__file__).parent.parent
    config_dir = Path(args.config_dir) if args.config_dir else project_root / "config"
    templates_dir = config_dir / "templates"

    if args.check_docs:
        return check_docs(config_dir, templates_dir)

    if args.update_docs:
        return update_docs(config_dir, templates_dir)

    deploy_dir = project_root / "deploy"
    argocd_config_dir = project_root / "argocd" / "config"

    if not config_dir.exists():
        print(f"Error: Config directory not found: {config_dir}", file=sys.stderr)
        return 1

    environments = discover_environments(config_dir)
    if not environments:
        print("Error: No environments found in config/", file=sys.stderr)
        return 1

    cluster_types = sorted(
        d.name for d in argocd_config_dir.iterdir()
        if d.is_dir() and not d.name.startswith(".") and d.name.endswith("cluster")
    )
    global_defaults = load_yaml(config_dir / "defaults.yaml")
    global_defaults_ruamel = load_yaml_ruamel(config_dir / "defaults.yaml")

    if eph_prefix:
        print(f"Ephemeral prefix: {eph_prefix}")
    print(f"Environments: {', '.join(environments)}")
    print(f"Cluster types: {', '.join(cluster_types)}")
    print()

    # Track valid paths for cleanup
    valid_envs = set(environments)
    env_regions: dict[str, set[str]] = {}
    env_region_mcs: dict[str, dict[str, set[str]]] = {}

    for env_name in environments:
        env_dir = config_dir / env_name
        env_defaults = load_yaml(env_dir / "defaults.yaml")
        env_defaults_ruamel = load_yaml_ruamel(env_dir / "defaults.yaml")
        regions = discover_regions(env_dir)
        if not regions:
            continue

        print(f"Processing: {env_name}")
        env_regions[env_name] = set(regions)
        env_region_mcs[env_name] = {}

        # -- Stage 1: Merge config hierarchy → _merged_config.yaml --------
        region_configs = {}
        region_configs_ruamel = {}
        for region in regions:
            region_yaml = load_yaml(env_dir / f"{region}.yaml")
            region_configs[region] = deep_merge(deep_merge(global_defaults, env_defaults), region_yaml)
            region_yaml_ruamel = load_yaml_ruamel(env_dir / f"{region}.yaml")
            region_configs_ruamel[region] = deep_merge_ruamel(
                deep_merge_ruamel(global_defaults_ruamel, env_defaults_ruamel), region_yaml_ruamel
            )

            out_dir = deploy_dir / env_name / region
            config_output = out_dir / "_merged_config.yaml"
            config_output.parent.mkdir(parents=True, exist_ok=True)
            with open(config_output, "w") as f:
                f.write(f"# Merged config: defaults.yaml → {env_name}/defaults.yaml → {env_name}/{region}.yaml\n")
                f.write("# This file is the output of stage 1 (merge). Stage 2 feeds it to config/templates/.\n")
                f.write("\n")
                _ruamel.dump(region_configs_ruamel[region], f)
            print(f"  [OK] {config_output}")

        # Region definitions (env-level) — constructed by template
        render_file(templates_dir, "region-definitions.json",
                    {"region_configs": region_configs, "environment": env_name, "eph_prefix": eph_prefix},
                    deploy_dir / env_name / "region-definitions.json")

        # -- Stage 2: Feed merged config to templates → output files ----
        for region in regions:
            merged = region_configs[region]
            ctx = build_context(merged, env_name, region, eph_prefix)
            mc_list = build_mc_list(ctx, merged, eph_prefix)
            validate_cluster_topology(merged, ctx, mc_list, env_name, region)
            ctx["management_clusters"] = mc_list
            env_region_mcs[env_name][region] = {mc["management_id"] for mc in mc_list}

            out_dir = deploy_dir / env_name / region

            # 1:1 templates
            render_file(templates_dir, "pipeline-provisioner-inputs/terraform.json", ctx, out_dir / "pipeline-provisioner-inputs" / "terraform.json")
            render_file(templates_dir, "pipeline-provisioner-inputs/regional-cluster.json", ctx, out_dir / "pipeline-provisioner-inputs" / "regional-cluster.json")
            render_file(templates_dir, "pipeline-regional-cluster-inputs/terraform.json", ctx, out_dir / "pipeline-regional-cluster-inputs" / "terraform.json")
            render_file(templates_dir, "pipeline-regional-cluster-inputs/static.tfvars.json", ctx, out_dir / "pipeline-regional-cluster-inputs" / "static.tfvars.json")

            # Per-cluster-type: ArgoCD values + bootstrap
            app_config = resolve_templates(ctx.get("applications", {}), ctx)

            for ct in cluster_types:
                ct_ctx = {**ctx, "cluster_type": ct, "application_values": app_config.get(ct, {})}
                render_file(templates_dir, "argocd-values.yaml", ct_ctx, out_dir / f"argocd-values-{ct}.yaml")
                render_file(templates_dir, "argocd-bootstrap/applicationset.yaml", ct_ctx, out_dir / f"argocd-bootstrap-{ct}" / "applicationset.yaml")

            # Per-MC templates
            for mc in mc_list:
                mc_ctx = {**ctx, "mc": mc}
                mc_id = mc["management_id"]
                render_file(templates_dir, "pipeline-provisioner-inputs/management-cluster.json", mc_ctx, out_dir / "pipeline-provisioner-inputs" / f"management-cluster-{mc_id}.json")
                render_file(templates_dir, "pipeline-management-cluster-inputs/terraform.json", mc_ctx, out_dir / f"pipeline-management-cluster-{mc_id}-inputs" / "terraform.json")
                render_file(templates_dir, "pipeline-management-cluster-inputs/static.tfvars.json", mc_ctx, out_dir / f"pipeline-management-cluster-{mc_id}-inputs" / "static.tfvars.json")

        print()

    cleanup_stale_files(valid_envs, env_regions, env_region_mcs, deploy_dir)
    print("[OK] Rendering complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
