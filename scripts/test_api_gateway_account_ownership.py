#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "pytest>=8.0",
#     "PyYAML>=6.0",
# ]
# ///
"""Unit tests for API Gateway account-level ownership in the regional cluster.

AWS stores one API Gateway `cloudwatchRoleArn` per account and region, shared by
every REST API in the account. It is owned by a single account-level
provisioning step with a lifetime longer than any cluster; this repository
consumes it. These tests pin the two halves of that, offline:

  * the cluster module owns no account-level resource and has no way to take
    ownership back, and
  * the handover deletes nothing — `removed` blocks on apply, plus a pre-destroy
    detach for states destroyed before they apply, because `terraform destroy`
    ignores `removed` blocks.
"""

import json
import os
import re
import subprocess
from fnmatch import fnmatch
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
LIB = REPO_ROOT / "scripts" / "pipeline-common" / "lib.sh"
TERRAFORM_LIB = REPO_ROOT / "scripts" / "pipeline-common" / "terraform-lib.sh"
RC_CONFIG = REPO_ROOT / "terraform" / "config" / "regional-cluster"
PRE_DESTROY = RC_CONFIG / "pre-destroy.sh"
IMPORTS = RC_CONFIG / "imports.sh"
API_GATEWAY_MODULE = REPO_ROOT / "terraform" / "modules" / "api-gateway"
RHOBS_MODULE = REPO_ROOT / "terraform" / "modules" / "rhobs-api-gateway"

# The account-level addresses this module used to own and has handed back.
RELINQUISHED_ADDRESSES = [
    "aws_api_gateway_account.main",
    "aws_iam_role_policy_attachment.api_gateway_cloudwatch",
    "aws_iam_role.api_gateway_cloudwatch",
]

# Resource types that would make this module an owner of the account setting.
ACCOUNT_LEVEL_TYPES = ("aws_api_gateway_account",)

STUB_TERRAFORM = """#!/usr/bin/env bash
# Stub terraform. Records every invocation and fakes `state list` / `state rm`
# against a line-per-address file.
printf '%s\\n' "$*" >> "$FAKE_LOG"

if [ "$1" = "state" ] && [ "$2" = "list" ]; then
    [ "${FAKE_STATE_LIST_FAILS:-0}" = "1" ] && { echo "no state" >&2; exit 1; }
    cat "$FAKE_STATE"
    exit 0
fi

if [ "$1" = "state" ] && [ "$2" = "rm" ]; then
    [ "${FAKE_STATE_RM_FAILS:-0}" = "1" ] && { echo "cannot remove" >&2; exit 1; }
    # FAKE_STATE_RM_NOOP: exits 0 but leaves the address managed.
    [ "${FAKE_STATE_RM_NOOP:-0}" = "1" ] && exit 0
    grep -Fxv -- "$3" "$FAKE_STATE" > "$FAKE_STATE.tmp" || true
    mv "$FAKE_STATE.tmp" "$FAKE_STATE"
    exit 0
fi

exit 0
"""


def _module_text(module):
    return "\n".join(path.read_text() for path in sorted(module.glob("*.tf")))


def _hcl_resource_blocks(text):
    """Map "<type>.<name>" to the body of each top-level resource block."""
    starts = [
        (match, match.start())
        for match in re.finditer(
            r'^resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', text, re.MULTILINE
        )
    ]
    blocks = {}
    for index, (match, start) in enumerate(starts):
        end = starts[index + 1][1] if index + 1 < len(starts) else len(text)
        blocks[f"{match.group(1)}.{match.group(2)}"] = text[start:end]
    return blocks


@pytest.fixture(scope="module")
def api_gateway_module():
    return _module_text(API_GATEWAY_MODULE)


# ---------------------------------------------------------------------------
# Single owner: the cluster module must not own the account-level resources
# ---------------------------------------------------------------------------


def test_module_declares_no_account_level_resource(api_gateway_module):
    """One owner per AWS account and region, and it is not this module."""
    declared = set(_hcl_resource_blocks(api_gateway_module))
    for resource_type in ACCOUNT_LEVEL_TYPES:
        assert not [a for a in declared if a.startswith(f"{resource_type}.")], resource_type
    assert not [
        address
        for address, body in _hcl_resource_blocks(api_gateway_module).items()
        if address.startswith("aws_iam_role")
        and "apigateway.amazonaws.com" in body
    ], "the logging role is account-level and must not be created per cluster"


def test_rhobs_module_also_declares_no_account_level_resource():
    """The RHOBS gateway shares the same account setting; it must not own it either."""
    declared = _hcl_resource_blocks(_module_text(RHOBS_MODULE))
    for resource_type in ACCOUNT_LEVEL_TYPES:
        assert not [a for a in declared if a.startswith(f"{resource_type}.")], resource_type


def test_module_cannot_take_ownership_back(api_gateway_module):
    """No adoption, import or create-if-absent path may reappear, in the module
    or in the root configuration that instantiates it."""
    pipeline_imports = IMPORTS.read_text()
    for address in RELINQUISHED_ADDRESSES:
        assert address not in pipeline_imports, address
    assert "aws_api_gateway_account" not in pipeline_imports

    hcl = api_gateway_module + "\n" + "\n".join(p.read_text() for p in sorted(RC_CONFIG.glob("*.tf")))
    for block in re.finditer(r"^import\s*\{(.*?)\n\}", hcl, re.DOTALL | re.MULTILINE):
        target = re.search(r"to\s*=\s*([^\s]+)", block.group(1))
        assert target, block.group(0)
        assert not any(
            target.group(1).endswith(address) for address in RELINQUISHED_ADDRESSES
        ), f"import block would re-adopt {target.group(1)}"


def test_consumption_is_read_only(api_gateway_module):
    """The module may only read the role, never manage it.

    The check block is advisory: a failed read degrades to a warning. That does
    not make the prerequisite optional — in an account with no logging role at
    all, aws_api_gateway_method_settings still fails at apply — but a warning
    means only that no role of this name could be read; it says nothing about
    the account setting. This asserts the read-only property, nothing more.
    """
    check = re.search(
        r'check\s+"api_gateway_account_logging_role"\s*\{.*?\n\}', api_gateway_module, re.DOTALL
    )
    assert check, "the prerequisite must be reported by a check block"
    body = check.group(0)
    assert 'data "aws_iam_role"' in body, "the role is read, never managed"
    assert "var.cloudwatch_role_name" in body


def _role_name_variable_block():
    variables = (API_GATEWAY_MODULE / "variables.tf").read_text()
    after = variables.split('variable "cloudwatch_role_name"', 1)[1]
    return after.split('\nvariable "', 1)[0]


def _expected_role_name():
    return re.search(r'^\s*default\s*=\s*"([^"]+)"', _role_name_variable_block(), re.MULTILINE).group(1)


def test_role_name_is_account_level_not_cluster_scoped():
    """The name is the contract with whatever provisions the account, so it
    must be one fixed value and must not be set per cluster."""
    assert "var.regional_id" not in _role_name_variable_block()
    main = (RC_CONFIG / "main.tf").read_text()
    instantiation = re.search(
        r'module\s+"api_gateway"\s*\{.*?\n\}', main, re.DOTALL
    ).group(0)
    assert "cloudwatch_role_name" not in instantiation, (
        "the role name must not be overridden per regional cluster"
    )


def test_per_cluster_log_destinations_are_untouched(api_gateway_module):
    """Sharing a delivery role must not share where the logs land."""
    for text, prefix in (
        (api_gateway_module, "/aws/api-gateway/${var.regional_id}/"),
        (_module_text(RHOBS_MODULE), "/aws/api-gateway/${var.regional_id}-rhobs/"),
    ):
        groups = _hcl_resource_blocks(text)["aws_cloudwatch_log_group.api_gateway_access"]
        assert prefix in groups
        assert "access_log_settings" in text
        assert "aws_cloudwatch_log_group.api_gateway_access.arn" in text


# ---------------------------------------------------------------------------
# Handover: nothing may be deleted on the way out
# ---------------------------------------------------------------------------


def _removed_blocks(text):
    return {
        match.group(1): match.group(0)
        for match in re.finditer(
            r"^removed\s*\{\s*\n\s*from\s*=\s*([^\s]+).*?\n\}", text, re.DOTALL | re.MULTILINE
        )
    }


def test_every_relinquished_address_is_handed_back_without_destroying(api_gateway_module):
    blocks = _removed_blocks(api_gateway_module)
    assert set(blocks) == set(RELINQUISHED_ADDRESSES)
    for address, body in blocks.items():
        assert re.search(r"destroy\s*=\s*false", body), address


def test_stage_does_not_depend_on_an_unmanaged_resource(api_gateway_module):
    stage = _hcl_resource_blocks(api_gateway_module)["aws_api_gateway_stage.main"]
    assert "aws_api_gateway_account" not in stage
    assert "aws_cloudwatch_log_group.api_gateway_access" in stage


@pytest.mark.parametrize(
    "config", sorted((REPO_ROOT / "ci" / "janitor").glob("aws-nuke-config*.yaml"))
)
def test_logging_roles_survive_the_nightly_janitor(config):
    """The account-level role, and the per-cluster roles left behind by the
    handover while the live setting may still name one, must not be reaped."""

    def matches(entry, name):
        if isinstance(entry, str):
            return entry == name
        if entry.get("property") not in ("Name", "RoleName"):
            return False
        value, kind = entry.get("value", ""), entry.get("type", "exact")
        if kind == "glob":
            return fnmatch(name, value)
        if kind == "contains":
            return value in name
        return value == name

    parsed = yaml.safe_load(config.read_text())
    accounts = parsed.get("accounts") or {}
    if accounts:
        # Only a preset every account uses protects every account.
        common = set.intersection(*(set(a["presets"]) for a in accounts.values()))
    else:
        common = set(parsed["presets"])  # account-agnostic config

    def filters(resource_type):
        return [
            entry
            for name in common
            for entry in parsed["presets"][name].get("filters", {}).get(resource_type, [])
        ]

    for name in (_expected_role_name(), "eph-deadbeef-regional-api-gateway-cloudwatch"):
        assert any(matches(e, name) for e in filters("IAMRole")), f"{config.name}: {name}"
        assert any(
            matches(e, name) for e in filters("IAMRolePolicyAttachment")
        ), f"{config.name}: {name} attachment"


# ---------------------------------------------------------------------------
# Pre-destroy detach: terraform destroy ignores `removed` blocks
# ---------------------------------------------------------------------------


@pytest.fixture
def shell(tmp_path):
    """Run snippets against the real pipeline libraries and a stub terraform."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "terraform"
    stub.write_text(STUB_TERRAFORM)
    stub.chmod(0o755)

    state = tmp_path / "state.txt"
    log = tmp_path / "terraform.log"
    log.touch()

    def run(snippet, managed=(), **env_overrides):
        state.write_text("".join(f"{address}\n" for address in managed))
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "HOME": str(tmp_path),
            "FAKE_STATE": str(state),
            "FAKE_LOG": str(log),
        }
        env.update({key: str(value) for key, value in env_overrides.items()})
        result = subprocess.run(
            [
                "bash",
                "-c",
                "set -euo pipefail\n"
                + ("" if env.get("_SKIP_LIB") else f"source {LIB}\n")
                + f"source {TERRAFORM_LIB}\n{snippet}\n",
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        result.managed = state.read_text().split()
        # Match the action as a whole argument: the -chdir path embeds the
        # pytest tmp dir, whose name contains the test name.
        result.terraform_actions = [call.split() for call in log.read_text().splitlines()]
        return result

    return run


def _tf_dir(tmp_path):
    tf_dir = tmp_path / "tf"
    tf_dir.mkdir()
    (tf_dir / "pre-destroy.sh").write_text(PRE_DESTROY.read_text())
    return tf_dir


MANAGED = [f"module.api_gateway.{a}" for a in RELINQUISHED_ADDRESSES]


def test_pre_destroy_detaches_exactly_the_relinquished_addresses():
    found = re.findall(
        r"^\s*state_rm_if_present '([^']+)'", PRE_DESTROY.read_text(), re.MULTILINE
    )
    assert found == MANAGED


def test_stale_state_teardown_cannot_reset_the_account_setting(shell, tmp_path):
    """A state provisioned before the handover is destroyed without ever
    applying it; the account-level resources must leave state first."""
    result = shell(
        f"tf_apply '{_tf_dir(tmp_path)}' destroy",
        managed=[*MANAGED, "module.vpc.aws_vpc.main"],
    )
    assert result.returncode == 0, result.stderr + result.stdout
    assert result.managed == ["module.vpc.aws_vpc.main"]
    destroys = [argv for argv in result.terraform_actions if "destroy" in argv]
    assert len(destroys) == 1
    assert result.terraform_actions.index(destroys[0]) == len(result.terraform_actions) - 1


def test_destroy_is_refused_when_an_address_stays_managed(shell, tmp_path):
    result = shell(
        f"tf_apply '{_tf_dir(tmp_path)}' destroy", managed=MANAGED, FAKE_STATE_RM_NOOP=1
    )
    assert result.returncode != 0
    assert "refusing to run terraform destroy" in result.stderr
    assert not any("destroy" in argv for argv in result.terraform_actions)


def test_destroy_is_refused_when_state_cannot_be_read(shell, tmp_path):
    result = shell(
        f"tf_apply '{_tf_dir(tmp_path)}' destroy", managed=MANAGED, FAKE_STATE_LIST_FAILS=1
    )
    assert result.returncode != 0
    assert not any("destroy" in argv for argv in result.terraform_actions)


def test_already_handed_over_state_destroys_normally(shell, tmp_path):
    """After one apply all three addresses are absent; teardown is unchanged."""
    result = shell(
        f"tf_apply '{_tf_dir(tmp_path)}' destroy", managed=["module.vpc.aws_vpc.main"]
    )
    assert result.returncode == 0, result.stderr + result.stdout
    assert "[absent]" in result.stdout
    assert any("destroy" in argv for argv in result.terraform_actions)


def test_destroy_is_refused_when_state_rm_fails(shell, tmp_path):
    result = shell(
        f"tf_apply '{_tf_dir(tmp_path)}' destroy", managed=MANAGED, FAKE_STATE_RM_FAILS=1
    )
    assert result.returncode != 0
    assert not any("destroy" in argv for argv in result.terraform_actions)


def test_destroy_is_refused_when_the_hook_itself_is_broken(shell, tmp_path):
    """A truncated or mis-edited hook must not read as a successful detach."""
    tf_dir = tmp_path / "tf"
    tf_dir.mkdir()
    (tf_dir / "pre-destroy.sh").write_text("state_rm_if_present 'module.api_gateway.\n")
    result = shell(f"tf_apply '{tf_dir}' destroy", managed=MANAGED)
    assert result.returncode != 0
    assert "refusing to run terraform destroy" in result.stderr
    assert not any("destroy" in argv for argv in result.terraform_actions)


def test_destroy_is_refused_when_the_detach_helpers_are_missing(shell, tmp_path):
    """terraform-lib.sh without lib.sh must stop, not skip the detach."""
    tf_dir = _tf_dir(tmp_path)
    result = shell(
        f"tf_apply '{tf_dir}' destroy", managed=MANAGED, _SKIP_LIB="1"
    )
    assert result.returncode != 0
    assert not any("destroy" in argv for argv in result.terraform_actions)
    assert all(a in result.managed for a in MANAGED)


def test_hook_runs_on_destroy_only(shell, tmp_path):
    tf_dir = tmp_path / "tf"
    tf_dir.mkdir()
    (tf_dir / "imports.sh").write_text("echo SOURCED_IMPORTS\n")
    (tf_dir / "pre-destroy.sh").write_text("echo SOURCED_PRE_DESTROY\n")
    result = shell(f"tf_apply '{tf_dir}' apply")
    assert result.returncode == 0, result.stderr
    assert "SOURCED_IMPORTS" in result.stdout
    assert "SOURCED_PRE_DESTROY" not in result.stdout


def test_hook_addresses_match_the_module_instance_name():
    """Renaming the module block would make the hook silently a no-op."""
    main = (RC_CONFIG / "main.tf").read_text()
    block = re.search(
        r'module\s+"([a-z_]+)"\s*\{[^}]*?source\s*=\s*"\.\./\.\./modules/api-gateway"',
        main,
        re.DOTALL,
    )
    assert block, "api-gateway module instance not found in regional-cluster"
    for address in MANAGED:
        assert address.startswith(f"module.{block.group(1)}."), address


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
