#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "PyYAML>=6.0",
#     "Jinja2>=3.1",
#     "pytest>=8.0",
#     "ruamel.yaml>=0.18",
# ]
# ///
"""Unit tests for render.py"""

import copy
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

from render import (
    _make_jinja_env,
    build_context,
    build_mc_list,
    check_docs,
    cleanup_stale_files,
    collect_leaf_paths,
    deep_merge,
    discover_environments,
    discover_regions,
    load_yaml,
    main,
    resolve_templates,
    scan_annotations,
    scan_template_variables,
    update_docs,
    validate_cluster_topology,
    write_output,
)

# Path to real templates and argocd config for integration-style tests
PROJECT_ROOT = Path(__file__).parent.parent
REAL_TEMPLATES_DIR = PROJECT_ROOT / "config" / "templates"
REAL_ARGOCD_CONFIG_DIR = PROJECT_ROOT / "argocd" / "config"


# Prow sets BUILD_ID, which build_context reads as CI mode. Tests opt in explicitly.
@pytest.fixture(autouse=True)
def _no_ci_build_id(monkeypatch):
    monkeypatch.delenv("BUILD_ID", raising=False)


def _create_config_structure(
    tmp_path,
    global_defaults=None,
    environments=None,
):
    """Helper to create the new config directory structure.

    environments is a dict like:
        {
            "staging": {
                "defaults": { ... },      # config/<env>/defaults.yaml content
                "regions": {
                    "us-east-1": { ... },  # config/<env>/us-east-1.yaml content
                }
            }
        }
    """
    config_dir = tmp_path / "config"
    config_dir.mkdir(exist_ok=True)

    # Start with base required fields (mirrors real config/defaults.yaml)
    base_defaults = {
        "platform_image": "example.invalid/platform:test",
        "aws": {
            "account_id": "",
            "management_cluster_account_id": "000000000000",
        },
        "dns": {
            "domain": "",
        },
        "terraform_tags": {
            "app_code": "infra",
            "service_phase": "dev",
            "cost_center": "000",
        },
        "regional_cluster": {
            "enable_bastion": False,
            "node_instance_families": ["m8i", "m7i"],
            "zoa_lambda_image_tag": "dd76a96",
            "zoa_runner_image_tag": "dd76a96",
            "zoa_boundary_image_tag": "dd76a96",
            "zoa_lambda_source_image": "quay.io/rrp-dev-ci/zoa-lambda",
            "zoa_runner_source_image": "quay.io/rrp-dev-ci/zoa-runner",
            "zoa_boundary_source_image": "quay.io/rrp-dev-ci/zoa-boundary",
            "zoa_boundary_session_idle_timeout_seconds": 3600,
            "zoa_boundary_session_stale_creating_seconds": 900,
            "zoa_boundary_session_max_duration_hours": 4,
            "zoa_lambda_api_concurrency": 50,
            "zoa_lambda_worker_concurrency": 10,
            "zoa_lambda_access_concurrency": 10,
        },
        "management_cluster_defaults": {
            "enable_bastion": False,
            "node_instance_families": ["m8i", "m7i"],
        },
        "observability": {
            "pagerduty": {
                "enabled": False,
                "escalation_policy_id": "",
            },
        },
        "applications": {
            "regional-cluster": {
                "maestro": {
                    "iotLogLevel": "WARN",
                },
            },
        },
    }

    # Merge test-provided defaults on top
    if global_defaults:
        final_defaults = deep_merge(base_defaults, global_defaults)
    else:
        final_defaults = base_defaults

    # Global defaults (always create)
    (config_dir / "defaults.yaml").write_text(yaml.dump(final_defaults))

    # Copy real templates
    templates_dest = config_dir / "templates"
    if REAL_TEMPLATES_DIR.exists():
        shutil.copytree(REAL_TEMPLATES_DIR, templates_dest, dirs_exist_ok=True)

    # Environment configs
    if environments:
        for env_name, env_data in environments.items():
            env_dir = config_dir / env_name
            env_dir.mkdir(exist_ok=True)

            env_defaults = env_data.get("defaults", {})
            (env_dir / "defaults.yaml").write_text(yaml.dump(env_defaults))

            for region_name, region_config in env_data.get("regions", {}).items():
                (env_dir / f"{region_name}.yaml").write_text(
                    yaml.dump(region_config)
                )

    return config_dir


def _create_argocd_config(tmp_path, cluster_types=None):
    """Helper to create argocd/config directory with cluster type dirs."""
    if cluster_types is None:
        cluster_types = ["regional-cluster", "management-cluster"]

    argocd_config_dir = tmp_path / "argocd" / "config"
    argocd_config_dir.mkdir(parents=True, exist_ok=True)

    for ct in cluster_types:
        (argocd_config_dir / ct).mkdir(exist_ok=True)

    # Copy base applicationset from real project
    appset_src = REAL_ARGOCD_CONFIG_DIR / "applicationset"
    appset_dest = argocd_config_dir / "applicationset"
    if appset_src.exists():
        shutil.copytree(appset_src, appset_dest, dirs_exist_ok=True)
    else:
        # Create a minimal base applicationset
        appset_dest.mkdir(exist_ok=True)
        _write_base_applicationset(appset_dest)

    return argocd_config_dir


def _write_base_applicationset(appset_dir):
    """Write a minimal base-applicationset.yaml for testing."""
    appset = {
        "spec": {
            "generators": [
                {
                    "matrix": {
                        "generators": [
                            {"clusters": {}},
                            {"git": {"revision": "HEAD"}},
                        ]
                    }
                }
            ],
            "template": {
                "spec": {
                    "sources": [
                        {"targetRevision": "HEAD", "path": "chart"},
                        {"targetRevision": "HEAD", "ref": "values"},
                    ]
                }
            },
        }
    }
    with open(appset_dir / "base-applicationset.yaml", "w") as f:
        yaml.dump(appset, f)


# =============================================================================
# load_yaml
# =============================================================================


class TestLoadYaml:
    def test_returns_parsed_content(self, tmp_path):
        f = tmp_path / "test.yaml"
        f.write_text("key: value\nnested:\n  a: 1\n")
        assert load_yaml(f) == {"key": "value", "nested": {"a": 1}}

    def test_returns_empty_dict_for_missing_file(self, tmp_path):
        assert load_yaml(tmp_path / "nonexistent.yaml") == {}

    def test_returns_empty_dict_for_empty_file(self, tmp_path):
        f = tmp_path / "empty.yaml"
        f.write_text("")
        assert load_yaml(f) == {}

    def test_returns_empty_dict_for_null_content(self, tmp_path):
        f = tmp_path / "null.yaml"
        f.write_text("---\n")
        assert load_yaml(f) == {}


# =============================================================================
# discover_environments
# =============================================================================


class TestDiscoverEnvironments:
    def test_finds_environments_with_defaults_yaml(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        staging = config_dir / "staging"
        staging.mkdir()
        (staging / "defaults.yaml").write_text("revision: main\n")
        prod = config_dir / "prod"
        prod.mkdir()
        (prod / "defaults.yaml").write_text("revision: main\n")

        result = discover_environments(config_dir)
        assert sorted(result) == ["prod", "staging"]

    def test_excludes_dirs_without_defaults_yaml(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        staging = config_dir / "staging"
        staging.mkdir()
        (staging / "defaults.yaml").write_text("revision: main\n")
        # This dir has no defaults.yaml, should be excluded
        (config_dir / "incomplete").mkdir()

        result = discover_environments(config_dir)
        assert result == ["staging"]

    def test_excludes_templates_directory(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        templates = config_dir / "templates"
        templates.mkdir()
        (templates / "defaults.yaml").write_text("something\n")

        result = discover_environments(config_dir)
        assert result == []

    def test_excludes_hidden_directories(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        hidden = config_dir / ".hidden"
        hidden.mkdir()
        (hidden / "defaults.yaml").write_text("revision: main\n")

        result = discover_environments(config_dir)
        assert result == []

    def test_returns_sorted(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        for name in ["zebra", "alpha", "middle"]:
            d = config_dir / name
            d.mkdir()
            (d / "defaults.yaml").write_text("{}\n")

        result = discover_environments(config_dir)
        assert result == ["alpha", "middle", "zebra"]

    def test_returns_empty_for_no_environments(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        result = discover_environments(config_dir)
        assert result == []


# =============================================================================
# discover_regions
# =============================================================================


class TestDiscoverRegions:
    def test_finds_region_yaml_files(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")
        (env_dir / "us-west-2.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert sorted(result) == ["us-east-1", "us-west-2"]

    def test_excludes_defaults_yaml(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert result == ["us-east-1"]

    def test_returns_empty_for_no_regions(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert result == []

    def test_returns_sorted(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "eu-west-1.yaml").write_text("{}\n")
        (env_dir / "ap-southeast-1.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert result == ["ap-southeast-1", "eu-west-1", "us-east-1"]


# =============================================================================
# deep_merge
# =============================================================================


class TestDeepMerge:
    def test_flat_merge(self):
        assert deep_merge({"a": 1}, {"b": 2}) == {"a": 1, "b": 2}

    def test_overlay_overrides_base(self):
        assert deep_merge({"a": 1}, {"a": 2}) == {"a": 2}

    def test_nested_merge(self):
        base = {"x": {"a": 1, "b": 2}}
        overlay = {"x": {"b": 3, "c": 4}}
        assert deep_merge(base, overlay) == {"x": {"a": 1, "b": 3, "c": 4}}

    def test_deeply_nested_merge(self):
        base = {"x": {"y": {"a": 1}}}
        overlay = {"x": {"y": {"b": 2}}}
        assert deep_merge(base, overlay) == {"x": {"y": {"a": 1, "b": 2}}}

    def test_overlay_replaces_non_dict_with_dict(self):
        assert deep_merge({"a": 1}, {"a": {"nested": True}}) == {
            "a": {"nested": True}
        }

    def test_overlay_replaces_dict_with_non_dict(self):
        assert deep_merge({"a": {"nested": True}}, {"a": "flat"}) == {"a": "flat"}

    def test_does_not_mutate_base(self):
        base = {"a": {"b": 1}}
        overlay = {"a": {"c": 2}}
        deep_merge(base, overlay)
        assert base == {"a": {"b": 1}}

    def test_empty_base(self):
        assert deep_merge({}, {"a": 1}) == {"a": 1}

    def test_empty_overlay(self):
        assert deep_merge({"a": 1}, {}) == {"a": 1}

    def test_both_empty(self):
        assert deep_merge({}, {}) == {}


# =============================================================================
# resolve_templates
# =============================================================================


class TestResolveTemplates:
    def test_simple_string_substitution(self):
        result = resolve_templates("hello {{ name }}", {"name": "world"})
        assert result == "hello world"

    def test_no_template_in_string(self):
        assert resolve_templates("plain text", {}) == "plain text"

    def test_dict_values_resolved(self):
        data = {"key": "{{ env }}-value", "static": "no-change"}
        result = resolve_templates(data, {"env": "prod"})
        assert result == {"key": "prod-value", "static": "no-change"}

    def test_list_values_resolved(self):
        data = ["{{ a }}", "{{ b }}"]
        result = resolve_templates(data, {"a": "x", "b": "y"})
        assert result == ["x", "y"]

    def test_nested_structures(self):
        data = {"outer": {"inner": "{{ val }}"}}
        result = resolve_templates(data, {"val": "resolved"})
        assert result == {"outer": {"inner": "resolved"}}

    def test_non_string_passthrough(self):
        assert resolve_templates(42, {}) == 42
        assert resolve_templates(True, {}) is True
        assert resolve_templates(None, {}) is None

    def test_mixed_list(self):
        data = ["{{ x }}", 42, {"k": "{{ x }}"}]
        result = resolve_templates(data, {"x": "val"})
        assert result == ["val", 42, {"k": "val"}]

    def test_plain_string_false_not_coerced(self):
        result = resolve_templates("false", {})
        assert result == "false"

    def test_undefined_variable_raises(self):
        with pytest.raises(ValueError, match="undefined"):
            resolve_templates("{{ regional_cluster.observe.nothere }}", {})

    def test_undefined_nested_with_default_ok(self):
        result = resolve_templates(
            "{{ regional_cluster.observe.nothere | default('fallback') }}", {}
        )
        assert result == "fallback"

    def test_undefined_in_dict_raises(self):
        data = {"key": "{{ missing.nested.path }}"}
        with pytest.raises(ValueError, match="undefined"):
            resolve_templates(data, {})


# =============================================================================
# tojson filter — undefined detection
# =============================================================================


class TestTojsonUndefinedDetection:
    def _render(self, template_str, context=None):
        env = _make_jinja_env()
        return env.from_string(template_str).render(context or {})

    def test_top_level_undefined_raises(self):
        with pytest.raises(ValueError, match="undefined variable passed to tojson"):
            self._render("{{ missing | tojson }}")

    def test_nested_undefined_in_dict_raises(self):
        with pytest.raises(ValueError, match="undefined variable passed to tojson"):
            self._render(
                '{{ {"key": parent.missing_child} | tojson }}',
                {"parent": {"other": "exists"}},
            )

    def test_nested_undefined_in_list_raises(self):
        with pytest.raises(ValueError, match="undefined variable passed to tojson"):
            self._render(
                "{{ [1, parent.missing_child] | tojson }}",
                {"parent": {"other": "exists"}},
            )

    def test_defined_values_serialize(self):
        result = self._render("{{ val | tojson }}", {"val": {"a": [1, True]}})
        assert '"a"' in result
        assert "1" in result

    def test_default_filter_bypasses_check(self):
        result = self._render('{{ missing | default("ok") | tojson }}')
        assert '"ok"' in result


# =============================================================================
# resolve_templates — type preservation
# =============================================================================


class TestResolveTemplatesTypePreservation:
    """Verify that resolve_templates preserves value types when values are
    referenced via Jinja2 templates.  Two invariants:

    1. String values that *look like* other types (e.g. "42", "true") must
       remain strings — no silent coercion.
    2. Native ints, bools, and floats must remain their original type when
       referenced through a template expression.
    """

    # -----------------------------------------------------------------
    # Category 1: Strings that look like other types stay strings
    # -----------------------------------------------------------------

    @pytest.mark.parametrize(
        "string_val",
        ["42", "001", "true", "on", "yes", "0.15"],
        ids=["int-like", "leading-zero", "bool-true", "bool-on", "bool-yes", "float-like"],
    )
    def test_string_direct_not_coerced(self, string_val):
        """A string value rendered via {{ val }} must stay a string."""
        result = resolve_templates("{{ val }}", {"val": string_val})
        assert result == string_val
        assert type(result) is str

    @pytest.mark.parametrize(
        "string_val",
        ["42", "001", "true", "on", "yes", "0.15"],
        ids=["int-like", "leading-zero", "bool-true", "bool-on", "bool-yes", "float-like"],
    )
    def test_string_cross_reference_not_coerced(self, string_val):
        """A string defined in one part of the config and referenced elsewhere
        must remain a string after two rounds of resolve_templates."""
        config = {"settings": {"port": string_val}}
        resolved_config = resolve_templates(config, {})
        result = resolve_templates(
            "{{ settings.port }}", resolved_config
        )
        assert result == string_val
        assert type(result) is str

    # -----------------------------------------------------------------
    # Category 2: Native types stay native when referenced
    # -----------------------------------------------------------------

    def test_native_int_preserved(self):
        """An int value referenced via {{ val }} must remain an int."""
        result = resolve_templates("{{ val }}", {"val": 42})
        assert result == 42
        assert type(result) is int

    def test_native_bool_true_preserved(self):
        """A True bool referenced via {{ val }} must remain True (bool)."""
        result = resolve_templates("{{ val }}", {"val": True})
        assert result is True
        assert type(result) is bool

    def test_native_bool_false_preserved(self):
        """A False bool referenced via {{ val }} must remain False (bool)."""
        result = resolve_templates("{{ val }}", {"val": False})
        assert result is False
        assert type(result) is bool

    def test_native_float_preserved(self):
        """A float value referenced via {{ val }} must remain a float."""
        result = resolve_templates("{{ val }}", {"val": 0.15})
        assert result == 0.15
        assert type(result) is float

    def test_native_int_cross_reference_preserved(self):
        """An int defined in config and referenced elsewhere stays int."""
        config = {"settings": {"port": 8080}}
        resolved_config = resolve_templates(config, {})
        result = resolve_templates("{{ settings.port }}", resolved_config)
        assert result == 8080
        assert type(result) is int

    def test_native_bool_cross_reference_preserved(self):
        """A bool defined in config and referenced elsewhere stays bool."""
        config = {"features": {"enabled": True}}
        resolved_config = resolve_templates(config, {})
        result = resolve_templates("{{ features.enabled }}", resolved_config)
        assert result is True
        assert type(result) is bool

    def test_native_float_cross_reference_preserved(self):
        """A float defined in config and referenced elsewhere stays float."""
        config = {"settings": {"ratio": 0.15}}
        resolved_config = resolve_templates(config, {})
        result = resolve_templates("{{ settings.ratio }}", resolved_config)
        assert result == 0.15
        assert type(result) is float

    # -----------------------------------------------------------------
    # Mixed: native types in nested structures
    # -----------------------------------------------------------------

    def test_mixed_types_in_dict_preserved(self):
        """A dict with mixed native types preserves all types."""
        config = {
            "str_val": "hello",
            "int_val": 42,
            "bool_val": True,
            "float_val": 0.15,
            "str_that_looks_int": "001",
            "str_that_looks_bool": "true",
        }
        result = resolve_templates(config, {})
        assert type(result["str_val"]) is str
        assert type(result["int_val"]) is int
        assert type(result["bool_val"]) is bool
        assert type(result["float_val"]) is float
        assert result["str_that_looks_int"] == "001"
        assert type(result["str_that_looks_int"]) is str
        assert result["str_that_looks_bool"] == "true"
        assert type(result["str_that_looks_bool"]) is str

    # -----------------------------------------------------------------
    # Category 3: Native types preserved through filter expressions
    # -----------------------------------------------------------------

    def test_bool_false_with_default_filter_preserved(self):
        """A False bool rendered via {{ val | default(false) }} must stay bool."""
        result = resolve_templates("{{ val | default(false) }}", {"val": False})
        assert result is False
        assert type(result) is bool

    def test_bool_true_with_default_filter_preserved(self):
        """A True bool rendered via {{ val | default(false) }} must stay bool."""
        result = resolve_templates("{{ val | default(false) }}", {"val": True})
        assert result is True
        assert type(result) is bool

    def test_bool_default_fallback_preserved(self):
        """When the base var is missing, the type is inferred from the
        default() literal and the rendered result is coerced to match."""
        result = resolve_templates("{{ missing | default(false) }}", {})
        assert result is False
        assert type(result) is bool

    def test_int_with_default_filter_preserved(self):
        """An int rendered via {{ val | default(0) }} must stay int."""
        result = resolve_templates("{{ val | default(0) }}", {"val": 42})
        assert result == 42
        assert type(result) is int

    def test_float_with_default_filter_preserved(self):
        """A float rendered via {{ val | default(0.0) }} must stay float."""
        result = resolve_templates("{{ val | default(0.0) }}", {"val": 0.15})
        assert result == 0.15
        assert type(result) is float

    def test_string_with_default_filter_not_coerced(self):
        """A string value with a default filter must stay a string."""
        result = resolve_templates('{{ val | default("fallback") }}', {"val": "001"})
        assert result == "001"
        assert type(result) is str

    def test_bool_cross_reference_with_default_preserved(self):
        """A bool defined in config and referenced with | default stays bool."""
        config = {"features": {"enabled": False}}
        resolved_config = resolve_templates(config, {})
        result = resolve_templates(
            "{{ features.enabled | default(false) }}", resolved_config
        )
        assert result is False
        assert type(result) is bool

    def test_string_bool_with_default_not_coerced(self):
        """A string 'true' with a default filter must stay a string."""
        result = resolve_templates('{{ val | default("nope") }}', {"val": "true"})
        assert result == "true"
        assert type(result) is str

    # -----------------------------------------------------------------
    # Category 4: Default fallback type detection (base var missing)
    # -----------------------------------------------------------------

    def test_default_fallback_bool_true(self):
        """default(true) with missing base var produces True (bool)."""
        result = resolve_templates("{{ missing | default(true) }}", {})
        assert result is True
        assert type(result) is bool

    def test_default_fallback_int(self):
        """default(42) with missing base var produces 42 (int)."""
        result = resolve_templates("{{ missing | default(42) }}", {})
        assert result == 42
        assert type(result) is int

    def test_default_fallback_float(self):
        """default(0.5) with missing base var produces 0.5 (float)."""
        result = resolve_templates("{{ missing | default(0.5) }}", {})
        assert result == 0.5
        assert type(result) is float

    def test_default_fallback_quoted_string(self):
        """default("hello") with missing base var produces 'hello' (str)."""
        result = resolve_templates('{{ missing | default("hello") }}', {})
        assert result == "hello"
        assert type(result) is str

    def test_default_fallback_variable_lookup(self):
        """default(some_var) where some_var is a bool in context preserves bool."""
        result = resolve_templates(
            "{{ missing | default(features.enabled) }}",
            {"features": {"enabled": False}},
        )
        assert result is False
        assert type(result) is bool

    def test_default_fallback_variable_lookup_int(self):
        """default(some_var) where some_var is an int in context preserves int."""
        result = resolve_templates(
            "{{ missing | default(settings.port) }}",
            {"settings": {"port": 8080}},
        )
        assert result == 8080
        assert type(result) is int

    def test_default_fallback_variable_also_missing(self):
        """default(also_missing) where both vars are missing raises ValueError."""
        with pytest.raises(ValueError, match="undefined variable"):
            resolve_templates("{{ missing | default(also_missing) }}", {})


# =============================================================================
# write_output
# =============================================================================


class TestWriteOutput:
    def test_creates_file_with_content(self, tmp_path):
        output = tmp_path / "sub" / "output.txt"
        write_output("hello world", output)
        assert output.exists()
        assert output.read_text() == "hello world\n"

    def test_creates_parent_directories(self, tmp_path):
        output = tmp_path / "deep" / "nested" / "dir" / "file.txt"
        write_output("content", output)
        assert output.exists()

    def test_adds_trailing_newline(self, tmp_path):
        output = tmp_path / "file.txt"
        write_output("no newline", output)
        assert output.read_text().endswith("\n")

    def test_preserves_existing_trailing_newline(self, tmp_path):
        output = tmp_path / "file.txt"
        write_output("has newline\n", output)
        content = output.read_text()
        assert content == "has newline\n"
        assert not content.endswith("\n\n")


# =============================================================================
# build_context
# =============================================================================


class TestBuildContext:
    def test_injects_identity_variables(self):
        ctx = build_context({}, "staging", "us-east-1", "")
        assert ctx["environment"] == "staging"
        assert ctx["aws_region"] == "us-east-1"

    def test_eph_prefix_injected(self):
        ctx = build_context({}, "staging", "us-east-1", "xg4y")
        assert ctx["eph_prefix"] == "xg4y"

    def test_resolves_account_id_template(self):
        merged = {"aws": {"account_id": "account-{{ environment }}-{{ aws_region }}"}}
        ctx = build_context(merged, "staging", "us-east-1", "")
        assert ctx["account_id"] == "account-staging-us-east-1"

    def test_resolves_terraform_common_templates(self):
        merged = {"terraform_tags": {"region": "{{ aws_region }}"}}
        ctx = build_context(merged, "prod", "eu-west-1", "")
        assert ctx["terraform_tags"]["region"] == "eu-west-1"

    def test_write_sre_tools_true_raises_for_non_ephemeral(self):
        merged = {"regional_cluster": {"enable_write_sre_tools": True}}
        with pytest.raises(ValueError, match="can only be true for ephemeral"):
            build_context(merged, "integration", "us-east-1", "")

    def test_write_sre_tools_true_raises_for_production(self):
        merged = {"regional_cluster": {"enable_write_sre_tools": True}}
        with pytest.raises(ValueError, match="can only be true for ephemeral"):
            build_context(merged, "production", "us-east-1", "")

    def test_write_sre_tools_true_allowed_for_ephemeral(self):
        merged = {"regional_cluster": {"enable_write_sre_tools": True}}
        ctx = build_context(merged, "ephemeral", "us-east-1", "xg4y")
        assert ctx["regional_cluster"]["enable_write_sre_tools"] is True

    def test_write_sre_tools_false_allowed_for_any_environment(self):
        for env in ["integration", "production", "ephemeral"]:
            merged = {"regional_cluster": {"enable_write_sre_tools": False}}
            ctx = build_context(merged, env, "us-east-1", "")
            assert ctx["regional_cluster"]["enable_write_sre_tools"] is False


# =============================================================================
# build_mc_list
# =============================================================================


class TestBuildMcList:
    def test_builds_mc_entries(self):
        merged = {"provision_mcs": {"mc01": {"account_id": "111"}}}
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert len(mc_list) == 1
        assert mc_list[0]["management_id"] == "mc01"
        assert mc_list[0]["account_id"] == "111"

    def test_eph_prefix_applied(self):
        merged = {"provision_mcs": {"mc01": {"account_id": "111"}}}
        ctx = build_context(merged, "staging", "us-east-1", "xg4y")
        mc_list = build_mc_list(ctx, merged, "xg4y")
        assert mc_list[0]["management_id"] == "xg4y-mc01"

    def test_shared_ids_do_not_duplicate_suffixes(self):
        merged = {
            "provision_mcs": {"mc01": {"account_id": "111"}},
        }
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")

        assert ctx["regional_id"] == "regional"
        assert mc_list[0]["management_id"] == "mc01"

    def test_ephemeral_ids_keep_prefix(self):
        merged = {"provision_mcs": {"mc01": {"account_id": "111"}}}
        ctx = build_context(merged, "ephemeral", "us-east-1", "beb87f69")
        mc_list = build_mc_list(ctx, merged, "beb87f69")

        assert ctx["regional_id"] == "beb87f69-regional"
        assert mc_list[0]["management_id"] == "beb87f69-mc01"

    def test_default_account_id(self):
        merged = {
            "aws": {"management_cluster_account_id": "default-account"},
            "provision_mcs": {"mc01": {}},
        }
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "default-account"

    def test_explicit_account_overrides_default(self):
        merged = {
            "aws": {"management_cluster_account_id": "default-account"},
            "provision_mcs": {"mc01": {"account_id": "explicit-account"}},
        }
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "explicit-account"

    def test_cluster_prefix_template_resolution(self):
        merged = {
            "aws": {"management_cluster_account_id": "mc-{{ cluster_prefix }}-{{ aws_region }}"},
            "provision_mcs": {"mc01": {}},
        }
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "mc-mc01-us-east-1"


class TestClusterTopologyValidation:
    def test_rejects_duplicate_rc_and_mc_ids(self):
        merged = {
            "provision_mcs": {"mc01": {"account_id": "111"}},
            "aws": {"management_cluster_account_id": "222"},
            "cluster_naming": {
                "rc_pattern": "{prefix}-cluster",
                "mc_pattern": "{prefix}-cluster",
            },
        }
        ctx = build_context(merged, "integration", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")

        with pytest.raises(ValueError, match="used by both"):
            validate_cluster_topology(merged, ctx, mc_list, "integration", "us-east-1")

    def test_rejects_missing_mc_account(self):
        merged = {"provision_mcs": {"mc01": {}}}
        ctx = build_context(merged, "integration", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        mc_list[0].pop("account_id", None)

        with pytest.raises(ValueError, match="no account_id"):
            validate_cluster_topology(merged, ctx, mc_list, "integration", "us-east-1")


# =============================================================================
# cleanup_stale_files
# =============================================================================


class TestCleanupStaleFiles:
    def test_removes_orphaned_input_directories_after_template_rename(self, tmp_path):
        region_dir = tmp_path / "staging" / "us-east-1"
        for name in ("obsolete-cluster-inputs", "pipeline-regional-cluster-inputs", "argocd-bootstrap-regional-cluster"):
            (region_dir / name).mkdir(parents=True)

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=tmp_path,
        )

        assert not (region_dir / "obsolete-cluster-inputs").exists()
        assert (region_dir / "pipeline-regional-cluster-inputs").is_dir()
        assert (region_dir / "argocd-bootstrap-regional-cluster").is_dir()

    def test_removes_stale_environment(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        stale_dir = deploy_dir / "old-env" / "us-east-1"
        stale_dir.mkdir(parents=True)
        (stale_dir / "file.txt").touch()

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=deploy_dir,
        )

        assert not (deploy_dir / "old-env").exists()

    def test_removes_stale_region(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        stale_dir = deploy_dir / "staging" / "us-west-2"
        stale_dir.mkdir(parents=True)
        (stale_dir / "file.txt").touch()
        valid_dir = deploy_dir / "staging" / "us-east-1"
        valid_dir.mkdir(parents=True)

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=deploy_dir,
        )

        assert not (deploy_dir / "staging" / "us-west-2").exists()
        assert (deploy_dir / "staging" / "us-east-1").exists()

    def test_keeps_valid_region(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        valid_dir = deploy_dir / "staging" / "us-east-1"
        valid_dir.mkdir(parents=True)
        (valid_dir / "file.txt").touch()

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=deploy_dir,
        )

        assert (deploy_dir / "staging" / "us-east-1").exists()

    def test_removes_stale_mc_input_directories(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        region_dir = deploy_dir / "staging" / "us-east-1"
        # Valid MC dir
        (region_dir / "pipeline-management-cluster-mc01-inputs").mkdir(parents=True)
        # Stale MC dir
        (region_dir / "pipeline-management-cluster-mc02-inputs").mkdir(parents=True)

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": {"mc01"}}},
            deploy_dir=deploy_dir,
        )

        assert (
            region_dir / "pipeline-management-cluster-mc01-inputs"
        ).exists()
        assert not (
            region_dir / "pipeline-management-cluster-mc02-inputs"
        ).exists()

    def test_removes_stale_mc_provisioner_files(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        prov_dir = deploy_dir / "staging" / "us-east-1" / "pipeline-provisioner-inputs"
        prov_dir.mkdir(parents=True)
        (prov_dir / "management-cluster-mc01.json").touch()
        (prov_dir / "management-cluster-mc02.json").touch()  # stale

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": {"mc01"}}},
            deploy_dir=deploy_dir,
        )

        assert (prov_dir / "management-cluster-mc01.json").exists()
        assert not (prov_dir / "management-cluster-mc02.json").exists()

    def test_no_op_when_deploy_dir_missing(self, tmp_path):
        deploy_dir = tmp_path / "nonexistent"
        cleanup_stale_files(
            valid_envs=set(),
            env_regions={},
            env_region_mcs={},
            deploy_dir=deploy_dir,
        )  # should not raise

    def test_ignores_hidden_directories(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        hidden = deploy_dir / ".hidden"
        hidden.mkdir(parents=True)
        (hidden / "file.txt").touch()

        cleanup_stale_files(
            valid_envs=set(),
            env_regions={},
            env_region_mcs={},
            deploy_dir=deploy_dir,
        )

        assert hidden.exists()


# =============================================================================
# Integration tests: config merge + output files
# =============================================================================


class TestConfigMergeAndRendering:
    """Tests that exercise the full merge chain (global -> env -> region)
    by creating config structures and verifying the merged output."""

    def test_deep_merge_inheritance(self, tmp_path):
        """Global defaults are merged with env defaults and region config."""
        global_defaults = {
            "terraform_common": {"app_code": "infra", "service_phase": "dev"},
        }
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults=global_defaults,
            environments={
                "staging": {
                    "defaults": {"terraform_common": {"service_phase": "staging"}},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        assert merged["terraform_common"]["app_code"] == "infra"
        assert merged["terraform_common"]["service_phase"] == "staging"

    def test_region_level_overrides_env_and_defaults(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"terraform_common": {"key": "default"}},
            environments={
                "staging": {
                    "defaults": {"terraform_common": {"key": "env"}},
                    "regions": {
                        "us-east-1": {
                            "terraform_common": {"key": "region"},
                            "provision_mcs": {},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        assert merged["terraform_common"]["key"] == "region"

    def test_jinja2_templates_resolved_in_terraform(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "terraform_tags": {
                    "region": "{{ aws_region }}",
                    "env": "{{ environment }}",
                },
            },
            environments={
                "prod": {
                    "defaults": {},
                    "regions": {
                        "eu-west-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "prod" / "defaults.yaml")
        rc = load_yaml(config_dir / "prod" / "eu-west-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        ctx = build_context(merged, "prod", "eu-west-1", "")
        assert ctx["terraform_tags"]["region"] == "eu-west-1"
        assert ctx["terraform_tags"]["env"] == "prod"

    def test_provision_mcs_in_region(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {"account_id": "111"},
                                "mc02": {"account_id": "222"},
                            },
                        },
                    },
                }
            },
        )

        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        mc_dict = rc.get("provision_mcs", {})
        assert len(mc_dict) == 2
        assert "mc01" in mc_dict
        assert "mc02" in mc_dict

    def test_management_cluster_default_account_id(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"management_cluster_account_id": "default-mc-account"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "default-mc-account"

    def test_management_cluster_explicit_account_overrides_default(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"management_cluster_account_id": "default-mc-account"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {"account_id": "explicit-account"},
                            },
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "explicit-account"

    def test_eph_prefix_applied_to_management_id(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "xg4y")
        mc_list = build_mc_list(ctx, merged, "xg4y")
        assert len(mc_list) == 1
        assert mc_list[0]["management_id"] == "xg4y-mc01"

    def test_eph_prefix_stored_in_context(self):
        ctx = build_context({}, "staging", "us-east-1", "xg4y")
        assert ctx["eph_prefix"] == "xg4y"

    def test_empty_eph_prefix(self):
        ctx = build_context({}, "staging", "us-east-1", "")
        assert ctx["eph_prefix"] == ""

    def test_revision_inheritance(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"git": {"revision": "main"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "git": {"revision": "abc1234"},
                            "provision_mcs": {},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        assert merged["git"]["revision"] == "abc1234"

    def test_revision_falls_back_to_defaults(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"git": {"revision": "main"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        assert merged["git"]["revision"] == "main"

    def test_applications_merge_chain(self, tmp_path):
        """applications values merge through defaults -> env -> region."""
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "applications": {
                    "regional-cluster": {"setting": "default", "shared": "from-defaults"},
                },
            },
            environments={
                "staging": {
                    "defaults": {
                        "applications": {
                            "regional-cluster": {"setting": "env-override"},
                        },
                    },
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        apps = merged["applications"]
        assert apps["regional-cluster"]["setting"] == "env-override"
        assert apps["regional-cluster"]["shared"] == "from-defaults"

    def test_arbitrary_field_inherits_without_code_changes(self, tmp_path):
        """Any field inherits through the full merge chain."""
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"custom_field": "from-defaults", "only_in_defaults": True},
            environments={
                "staging": {
                    "defaults": {"custom_field": "from-env"},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        assert merged["custom_field"] == "from-env"
        assert merged["only_in_defaults"] is True

    def test_account_id_template_resolution(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "account-{{ environment }}-{{ aws_region }}"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "")
        assert ctx["account_id"] == "account-staging-us-east-1"

    def test_management_cluster_template_with_cluster_prefix(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"management_cluster_account_id": "mc-{{ cluster_prefix }}-{{ aws_region }}"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        ctx = build_context(merged, "staging", "us-east-1", "")
        mc_list = build_mc_list(ctx, merged, "")
        assert mc_list[0]["account_id"] == "mc-mc01-us-east-1"


# =============================================================================
# Integration tests: full main() run
# =============================================================================


class TestMainIntegration:
    """Tests that run main() end-to-end and verify deploy/ output files."""

    def _run_main(self, tmp_path, global_defaults, environments, eph_prefix=""):
        """Helper to run main() with a tmp_path-based project root."""
        import sys
        import render

        config_dir = _create_config_structure(
            tmp_path,
            global_defaults=global_defaults,
            environments=environments,
        )
        _create_argocd_config(tmp_path)

        deploy_dir = tmp_path / "deploy"

        # Patch sys.argv
        old_argv = sys.argv
        args = ["render.py", "--config-dir", str(config_dir)]
        if eph_prefix:
            args.extend(["--eph-prefix", eph_prefix])
        sys.argv = args

        # Patch the project_root derivation in main()
        old_file = render.__file__
        render.__file__ = str(tmp_path / "scripts" / "render.py")

        try:
            result = main()
        finally:
            sys.argv = old_argv
            render.__file__ = old_file

        assert result == 0, "main() should return 0 on success"
        return deploy_dir

    def test_region_definitions_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        region_defs_file = deploy_dir / "staging" / "region-definitions.json"
        assert region_defs_file.exists()
        data = json.loads(region_defs_file.read_text())
        assert "us-east-1" in data
        entry = data["us-east-1"]
        assert entry["name"] == "staging"
        assert entry["environment"] == "staging"
        assert entry["aws_region"] == "us-east-1"

    def test_region_definitions_multiple_regions(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "prod": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                        "us-west-2": {"provision_mcs": {}},
                    },
                }
            },
        )

        region_defs_file = deploy_dir / "prod" / "region-definitions.json"
        data = json.loads(region_defs_file.read_text())
        assert len(data) == 2
        assert "us-east-1" in data
        assert "us-west-2" in data

    def test_region_definitions_multiple_environments(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                },
                "prod": {
                    "defaults": {},
                    "regions": {
                        "eu-west-1": {"provision_mcs": {}},
                    },
                },
            },
        )

        assert (deploy_dir / "staging" / "region-definitions.json").exists()
        assert (deploy_dir / "prod" / "region-definitions.json").exists()

    def test_region_definitions_with_provision_mcs(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {},
                                "mc02": {},
                            },
                        },
                    },
                }
            },
        )

        region_defs_file = deploy_dir / "staging" / "region-definitions.json"
        data = json.loads(region_defs_file.read_text())
        assert sorted(data["us-east-1"]["management_clusters"]) == ["mc01", "mc02"]

    def test_pipeline_provisioner_terraform_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"dns": {"domain": "test.example.com"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "terraform.json"
        )
        assert tf_file.exists()
        data = json.loads(tf_file.read_text())
        assert data["domain"] == "test.example.com"

    def test_pipeline_provisioner_regional_cluster_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"aws": {"account_id": "111111111111"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        rc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "regional-cluster.json"
        )
        assert rc_file.exists()
        data = json.loads(rc_file.read_text())
        assert data["region"] == "us-east-1"
        assert data["regional_id"] == "regional"
        assert data["account_id"] == "111111111111"

    def test_pipeline_provisioner_management_cluster_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "999999999999",
                    "management_cluster_account_id": "111111111111",
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        mc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "management-cluster-mc01.json"
        )
        assert mc_file.exists()
        data = json.loads(mc_file.read_text())
        assert data["management_id"] == "mc01"
        assert data["account_id"] == "111111111111"
        assert data["region"] == "us-east-1"

    def test_pipeline_regional_cluster_inputs_terraform_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111111111111"},
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        assert tf_file.exists()
        data = json.loads(tf_file.read_text())
        assert data["app_code"] == "infra"
        assert data["regional_id"] == "regional"
        assert data["environment"] == "staging"
        assert data["region"] == "us-east-1"
        assert data["_generated"].startswith("DO NOT EDIT")

    def test_ephemeral_ci_omits_zoa_suffixes_in_regional_terraform_json(
        self, tmp_path, monkeypatch
    ):
        """CI ephemeral (EPH_PREFIX + BUILD_ID) must not trust operator suffixes in ci00 central."""
        monkeypatch.setenv("BUILD_ID", "prow-123")
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "111111111111",
                    "zoa_access_trusted_assumer_role_name_suffixes": [
                        "rosa-seaplane-zoa-operator-dev",
                    ],
                },
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "ephemeral": {
                    "defaults": {},
                    "regions": {"us-east-1": {"provision_mcs": {}}},
                }
            },
            eph_prefix="abc123",
        )
        tf_file = (
            deploy_dir
            / "ephemeral"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        data = json.loads(tf_file.read_text())
        assert data["zoa_access_trusted_assumer_role_name_suffixes"] == []

    def test_pipeline_management_cluster_inputs_terraform_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "999999999999",
                    "management_cluster_account_id": "111111111111",
                },
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {},
                            },
                        },
                    },
                }
            },
        )

        mc_tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-management-cluster-mc01-inputs"
            / "terraform.json"
        )
        assert mc_tf_file.exists()
        data = json.loads(mc_tf_file.read_text())
        assert data["management_id"] == "mc01"
        assert data["account_id"] == "111111111111"
        assert data["regional_aws_account_id"] == "999999999999"
        assert data["app_code"] == "infra"

    def test_mc_account_ids_added_to_regional_terraform(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "999"},
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {
                                "mc01": {"account_id": "111"},
                                "mc02": {"account_id": "222"},
                            },
                        },
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        data = json.loads(tf_file.read_text())
        mc_info = sorted(data["management_clusters_info"], key=lambda x: x["id"])
        assert mc_info == [
            {"id": "mc01", "account_id": "111"},
            {"id": "mc02", "account_id": "222"},
        ]

    def test_argocd_values_files(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "applications": {
                    "regional-cluster": {"setting": "value"},
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        values_file = (
            deploy_dir / "staging" / "us-east-1" / "argocd-values-regional-cluster.yaml"
        )
        assert values_file.exists()
        content = values_file.read_text()
        assert "setting: value" in content
        assert "GENERATED FILE" in content

    def test_argocd_values_empty_creates_file(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        values_file = (
            deploy_dir / "staging" / "us-east-1" / "argocd-values-regional-cluster.yaml"
        )
        assert values_file.exists()

    def test_argocd_bootstrap_applicationset(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        appset_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "argocd-bootstrap-regional-cluster"
            / "applicationset.yaml"
        )
        assert appset_file.exists()
        content = appset_file.read_text()
        assert "GENERATED FILE" in content

    def test_argocd_bootstrap_pinned_revision(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "git": {"revision": "abc1234def5678901234567890abcdef12345678"},
                            "provision_mcs": {},
                        },
                    },
                }
            },
        )

        appset_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "argocd-bootstrap-regional-cluster"
            / "applicationset.yaml"
        )
        content = appset_file.read_text()
        assert "abc1234d" in content  # truncated hash in header

    def test_argocd_bootstrap_main_revision_not_pinned(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"git": {"revision": "main"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        appset_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "argocd-bootstrap-regional-cluster"
            / "applicationset.yaml"
        )
        content = appset_file.read_text()
        assert "metadata.annotations.git_revision" in content

    def test_eph_prefix_in_regional_id(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111111111111"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
            eph_prefix="xg4y",
        )

        rc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "regional-cluster.json"
        )
        data = json.loads(rc_file.read_text())
        assert data["regional_id"] == "xg4y-regional"

    def test_eph_prefix_in_management_id(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "999",
                    "management_cluster_account_id": "111",
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
            eph_prefix="xg4y",
        )

        mc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "management-cluster-xg4y-mc01.json"
        )
        assert mc_file.exists()
        data = json.loads(mc_file.read_text())
        assert data["management_id"] == "xg4y-mc01"

    def test_domain_in_provisioner_terraform(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "integration": {
                    "defaults": {"dns": {"domain": "int0.rosa.devshift.net"}},
                    "regions": {
                        "us-east-1": {"provision_mcs": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "integration"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "terraform.json"
        )
        data = json.loads(tf_file.read_text())
        assert data["domain"] == "int0.rosa.devshift.net"

    def test_instance_families_default_values(self, tmp_path):
        """Instance families should flow from defaults.yaml into ArgoCD values"""
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111", "management_cluster_account_id": "222"},
                "regional_cluster": {
                    "node_instance_families": ["m8i", "m7i"],
                },
                "management_cluster_defaults": {
                    "node_instance_families": ["m8i", "m7i"],
                },
                "applications": {
                    "regional-cluster": {
                        "eksNodePool": {
                            "instanceFamilies": "{{ regional_cluster.node_instance_families }}",
                        },
                    },
                    "management-cluster": {
                        "eksNodePool": {
                            "instanceFamilies": "{{ management_cluster_defaults.node_instance_families }}",
                        },
                    },
                },
            },
            environments={
                "test": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"provision_mcs": {"mc01": {}}},
                    },
                }
            },
        )

        # Check MC terraform.json no longer has node_instance_types
        mc_file = (
            deploy_dir
            / "test"
            / "us-east-1"
            / "pipeline-management-cluster-mc01-inputs"
            / "terraform.json"
        )
        mc_data = json.loads(mc_file.read_text())
        assert "node_instance_types" not in mc_data

        # Check RC terraform.json no longer has node_instance_types
        rc_file = (
            deploy_dir
            / "test"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        rc_data = json.loads(rc_file.read_text())
        assert "node_instance_types" not in rc_data

        # Check ArgoCD values contain instance families
        rc_values_file = deploy_dir / "test" / "us-east-1" / "argocd-values-regional-cluster.yaml"
        rc_values = yaml.safe_load(rc_values_file.read_text())
        assert rc_values["eksNodePool"]["instanceFamilies"] == ["m8i", "m7i"]

        mc_values_file = deploy_dir / "test" / "us-east-1" / "argocd-values-management-cluster.yaml"
        mc_values = yaml.safe_load(mc_values_file.read_text())
        assert mc_values["eksNodePool"]["instanceFamilies"] == ["m8i", "m7i"]

    def test_instance_families_environment_override(self, tmp_path):
        """Instance families can be overridden at environment level"""
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111", "management_cluster_account_id": "222"},
                "regional_cluster": {
                    "node_instance_families": ["m8i", "m7i"],
                },
                "management_cluster_defaults": {
                    "node_instance_families": ["m8i", "m7i"],
                },
                "applications": {
                    "regional-cluster": {
                        "eksNodePool": {
                            "instanceFamilies": "{{ regional_cluster.node_instance_families }}",
                        },
                    },
                    "management-cluster": {
                        "eksNodePool": {
                            "instanceFamilies": "{{ management_cluster_defaults.node_instance_families }}",
                        },
                    },
                },
            },
            environments={
                "prod": {
                    "defaults": {
                        "regional_cluster": {
                            "node_instance_families": ["m8i", "m7i"],
                        },
                        "management_cluster_defaults": {
                            "node_instance_families": ["m8i-flex", "m7i-flex"],
                        },
                    },
                    "regions": {
                        "us-east-1": {"provision_mcs": {"mc01": {}}},
                    },
                }
            },
        )

        rc_values_file = deploy_dir / "prod" / "us-east-1" / "argocd-values-regional-cluster.yaml"
        rc_values = yaml.safe_load(rc_values_file.read_text())
        assert rc_values["eksNodePool"]["instanceFamilies"] == ["m8i", "m7i"]

        mc_values_file = deploy_dir / "prod" / "us-east-1" / "argocd-values-management-cluster.yaml"
        mc_values = yaml.safe_load(mc_values_file.read_text())
        assert mc_values["eksNodePool"]["instanceFamilies"] == ["m8i-flex", "m7i-flex"]

    def test_instance_families_region_override(self, tmp_path):
        """Instance families can be overridden at region level"""
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111", "management_cluster_account_id": "222"},
                "regional_cluster": {
                    "node_instance_families": ["m8i", "m7i"],
                },
                "management_cluster_defaults": {
                    "node_instance_families": ["m8i", "m7i"],
                },
                "applications": {
                    "regional-cluster": {
                        "eksNodePool": {
                            "instanceFamilies": "{{ regional_cluster.node_instance_families }}",
                        },
                    },
                    "management-cluster": {
                        "eksNodePool": {
                            "instanceFamilies": "{{ management_cluster_defaults.node_instance_families }}",
                        },
                    },
                },
            },
            environments={
                "test": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "regional_cluster": {
                                "node_instance_families": ["c6i"],
                            },
                            "provision_mcs": {"mc01": {}},
                        },
                    },
                }
            },
        )

        rc_values_file = deploy_dir / "test" / "us-east-1" / "argocd-values-regional-cluster.yaml"
        rc_values = yaml.safe_load(rc_values_file.read_text())
        assert rc_values["eksNodePool"]["instanceFamilies"] == ["c6i"]

    def test_merged_config_yaml_output(self, tmp_path):
        """Verify _merged_config.yaml is written with merged configuration"""
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"terraform_tags": {"app_code": "test"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {"us-east-1": {"provision_mcs": {}}},
                }
            },
        )

        config_file = deploy_dir / "staging" / "us-east-1" / "_merged_config.yaml"
        assert config_file.exists()
        data = yaml.safe_load(config_file.read_text())
        assert data["terraform_tags"]["app_code"] == "test"

    def test_write_sre_tools_false_renders_readonly_overlay(self, tmp_path):
        """When false, overlay sets Grafana Viewer role and ArgoCD read-only."""
        sre_tools_applications = {
            "applications": {
                "regional-cluster": {
                    "grafana": {
                        "grafana.ini": {
                            "auth.anonymous": {
                                "org_role": "{% if regional_cluster.enable_write_sre_tools %}Admin{% else %}Viewer{% endif %}",
                            },
                            "users": {
                                "auto_assign_org_role": "{% if regional_cluster.enable_write_sre_tools %}Admin{% else %}Viewer{% endif %}",
                            },
                        },
                    },
                    "argo-cd": {
                        "configs": {
                            "cm": {
                                "admin.enabled": "{% if regional_cluster.enable_write_sre_tools %}true{% else %}false{% endif %}",
                                "users.anonymous.enabled": "{% if regional_cluster.enable_write_sre_tools %}false{% else %}true{% endif %}",
                            },
                            "rbac": {
                                "policy.default": "{% if regional_cluster.enable_write_sre_tools %}{% else %}role:readonly{% endif %}",
                            },
                        },
                    },
                },
            },
        }
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "regional_cluster": {"enable_write_sre_tools": False},
                **sre_tools_applications,
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {"us-east-1": {"provision_mcs": {}}},
                }
            },
        )
        values = yaml.safe_load(
            (deploy_dir / "staging" / "us-east-1" / "argocd-values-regional-cluster.yaml").read_text()
        )
        assert values["grafana"]["grafana.ini"]["auth.anonymous"]["org_role"] == "Viewer"
        assert values["grafana"]["grafana.ini"]["users"]["auto_assign_org_role"] == "Viewer"
        assert values["argo-cd"]["configs"]["cm"]["admin.enabled"] == "false"
        assert values["argo-cd"]["configs"]["cm"]["users.anonymous.enabled"] == "true"
        assert values["argo-cd"]["configs"]["rbac"]["policy.default"] == "role:readonly"

    def test_write_sre_tools_true_renders_admin_overlay_for_ephemeral(self, tmp_path):
        """When true (ephemeral only), overlay sets Grafana Admin and ArgoCD admin enabled."""
        sre_tools_applications = {
            "applications": {
                "regional-cluster": {
                    "grafana": {
                        "grafana.ini": {
                            "auth.anonymous": {
                                "org_role": "{% if regional_cluster.enable_write_sre_tools %}Admin{% else %}Viewer{% endif %}",
                            },
                            "users": {
                                "auto_assign_org_role": "{% if regional_cluster.enable_write_sre_tools %}Admin{% else %}Viewer{% endif %}",
                            },
                        },
                    },
                    "argo-cd": {
                        "configs": {
                            "cm": {
                                "admin.enabled": "{% if regional_cluster.enable_write_sre_tools %}true{% else %}false{% endif %}",
                                "users.anonymous.enabled": "{% if regional_cluster.enable_write_sre_tools %}false{% else %}true{% endif %}",
                            },
                            "rbac": {
                                "policy.default": "{% if regional_cluster.enable_write_sre_tools %}{% else %}role:readonly{% endif %}",
                            },
                        },
                    },
                },
            },
        }
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "regional_cluster": {"enable_write_sre_tools": True},
                **sre_tools_applications,
            },
            environments={
                "ephemeral": {
                    "defaults": {},
                    "regions": {"us-east-1": {"provision_mcs": {}}},
                }
            },
        )
        values = yaml.safe_load(
            (deploy_dir / "ephemeral" / "us-east-1" / "argocd-values-regional-cluster.yaml").read_text()
        )
        assert values["grafana"]["grafana.ini"]["auth.anonymous"]["org_role"] == "Admin"
        assert values["grafana"]["grafana.ini"]["users"]["auto_assign_org_role"] == "Admin"
        assert values["argo-cd"]["configs"]["cm"]["admin.enabled"] == "true"
        assert values["argo-cd"]["configs"]["cm"]["users.anonymous.enabled"] == "false"
        assert values["argo-cd"]["configs"]["rbac"]["policy.default"] == ""

    def test_write_sre_tools_true_rejected_for_non_ephemeral(self, tmp_path):
        """render.py must fail if flag is true for a non-ephemeral environment."""
        with pytest.raises(ValueError, match="can only be true for ephemeral"):
            self._run_main(
                tmp_path,
                global_defaults={
                    "regional_cluster": {"enable_write_sre_tools": True},
                },
                environments={
                    "integration": {
                        "defaults": {},
                        "regions": {"us-east-1": {"provision_mcs": {}}},
                    }
                },
            )


# =============================================================================
# Documentation system tests
# =============================================================================


class TestScanAnnotations:
    def test_parses_doc_and_used_by(self):
        content = "# @doc dns.domain The domain\n# @used-by dns.domain template.j2\n"
        result = scan_annotations(content)
        assert "dns.domain" in result
        assert result["dns.domain"]["doc"] == "The domain"
        assert result["dns.domain"]["used_by"] == ["template.j2"]

    def test_multiple_used_by(self):
        content = (
            "# @doc tf.app Application code.\n"
            "# @used-by tf.app a.j2\n"
            "# @used-by tf.app b.j2\n"
        )
        result = scan_annotations(content)
        assert result["tf.app"]["used_by"] == ["a.j2", "b.j2"]

    def test_context_sentinel(self):
        content = "# @doc aws.id Account ID.\n# @used-by aws.id _context\n"
        result = scan_annotations(content)
        assert result["aws.id"]["used_by"] == ["_context"]

    def test_indented_annotations(self):
        content = "  # @doc dns.domain The domain\n  # @used-by dns.domain template.j2\n"
        result = scan_annotations(content)
        assert "dns.domain" in result
        assert result["dns.domain"]["used_by"] == ["template.j2"]

    def test_empty_content(self):
        assert scan_annotations("") == {}

    def test_ignores_non_annotation_comments(self):
        content = "# This is a regular comment\nkey: value\n"
        assert scan_annotations(content) == {}


class TestScanTemplateVariables:
    def test_finds_expression_variables(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.json.j2").write_text('{{ dns.domain }}')
        result = scan_template_variables(tpl_dir)
        assert "dns.domain" in result
        assert result["dns.domain"] == ["test.json.j2"]

    def test_finds_if_variables(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.j2").write_text("{% if delete %}yes{% endif %}")
        result = scan_template_variables(tpl_dir)
        assert "delete" in result

    def test_ignores_builtins(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.j2").write_text("{{ loop.index }}")
        assert "loop.index" not in scan_template_variables(tpl_dir)

    def test_subdirectory_templates(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        sub = tpl_dir / "sub"
        sub.mkdir(parents=True)
        (sub / "test.j2").write_text("{{ dns.domain }}")
        result = scan_template_variables(tpl_dir)
        assert result["dns.domain"] == ["sub/test.j2"]

    def test_ignores_double_quoted_go_template(self, tmp_path):
        """Go template keywords inside a double-quoted string literal must not be
        reported, but real Jinja variables should still be detected."""
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.j2").write_text('{{ real_var }} and {{ "{{ if .foo }}X{{ else }}Y{{ end }}" }}')
        result = scan_template_variables(tpl_dir)
        assert result == {"real_var": ["test.j2"]}
        assert "if" not in result
        assert "else" not in result
        assert "end" not in result

    def test_ignores_single_quoted_go_template_else_end(self, tmp_path):
        """Go template keywords inside a single-quoted string literal must not be
        reported, but real Jinja variables should still be detected."""
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.j2").write_text("{{ another_var }} and {{ '{{ if .foo }}X{{ else }}Y{{ end }}' }}")
        result = scan_template_variables(tpl_dir)
        assert result == {"another_var": ["test.j2"]}
        assert "if" not in result
        assert "else" not in result
        assert "end" not in result


class TestCollectLeafPaths:
    def test_flat_dict(self):
        assert collect_leaf_paths({"a": 1, "b": 2}) == {"a", "b"}

    def test_nested_dict(self):
        assert collect_leaf_paths({"a": {"b": 1}}) == {"a.b"}

    def test_deeply_nested(self):
        assert collect_leaf_paths({"a": {"b": {"c": 1}}}) == {"a.b.c"}

    def test_empty_dict_is_leaf(self):
        assert collect_leaf_paths({"a": {}}) == {"a"}

    def test_mixed(self):
        result = collect_leaf_paths({"a": 1, "b": {"c": 2, "d": 3}})
        assert result == {"a", "b.c", "b.d"}


class TestCheckDocs:
    def _setup(self, tmp_path, defaults_content, templates=None):
        config = tmp_path / "config"
        config.mkdir()
        tpl = config / "templates"
        tpl.mkdir()
        (config / "defaults.yaml").write_text(defaults_content)
        if templates:
            for path, content in templates.items():
                full = tpl / path
                full.parent.mkdir(parents=True, exist_ok=True)
                full.write_text(content)
        return config, tpl

    def test_passes_when_all_documented(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc dns.domain The domain\n# @used-by dns.domain test.j2\ndns:\n  domain: ''\n",
            {"test.j2": "{{ dns.domain }}"},
        )
        assert check_docs(config, tpl) == 0

    def test_fails_undocumented_leaf(self, tmp_path):
        config, tpl = self._setup(tmp_path, "undocumented: value\n")
        assert check_docs(config, tpl) == 1

    def test_fails_missing_used_by(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc my.key desc\nmy:\n  key: val\n",
        )
        assert check_docs(config, tpl) == 1

    def test_fails_bad_template_ref(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc my.key desc\n# @used-by my.key nonexistent.j2\nmy:\n  key: val\n",
        )
        assert check_docs(config, tpl) == 1

    def test_fails_wrong_consumer(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc my.key desc\n# @used-by my.key test.j2\nmy:\n  key: val\n",
            {"test.j2": "{{ other_var }}"},
        )
        assert check_docs(config, tpl) == 1

    def test_fails_undocumented_template_var(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "{}\n",
            {"test.j2": "{{ undocumented.var }}"},
        )
        assert check_docs(config, tpl) == 1

    def test_fails_unused_leaf(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc my.key desc\n# @used-by my.key test.j2\nmy:\n  key: val\n",
            {"test.j2": "{{ dns.domain }}"},
        )
        assert check_docs(config, tpl) == 1

    def test_context_skips_template_check(self, tmp_path):
        config, tpl = self._setup(
            tmp_path,
            "# @doc git.rev Revision.\n# @used-by git.rev _context\ngit:\n  rev: main\n",
        )
        assert check_docs(config, tpl) == 0

    def test_context_vars_not_flagged(self, tmp_path):
        """Template vars in CONTEXT_VARS (e.g. environment) don't need @doc."""
        config, tpl = self._setup(
            tmp_path,
            "{}\n",
            {"test.j2": "{{ environment }}"},
        )
        assert check_docs(config, tpl) == 0

    def test_ancestor_doc_covers_leaf(self, tmp_path):
        """A @doc on a parent key covers child leaves."""
        config, tpl = self._setup(
            tmp_path,
            "# @doc tf desc\n# @used-by tf test.j2\ntf:\n  a: 1\n  b: 2\n",
            {"test.j2": "{{ tf.a }} {{ tf.b }}"},
        )
        assert check_docs(config, tpl) == 0

    def test_real_config(self):
        """Verify the actual project config passes the check."""
        config_dir = PROJECT_ROOT / "config"
        templates_dir = config_dir / "templates"
        assert check_docs(config_dir, templates_dir) == 0


class TestUpdateDocs:
    def test_regenerates_used_by(self, tmp_path):
        config = tmp_path / "config"
        config.mkdir()
        tpl = config / "templates"
        tpl.mkdir()
        (tpl / "test.j2").write_text("{{ dns.domain }}")
        (config / "defaults.yaml").write_text(
            "# @doc dns.domain The domain\n# @used-by dns.domain wrong.j2\ndns:\n  domain: ''\n"
        )
        assert update_docs(config, tpl) == 0
        content = (config / "defaults.yaml").read_text()
        assert "# @used-by dns.domain test.j2" in content
        assert "wrong.j2" not in content

    def test_preserves_context_entries(self, tmp_path):
        config = tmp_path / "config"
        config.mkdir()
        tpl = config / "templates"
        tpl.mkdir()
        (config / "defaults.yaml").write_text(
            "# @doc git.rev Revision\n# @used-by git.rev _context\ngit:\n  rev: main\n"
        )
        assert update_docs(config, tpl) == 0
        content = (config / "defaults.yaml").read_text()
        assert "# @used-by git.rev _context" in content

    def test_preserves_doc_descriptions(self, tmp_path):
        config = tmp_path / "config"
        config.mkdir()
        tpl = config / "templates"
        tpl.mkdir()
        (tpl / "test.j2").write_text("{{ dns.domain }}")
        (config / "defaults.yaml").write_text(
            "# @doc dns.domain My custom description\n# @used-by dns.domain old.j2\ndns:\n  domain: ''\n"
        )
        update_docs(config, tpl)
        content = (config / "defaults.yaml").read_text()
        assert "My custom description" in content


AUTHZ_BUNDLE = '''formatVersion: 1
registeredAccounts: ["012345678901"]
policies:
  - id: read-clusters
    ownerAccountID: "012345678901"
    content: |
      permit(principal, action in Seaplane::Action::"ReadOnly", resource)
      when { context.region == "us-east-1" && context.accountId == "012345678901" };
attachments:
  - id: readers
    policyID: read-clusters
    principalARN: arn:aws:iam::012345678901:role/platform/readers
    scope: regional
    region: us-east-1
'''
AUTHZ_EXAMPLE = PROJECT_ROOT / "docs" / "examples" / "authz-dev"
PLATFORM_CHART = REAL_ARGOCD_CONFIG_DIR / "regional-cluster" / "platform-api"


def _authz_values(tmp_path, env, overrides=None, eph_prefix="", region="us-east-1"):
    defaults = load_yaml(PROJECT_ROOT / "config" / "defaults.yaml")
    env_defaults = load_yaml(PROJECT_ROOT / "config" / env / "defaults.yaml")
    deploy = TestMainIntegration()._run_main(
        tmp_path,
        defaults,
        {env: {
            "defaults": deep_merge(env_defaults, overrides or {}),
            "regions": {region: {"provision_mcs": {"mc01": {}}}},
        }},
        eph_prefix,
    )
    return load_yaml(deploy / env / region / "argocd-values-regional-cluster.yaml")


def _helm_platform(tmp_path, overrides):
    helm = shutil.which("helm")
    assert helm, "Helm is required for authz delivery checks. Use the CI-pinned CLI."
    values = tmp_path / "helm-values.yaml"
    overrides = copy.deepcopy(overrides)
    overrides.setdefault("global", {}).setdefault("aws_region", "us-east-1")
    # Quote strings explicitly: PyYAML treats 012345678901 as a string while
    # Helm's YAML decoder may coerce an unquoted decimal containing 8 or 9.
    values.write_text(yaml.safe_dump(overrides, default_style='"'))
    rendered = subprocess.run(
        [helm, "template", "authz-test", str(PLATFORM_CHART), "-f", str(values)],
        check=True, capture_output=True, text=True,
    ).stdout
    resources = list(yaml.safe_load_all(rendered))
    return resources, rendered


def _resource(resources, kind, name):
    return next(r for r in resources if r["kind"] == kind and r["metadata"]["name"] == name)


def _assert_bundle_fields(bundle):
    # Bundles carry no service-operator domain; MCs register at startup instead.
    assert set(bundle) == {"formatVersion", "registeredAccounts", "policies", "attachments"}
    assert bundle["formatVersion"] == 1


def _assert_rc_grants(bundle, account, role):
    # Every env grants the identities behind rrp-rc: the child-admin role and CI's e2e user.
    assert [p["id"] for p in bundle["policies"]] == ["rc-all-actions"]
    assert [a["principalARN"] for a in bundle["attachments"]] == [
        f"arn:aws:iam::{account}:role/{role}", f"arn:aws:iam::{account}:user/e2e",
    ]


class TestAuthzDelivery:
    @pytest.mark.parametrize("env,ci,eph_prefix,role", [
        ("integration", False, "", "rosa-seaplane-account-admin"),
        ("stage", False, "", "rosa-seaplane-account-admin"),
        ("ephemeral", False, "", "OrganizationAccountAccessRole"),
        ("ephemeral", False, "authz-test", "OrganizationAccountAccessRole"),
        ("ephemeral", True, "", "OrganizationAccountAccessRole"),
    ])
    def test_safe_source_defaults(self, tmp_path, monkeypatch, env, ci, eph_prefix, role):
        monkeypatch.setenv("BUILD_ID", "test-ci" if ci else "")
        values = _authz_values(tmp_path, env, eph_prefix=eph_prefix)
        authz = values["platformApi"]["authz"]
        assert set(authz) == {"config"}
        bundle = yaml.safe_load(authz["config"])
        assert bundle["registeredAccounts"] == ["@@AWS_ACCOUNT_ID@@"]
        _assert_rc_grants(bundle, "@@AWS_ACCOUNT_ID@@", role)
        _assert_bundle_fields(bundle)

    @pytest.mark.parametrize("principal,scope", [
        ("role", "regional"), ("session", "global"),
        ("deny-all", "regional"),
    ])
    def test_bundle_passes_through(self, tmp_path, monkeypatch, principal, scope):
        monkeypatch.setenv("BUILD_ID", "test-ci")
        content = AUTHZ_BUNDLE
        if principal == "deny-all":
            content = "formatVersion: 1\nregisteredAccounts: []\npolicies: []\nattachments: []\n"
        if scope == "global":
            content = content.replace("scope: regional\n    region: us-east-1", "scope: global")
            content = content.replace("iam::012345678901:role/platform/readers",
                                      "sts::012345678901:assumed-role/readers/session-a")
        bundle = yaml.safe_load(content)
        overrides = {"applications": {"regional-cluster": {"platformApi": {
            "authz": {"config": content},
        }}}}
        overrides["aws"] = {"account_id": "987654321098"}
        values = _authz_values(tmp_path, "ephemeral", overrides, eph_prefix="authz-test")
        assert values["platformApi"]["authz"] == {"config": content.removesuffix("\n")}
        resources, _ = _helm_platform(tmp_path, values)
        config = _resource(resources, "ConfigMap", "authz-config")["data"]["config.yaml"]
        assert config == content
        assert yaml.safe_load(config) == bundle
        assert yaml.safe_load(config)["registeredAccounts"] == ([] if principal == "deny-all" else ["012345678901"])

    def test_dev_override(self, tmp_path):
        # The example replaces the whole bundle and names no account; Helm supplies the RC account.
        overrides = load_yaml(AUTHZ_EXAMPLE / "defaults.yaml")
        assert load_yaml(AUTHZ_EXAMPLE / "us-east-1.yaml") == {"provision_mcs": {"mc01": {}}}
        values = _authz_values(tmp_path, "ephemeral", overrides)
        values["global"] = {"aws_account_id": "012345678901", "aws_region": "us-east-1"}
        resources, _ = _helm_platform(tmp_path, values)
        bundle = yaml.safe_load(_resource(resources, "ConfigMap", "authz-config")["data"]["config.yaml"])
        _assert_bundle_fields(bundle)
        assert bundle["registeredAccounts"] == ["012345678901"]
        assert [p["id"] for p in bundle["policies"]] == ["rc-all-actions", "dev-read-only"]
        assert [a["principalARN"] for a in bundle["attachments"]] == [
            "arn:aws:iam::012345678901:role/OrganizationAccountAccessRole",
            "arn:aws:iam::012345678901:user/e2e",
            "arn:aws:iam::012345678901:role/dev-readers",
        ]

    @pytest.mark.parametrize("rate_enabled", [False, True])
    def test_mount_inputs_metrics(self, tmp_path, rate_enabled):
        resources, rendered = _helm_platform(tmp_path, {"platformApi": {
            "rateLimit": {"enabled": rate_enabled},
        }})
        bundle = _resource(resources, "ConfigMap", "authz-config")
        mounted = yaml.safe_load(bundle["data"]["config.yaml"])
        assert mounted == {
            "formatVersion": 1, "registeredAccounts": [], "policies": [], "attachments": [],
        }
        deployment = _resource(resources, "Deployment", "platform-api")
        pod = deployment["spec"]["template"]
        app = next(c for c in pod["spec"]["containers"] if c["name"] == "platform-api")
        env = {e["name"]: e.get("value") for e in app["env"]}
        assert "AUTHZ_RESOLVER" not in env
        assert env["AUTHZ_CONFIG_FILE"] == "/etc/platform-api/authz/config.yaml"
        mounts = {m["name"]: m for m in app["volumeMounts"]}
        assert mounts["authz-config"] == {
            "name": "authz-config", "mountPath": "/etc/platform-api/authz", "readOnly": True,
        }
        volumes = {v["name"]: v for v in pod["spec"]["volumes"]}
        assert volumes["authz-config"]["configMap"] == {"name": "authz-config", "defaultMode": 0o644}
        assert "defaultMode: 0644" in rendered
        config_text = next(part.split("\n", 1)[1] for part in rendered.split("---\n")
                           if part.startswith("# Source:") and "/authz-configmap.yaml\n" in part)
        annotations = pod["metadata"]["annotations"]
        # Helm trims the terminal indented blank line from printed manifests, not include.
        assert annotations["checksum/authz-config"] == hashlib.sha256((config_text + "    \n").encode()).hexdigest()
        assert ("rate-limits" in mounts) == ("rate-limits" in volumes) == rate_enabled
        assert ("checksum/rate-limits" in annotations) == rate_enabled
        assert ("RATE_LIMIT_CONFIG_FILE" in env) == rate_enabled
        if rate_enabled:
            assert mounts["rate-limits"]["readOnly"] is True
            assert mounts["rate-limits"]["mountPath"] == "/etc/platform-api/rate-limits"
            assert env["RATE_LIMIT_CONFIG_FILE"] == "/etc/platform-api/rate-limits/limits.yaml"
            assert _resource(resources, "ConfigMap", "rate-limits")["data"]["limits.yaml"]
        assert set(volumes) == {"authz-config"} | ({"rate-limits"} if rate_enabled else set())
        service = _resource(resources, "Service", "platform-api")
        monitor = _resource(resources, "ServiceMonitor", "platform-api")
        port = next(p for p in app["ports"] if p["name"] == "metrics")
        service_port = next(p for p in service["spec"]["ports"] if p["name"] == "metrics")
        assert port["containerPort"] == service_port["port"] == 9090
        assert service_port["targetPort"] == monitor["spec"]["endpoints"][0]["port"] == "metrics"
        assert monitor["spec"]["endpoints"][0].get("path", "/metrics") == "/metrics"
        assert monitor["spec"]["selector"]["matchLabels"] == service["metadata"]["labels"]
        assert monitor["spec"]["namespaceSelector"]["matchNames"] == [service["metadata"]["namespace"]]

    @pytest.mark.parametrize("change", ["registeredAccounts", "policies", "attachments", "namespace"])
    def test_complete_checksum(self, tmp_path, change):
        values = {"platformApi": {"authz": {"config": AUTHZ_BUNDLE}}}
        before, _ = _helm_platform(tmp_path, values)
        changed = copy.deepcopy(values)
        if change == "namespace":
            changed["platformApi"]["namespace"] = "other-platform-api"
        else:
            if change == "registeredAccounts":
                content = AUTHZ_BUNDLE.replace('["012345678901"]', '["012345678901", "999999999999"]')
            elif change == "policies":
                content = AUTHZ_BUNDLE.replace('context.region == "us-east-1"', 'context.region == "us-west-2"')
            else:
                content = AUTHZ_BUNDLE.replace("role/platform/readers", "role/platform/others")
            changed["platformApi"]["authz"]["config"] = content
        after, _ = _helm_platform(tmp_path, changed)
        def annotations(resources):
            return _resource(resources, "Deployment", "platform-api")["spec"]["template"]["metadata"]["annotations"]
        assert annotations(before)["checksum/authz-config"] != annotations(after)["checksum/authz-config"]
        if change == "namespace":
            assert annotations(before)["checksum/rate-limits"] != annotations(after)["checksum/rate-limits"]
        else:
            assert annotations(before)["checksum/rate-limits"] == annotations(after)["checksum/rate-limits"]

    def test_mandatory_inputs(self, tmp_path):
        with pytest.raises(subprocess.CalledProcessError) as failure:
            _helm_platform(tmp_path, {"platformApi": {"authz": {"config": ""}}})
        assert "platformApi.authz.config is required" in failure.value.stderr


class TestRuntimeIdentityDelivery:
    def test_runtime_complete_bundle(self, tmp_path, monkeypatch):
        monkeypatch.delenv("BUILD_ID", raising=False)
        values = _authz_values(tmp_path, "ephemeral", {
            "aws": {"account_id": "012345678901", "child_admin_role_name": "platform/Provisioner"},
        }, eph_prefix="authz-test")
        values["global"] = {"aws_account_id": "012345678901", "aws_region": "us-east-1"}
        resources, _ = _helm_platform(tmp_path, values)
        bundle = yaml.safe_load(_resource(resources, "ConfigMap", "authz-config")["data"]["config.yaml"])
        assert bundle["registeredAccounts"] == ["012345678901"]
        _assert_rc_grants(bundle, "012345678901", "platform/Provisioner")
        _assert_bundle_fields(bundle)

    @pytest.mark.parametrize("env", ["ephemeral", "integration", "stage"])
    def test_runtime_delivery(self, tmp_path, env):
        values = _authz_values(tmp_path, env)
        assert set(values["platformApi"]["authz"]) == {"config"}
        assert "ssm:///" not in values["platformApi"]["authz"]["config"]
        values["global"] = {"aws_account_id": "012345678901", "aws_region": "us-east-1"}
        resources, _ = _helm_platform(tmp_path, values)
        config = _resource(resources, "ConfigMap", "authz-config")["data"]["config.yaml"]
        assert config == values["platformApi"]["authz"]["config"].replace(
            "@@AWS_ACCOUNT_ID@@", "012345678901",
        ).replace("@@AWS_REGION@@", "us-east-1") + "\n"
        bundle = yaml.safe_load(config)
        assert bundle["registeredAccounts"] == ["012345678901"]
        _assert_rc_grants(bundle, "012345678901", "OrganizationAccountAccessRole" if env == "ephemeral" else "rosa-seaplane-account-admin")
        _assert_bundle_fields(bundle)

    @pytest.mark.parametrize("field,invalid", [
        ("aws_account_id", ""), ("aws_account_id", None),
        ("aws_account_id", "ssm:///account"), ("aws_account_id", "123"),
        ("aws_account_id", "1234567890123"), ("aws_account_id", "１２３４５６７８９０１２"),
        ("aws_account_id", "012345678901\n"), ("aws_account_id", 123456789012),
        ("aws_account_id", True), ("aws_account_id", ["012345678901"]),
        ("aws_region", ""), ("aws_region", None), ("aws_region", "bad"),
        ("aws_region", "US-east-1"), ("aws_region", "us-east-1\n"),
        ("aws_region", 123), ("aws_region", ["us-east-1"]),
    ])
    def test_invalid_identity_fails(self, tmp_path, field, invalid):
        values = {"platformApi": {"authz": {"config": "# @@AWS_ACCOUNT_ID@@ @@AWS_REGION@@\n"}}}
        values["global"] = {"aws_account_id": "012345678901", "aws_region": "us-east-1"}
        values["global"][field] = invalid
        with pytest.raises(subprocess.CalledProcessError) as failure:
            _helm_platform(tmp_path, values)
        assert f"global.{field} must be" in failure.value.stderr

    @pytest.mark.parametrize("marker,globals,expected", [
        ("@@AWS_ACCOUNT_ID@@", {"aws_account_id": "012345678901", "aws_region": "bad"}, "012345678901"),
        ("@@AWS_REGION@@", {"aws_account_id": 123, "aws_region": "eu-west-2"}, "eu-west-2"),
    ])
    def test_only_used_identity_validated(self, tmp_path, marker, globals, expected):
        resources, _ = _helm_platform(tmp_path, {
            "global": globals, "platformApi": {"authz": {"config": f"# {marker}\n"}},
        })
        assert _resource(resources, "ConfigMap", "authz-config")["data"]["config.yaml"] == f"# {expected}\n"

    def test_preserves_explicit_records(self, tmp_path):
        bundle = yaml.safe_load(AUTHZ_BUNDLE)
        content = yaml.safe_dump(bundle, default_style='"')
        resources, _ = _helm_platform(tmp_path, {
            "global": {"aws_account_id": "ssm:///account", "aws_region": "invalid"},
            "platformApi": {"authz": {"config": content}},
        })
        actual = _resource(resources, "ConfigMap", "authz-config")["data"]["config.yaml"]
        assert actual == content
        assert yaml.safe_load(actual) == bundle

    @pytest.mark.parametrize("change", ["duplicateAccounts", "duplicatePolicies", "duplicateAttachments", "nullPolicies"])
    def test_preserves_invalid_records(self, tmp_path, change):
        bundle = yaml.safe_load(AUTHZ_BUNDLE)
        if change == "duplicateAccounts":
            bundle["registeredAccounts"] *= 2
        elif change == "duplicatePolicies":
            bundle["policies"] *= 2
        elif change == "duplicateAttachments":
            bundle["attachments"] *= 2
        else:
            bundle["policies"] = None
        content = yaml.safe_dump(bundle, default_style='"')
        resources, _ = _helm_platform(tmp_path, {"platformApi": {"authz": {"config": content}}})
        assert _resource(resources, "ConfigMap", "authz-config")["data"]["config.yaml"] == content

    @pytest.mark.parametrize("content", [
        'formatVersion: 1\nregisteredAccounts: ["@@AWS_ACCOUNT_ID@@"]\nregisteredAccounts: []\n',
        'formatVersion: 1\npolicies:\n  - id: first\n    id: second\n    ownerAccountID: "@@AWS_ACCOUNT_ID@@"\n',
        'formatVersion: 1\npolicies: [\n# @@AWS_ACCOUNT_ID@@ @@AWS_REGION@@\n',
        'formatVersion: 1\n# {{ .Values.global.aws_account_id }}\n# @@AWS_ACCOUNT_ID@@ @@AWS_REGION@@\n',
    ])
    def test_preserves_original_syntax(self, tmp_path, content):
        resources, _ = _helm_platform(tmp_path, {
            "global": {"aws_account_id": "012345678901", "aws_region": "us-east-1"},
            "platformApi": {"authz": {"config": content}},
        })
        actual = _resource(resources, "ConfigMap", "authz-config")["data"]["config.yaml"]
        assert actual == content.replace("@@AWS_ACCOUNT_ID@@", "012345678901").replace("@@AWS_REGION@@", "us-east-1")

    def test_account_changes_checksum(self, tmp_path):
        values = _authz_values(tmp_path, "stage")
        values["global"] = {"aws_account_id": "012345678901", "aws_region": "us-east-1"}
        before, _ = _helm_platform(tmp_path, values)
        values["global"]["aws_account_id"] = "987654321098"
        after, _ = _helm_platform(tmp_path, values)
        annotation = lambda resources: _resource(resources, "Deployment", "platform-api")["spec"]["template"]["metadata"]["annotations"]
        assert annotation(before)["checksum/authz-config"] != annotation(after)["checksum/authz-config"]
        assert annotation(before)["checksum/rate-limits"] == annotation(after)["checksum/rate-limits"]


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
