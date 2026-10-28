#!/bin/bash
# Run e2e API tests from rosa-seaplane-api against the provisioned environment.
#
# API URL resolution (first match wins):
#   1. BASE_URL env var            — set by local wrapper scripts (ephemeral-env.sh, int-env.sh)
#   2. CREDS_DIR/api_url file — Prow-mounted secret for the standing int environment
#   3. SHARED_DIR terraform output — written by ephemeral-provider during CI provisioning

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"

source "${SCRIPT_DIR}/setup-aws-profiles.sh"
# shellcheck source=../scripts/dev/env-common.sh
source "${SCRIPT_DIR}/../scripts/dev/env-common.sh"
write_e2e_host_aws_config

if [[ -n "${BASE_URL:-}" ]]; then
  echo "Using BASE_URL from environment: ${BASE_URL}"
else
  if [[ -r "${CREDS_DIR}/api_url" ]]; then
    echo "Using API URL from ${CREDS_DIR}/api_url (CI pre-existing environment)"
    BASE_URL="$(cat "${CREDS_DIR}/api_url")"
  else
    echo "No ${CREDS_DIR}/api_url found, falling back to terraform outputs (ephemeral environment)"
    TF_OUTPUTS="${SHARED_DIR}/regional-terraform-outputs.json"
    if [[ ! -r "${TF_OUTPUTS}" ]]; then
      echo "ERROR: ${TF_OUTPUTS} does not exist or is not readable" >&2
      exit 1
    fi
    BASE_URL="$(jq -r '.api_gateway_invoke_url.value // empty' "${TF_OUTPUTS}")"
    if [[ -z "${BASE_URL}" ]]; then
      echo "ERROR: api_gateway_invoke_url.value not found in ${TF_OUTPUTS}" >&2
      exit 1
    fi
  fi
fi
export BASE_URL
export SEAPLANE_URL="${BASE_URL}"
echo "Running API e2e tests against ${BASE_URL}"

# RHOBS API URL for observability E2E tests (Thanos Query read path).
# The query path is always available — uses the same invoke URL as remote-write.
if [[ -z "${RHOBS_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/rhobs_api_url" ]]; then
    RHOBS_API_URL="$(cat "${CREDS_DIR}/rhobs_api_url")"
  elif [[ -n "${TF_OUTPUTS:-}" && -r "${TF_OUTPUTS:-}" ]]; then
    RHOBS_API_URL="$(jq -r '.rhobs_api_url.value // empty' "${TF_OUTPUTS}")"
  fi
fi
if [[ -n "${RHOBS_API_URL:-}" ]]; then
  export RHOBS_API_URL
  echo "RHOBS API URL: ${RHOBS_API_URL}"
else
  echo "WARNING: RHOBS_API_URL not available — observability tests will be skipped"
fi

# ZOA RC/MC API URLs, consumed further down by the rosa-seaplane-zoa clone
# that runs its own `Label("smoke")` specs (see that repo's test/e2e/). Same
# resolution order as RHOBS_API_URL above; local wrapper scripts
# (ephemeral-env.sh) already export these directly, so this is mainly for
# CI-triggered runs (Prow). ZOA_MC_API_URL is only absent if this environment
# genuinely has no MC (empty provision_mcs) — ephemeral envs provision one
# MC by default, so in the common case both resolve and both get tested.
if [[ -z "${ZOA_RC_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/zoa_rc_api_url" ]]; then
    ZOA_RC_API_URL="$(cat "${CREDS_DIR}/zoa_rc_api_url")"
  elif [[ -n "${TF_OUTPUTS:-}" && -r "${TF_OUTPUTS:-}" ]]; then
    ZOA_RC_API_URL="$(jq -r '.zoa_api_function_url.value // empty' "${TF_OUTPUTS}")"
  fi
fi
if [[ -z "${ZOA_MC_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/zoa_mc_api_url" ]]; then
    ZOA_MC_API_URL="$(cat "${CREDS_DIR}/zoa_mc_api_url")"
  elif [[ -n "${SHARED_DIR:-}" && -r "${SHARED_DIR}/management-terraform-outputs.json" ]]; then
    ZOA_MC_API_URL="$(jq -r '.zoa_api_function_url.value // empty' "${SHARED_DIR}/management-terraform-outputs.json")"
  fi
fi
if [[ -n "${ZOA_RC_API_URL:-}" ]]; then
  export ZOA_RC_API_URL
  echo "ZOA RC API URL: ${ZOA_RC_API_URL}"
else
  echo "ZOA_RC_API_URL not available — ZOA RC tests will target MC only (if available)"
fi
[[ -n "${ZOA_MC_API_URL:-}" ]] && export ZOA_MC_API_URL && echo "ZOA MC API URL: ${ZOA_MC_API_URL}"

# ZOA deployment name for Access e2e (ephemeral: from regional terraform output).
if [[ -z "${ZOA_DEPLOYMENT_NAME:-}" ]]; then
  if [[ -r "${CREDS_DIR}/zoa_deployment_name" ]]; then
    ZOA_DEPLOYMENT_NAME="$(cat "${CREDS_DIR}/zoa_deployment_name")"
  elif [[ -n "${TF_OUTPUTS:-}" && -r "${TF_OUTPUTS:-}" ]]; then
    ZOA_DEPLOYMENT_NAME="$(jq -r '.deployment_name.value // empty' "${TF_OUTPUTS}")"
  fi
fi
if [[ -n "${ZOA_DEPLOYMENT_NAME:-}" ]]; then
  export ZOA_DEPLOYMENT_NAME
  echo "ZOA deployment name: ${ZOA_DEPLOYMENT_NAME}"
fi

# Use the regional account profile for authenticated API calls
export AWS_PROFILE="rrp-rc"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

# Print the real signing principal, not credentials, to diagnose grant mismatches.
echo "Regional API caller (rrp-rc):"
aws sts get-caller-identity --profile rrp-rc --query '{Account:Account,Arn:Arn}' --output json

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export PATH="/usr/local/sessionmanagerplugin/bin:/usr/bin:/usr/local/bin:${PATH}"

# Compute CLUSTER_PREFIX early so it's available for pre-cleanup hooks (log
# collection while HCPs still exist), not just in the post-test failure handler.
# Callers (e.g. ephemeral-env.sh) may set CLUSTER_PREFIX directly; honour it.
if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
    echo "Using caller-provided CLUSTER_PREFIX=${CLUSTER_PREFIX}"
elif [[ -r "${CREDS_DIR}/api_url" ]]; then
    export CLUSTER_PREFIX=""
elif [[ -n "${BUILD_ID:-}" ]]; then
    _hash="$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-6)" \
        || { echo "WARNING: sha256sum failed — CLUSTER_PREFIX not set"; _hash=""; }
    if [[ -n "$_hash" ]]; then
        export CLUSTER_PREFIX="eph-${_hash}-"
    fi
else
    echo "WARNING: no ${CREDS_DIR}/api_url and BUILD_ID not set — CLUSTER_PREFIX unset, log collection disabled" >&2
fi

E2E_REF="${E2E_REF:-main}"
E2E_REPO="${E2E_REPO:-https://github.com/openshift-online/rosa-seaplane-api.git}"
CLI_REF="${CLI_REF:-main}"
CLI_REPO="${CLI_REPO:-https://github.com/openshift-online/rosa-seaplane-cli.git}"
ROSA_REPO_URL="${ROSA_REPO_URL:-https://github.com/openshift/rosa}"
ROSA_REPO_BRANCH="${ROSA_REPO_BRANCH:-seaplane-v2}"
ROSA_LABEL_FILTER="${ROSA_LABEL_FILTER:-seaplane-sanity}"
ROSA_TEST_PROFILE="${ROSA_TEST_PROFILE:-rosa-hcp-basic}"
ZOA_REF="${ZOA_REF:-main}"
ZOA_REPO="${ZOA_REPO:-https://github.com/openshift-online/rosa-seaplane-zoa.git}"

E2E_SKIP_PLATFORM_API="${E2E_SKIP_PLATFORM_API:-false}"  # Set to "true" to skip
E2E_SKIP_ZOA="${E2E_SKIP_ZOA:-false}"                    # Set to "true" to skip
E2E_SKIP_HCP="true"
E2E_SKIP_ROSA_CLI="false"
E2E_SKIP_MONITORING="${E2E_SKIP_MONITORING:-false}"      # Set to "true" to skip

# OCP release payload (full pullspec) for HCP creation. Empty lets the e2e /
# operator pick their default; CI sets this to pair the cluster's OCP version
# with the CPO/HO build under test. Consumed by the api repo's test-e2e-cli.
export OCP_IMAGE="${OCP_IMAGE:-}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Print a human-readable summary line for one suite.
# Args: <suite label> <exit code> <skip flag ("true" if skipped)>
print_suite_result() {
    local label="$1" rc="$2" skipped="$3"
    if [[ "$skipped" == "true" ]]; then
        printf '  %-20s SKIPPED\n' "$label"
    elif [[ "$rc" -eq 0 ]]; then
        printf '  %-20s PASS\n' "$label"
    else
        printf '  %-20s FAIL (exit %s)\n' "$label" "$rc"
    fi
}
# ---------------------------------------------------------------------------
# When triggered by a rosa-seaplane-zoa PR, only run ZOA's full e2e suite —
# API, HCP, and monitoring tests are irrelevant for ZOA code changes.
# ---------------------------------------------------------------------------
if [[ "${REPO_NAME:-}" == "rosa-seaplane-zoa" ]]; then
  echo ""
  echo "=== ZOA PR detected — running ZOA full e2e only ==="
  echo ""
  zoa_exit=0
  if [[ -n "${ZOA_RC_API_URL:-}" ]] || [[ -n "${ZOA_MC_API_URL:-}" ]]; then
    if git clone --depth 1 --branch "${ZOA_REF}" "${ZOA_REPO}" "${WORK_DIR}/zoa"; then
      make -C "${WORK_DIR}/zoa" test-e2e || zoa_exit=$?
    else
      echo "ERROR: failed to clone zoa from ${ZOA_REPO}@${ZOA_REF}" >&2
      zoa_exit=1
    fi
  else
    echo "ERROR: neither ZOA_RC_API_URL nor ZOA_MC_API_URL resolved — ZOA e2e tests cannot run" >&2
    zoa_exit=1
  fi
  echo ""
  echo "=== E2E Test Summary ==="
  print_suite_result "ZOA" "$zoa_exit" ""
  echo ""
  if [[ $zoa_exit -ne 0 ]]; then
    echo "Result: FAILED"
  else
    echo "Result: PASSED"
  fi
  exit $zoa_exit
fi

# ---------------------------------------------------------------------------
# Standard flow: API tests + ZOA tests + HCP + monitoring
# ---------------------------------------------------------------------------
echo ""
echo "=== API Tests ==="
echo "===           ==="
echo "Repo: ${E2E_REPO} - Branch: ${E2E_REF}"
echo ""
git clone --depth 1 --branch "${E2E_REF}" \
  "${E2E_REPO}" "${WORK_DIR}/api"
cd "${WORK_DIR}/api"

echo "===           ==="
echo "working commit $(git rev-parse HEAD)"

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="$(go env GOPATH)/bin:${PATH}"

platform_rc=0
hcp_rc=0
monitoring_rc=0
rosa_cli_rc=0

if [[ "${E2E_SKIP_PLATFORM_API}" == "true" ]]; then
  echo ""
  echo "=== Platform API Tests ==="
  echo "Skipped (E2E_SKIP_PLATFORM_API=${E2E_SKIP_PLATFORM_API})"
else
  make test-e2e-api || platform_rc=$?
fi

# ZOA e2e coverage: rosa-seaplane-zoa owns its own e2e suite (test/e2e/).
#
# - On seaplane/api PRs (JOB_TYPE=presubmit or unset): smoke (~2min, 6 specs per target)
# - On nightlies (JOB_TYPE=periodic): full deep suite (~5min with parallel RC+MC)
#
# Both test-e2e and test-e2e-smoke auto-parallelize RC and MC when both URLs
# are set. The test suite handles AWS_PROFILE switching per-subprocess (rrp-rc
# for RC, rrp-mc for MC) — both profiles must exist in AWS_CONFIG_FILE.
#
# Runs if at least one of ZOA_RC_API_URL or ZOA_MC_API_URL is available — the
# Makefile handles missing URLs gracefully (tests only the available targets).
#
# Same "capture the exit code, don't abort" pattern used for platform_rc/
# hcp_rc/monitoring_rc: a zoa failure does NOT stop this script or skip the
# platform API / HCP / monitoring tests, but DOES fail the overall job.
zoa_exit=0
if [[ "${E2E_SKIP_ZOA}" == "true" ]]; then
  echo ""
  echo "=== ZOA Tests ==="
  echo "Skipped (E2E_SKIP_ZOA=${E2E_SKIP_ZOA})"
else
  if [[ -n "${ZOA_RC_API_URL:-}" ]] || [[ -n "${ZOA_MC_API_URL:-}" ]]; then
    if git clone --depth 1 --branch "${ZOA_REF}" "${ZOA_REPO}" "${WORK_DIR}/zoa"; then
      if [[ "${JOB_TYPE:-}" == "periodic" ]]; then
        echo "Nightly run — executing full ZOA e2e suite"
        make -C "${WORK_DIR}/zoa" test-e2e || zoa_exit=$?
      else
        make -C "${WORK_DIR}/zoa" test-e2e-smoke || zoa_exit=$?
      fi
    else
      echo "WARNING: failed to clone zoa from ${ZOA_REPO}@${ZOA_REF} — ZOA e2e tests skipped" >&2
      zoa_exit=1
    fi
  else
    echo "ERROR: neither ZOA_RC_API_URL nor ZOA_MC_API_URL resolved — ZOA e2e tests cannot run" >&2
    zoa_exit=1
  fi
fi

# Get regional account ID for CLI tests
if [[ -z "${E2E_ACCOUNT_ID:-}" ]]; then
  export E2E_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  echo "Regional account ID: ${E2E_ACCOUNT_ID}"
fi

# --- HCP Creation E2E Tests ---
# Customer credentials are supplied via the rrp-customer AWS profile (CUSTOMER_AWS_PROFILE).
# Subprocesses use credential_process auto-refresh, avoiding the 15-minute STS TTL cliff.
# Only run if the platform API tests passed.
_have_customer_creds=false
if [[ $platform_rc -ne 0 ]]; then
  echo "Skipping HCP creation & Platform Monitoring tests — platform API tests failed (exit code: $platform_rc)"
elif aws configure export-credentials --profile rrp-customer --format process &>/dev/null; then
  export CUSTOMER_AWS_PROFILE="rrp-customer"
  echo "Customer profile rrp-customer is available"
  echo "Customer API caller (rrp-customer):"
  aws sts get-caller-identity --profile rrp-customer --query '{Account:Account,Arn:Arn}' --output json

  if [[ -z "${E2E_CUSTOMER_ACCOUNT_ID:-}" ]]; then
    export E2E_CUSTOMER_ACCOUNT_ID="$(aws sts get-caller-identity --profile rrp-customer --query Account --output text)"
    echo "Customer account ID: ${E2E_CUSTOMER_ACCOUNT_ID:0:8}..."
  fi
  _have_customer_creds=true
else
  echo "WARNING: No rrp-customer profile available — skipping HCP creation tests"
fi

if [[ "$_have_customer_creds" == "true" ]]; then
  test_hcp_creation() {
    echo ""
    echo "=== HCP Creation Tests ==="

    local HCP_CLUSTER_NAME="e2e-$(date +%s)"

    CLI_WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "${CLI_WORK_DIR}"; rm -rf "${WORK_DIR}"' EXIT
    cd "${CLI_WORK_DIR}"

    git clone --depth 1 --branch "${CLI_REF}" \
      "${CLI_REPO}" "${CLI_WORK_DIR}/cli"
    cd "${CLI_WORK_DIR}/cli"

    export GOTOOLCHAIN=auto
    make build
    chmod 755 ./bin/rosactl

    export ROSACTL_BIN="${CLI_WORK_DIR}/cli/bin/rosactl"

    cd "${WORK_DIR}/api"

    "${ROSACTL_BIN}" login --url "${BASE_URL}"
    echo "Creating HCP cluster: ${HCP_CLUSTER_NAME}"

    # Collect cluster logs before HCP cleanup so the HCP namespace is captured.
    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        export PRE_CLEANUP_HOOK="S3_ONLY=true ${REPO_ROOT}/scripts/dev/dump-env.sh"
    fi

    export GINKGO_NO_COLOR=TRUE
    if [[ -n "${E2E_SKIP_CLEANUP:-}" ]]; then
      echo "E2E_SKIP_CLEANUP is set — cleanup specs will be skipped"
      export E2E_LABEL_FILTER='!cleanup'
    fi

    # Opt-in silence e2e: tunnel regional Alertmanager for ephemeral CI unless caller
    # already set ALERTMANAGER_URL / E2E_ALERTMANAGER_URL (local dev wrappers).
    if [[ "${E2E_SKIP_ALERTMANAGER_FORWARD:-}" != "true" ]]; then
      if [[ -z "${ALERTMANAGER_URL:-}" && -z "${E2E_ALERTMANAGER_URL:-}" && -n "${CLUSTER_PREFIX:-}" ]]; then
        echo "=== Alertmanager tunnel for silence e2e specs ==="
        # shellcheck source=ci/alertmanager-forward.sh
        if source "${REPO_ROOT}/ci/alertmanager-forward.sh" && start_alertmanager_forward; then
          echo "Silence e2e specs enabled (E2E_ALERTMANAGER_URL=${E2E_ALERTMANAGER_URL})"
        else
          echo "WARNING: Alertmanager tunnel failed — silence-installing/silence-ready specs will skip" >&2
        fi
      fi
    fi

    make test-e2e-cli || return $?

    echo "HCP creation test completed for: ${HCP_CLUSTER_NAME}"
  }

  if [[ "${E2E_SKIP_HCP}" == "true" ]]; then
    echo ""
    echo "=== HCP Creation Tests ==="
    echo "Skipped (E2E_SKIP_HCP=${E2E_SKIP_HCP})"
  else
    test_hcp_creation || hcp_rc=$?
  fi

  if [[ "${E2E_SKIP_ROSA_CLI}" == "false" ]] || [[ -z "${E2E_SKIP_ROSA_CLI:-}" ]]; then
    echo ""
    echo "=== ROSA CLI Tests ==="
    echo ""
    export ROSA_REPO_URL ROSA_REPO_BRANCH TEST_PROFILE="${ROSA_TEST_PROFILE}"
    export GOTOOLCHAIN=auto
    echo "ROSA_LABEL_FILTER: ${ROSA_LABEL_FILTER}"
    # Register the customer account as the RC account. "privileged" is for the legacy
    # accounts API; the Cedar allowlist ignores it.
    if AWS_PROFILE=rrp-rc awscurl --service execute-api --region "${AWS_DEFAULT_REGION}" --fail-with-body \
      -X POST -H "Content-Type: application/json" \
      -d "{\"accountId\":\"${E2E_CUSTOMER_ACCOUNT_ID}\",\"privileged\":true}" \
      "${BASE_URL}/api/v0/accounts"; then
      AWS_PROFILE="${CUSTOMER_AWS_PROFILE}" ROSA_LABEL_FILTER="${ROSA_LABEL_FILTER}" make test-e2e-rosa-cli || rosa_cli_rc=$?
    else
      echo "ERROR: allowlisting customer account failed" >&2
      rosa_cli_rc=1
    fi
  else
    echo ""
    echo "=== ROSA CLI Tests ==="
    echo "Skipped (E2E_SKIP_ROSA_CLI=${E2E_SKIP_ROSA_CLI})"
  fi

  if [[ "${E2E_SKIP_MONITORING}" == "true" ]]; then
    echo ""
    echo "=== Platform Monitoring Tests ==="
    echo "Skipped (E2E_SKIP_MONITORING=${E2E_SKIP_MONITORING})"
  else
    echo ""
    echo "=== Platform Monitoring Tests ==="
    echo ""
    make test-e2e-platform-monitoring || monitoring_rc=$?
  fi
fi

# HCP test failures collect logs via PRE_CLEANUP_HOOK in the test's DeferCleanup
# (before HCP deletion). Only collect here for non-HCP failures.
if [[ $platform_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]] || [[ $rosa_cli_rc -ne 0 ]] || [[ $zoa_exit -ne 0 ]]; then
    # Logs are left in S3 rather than added to public CI artifacts because
    # they may contain sensitive data that cannot be reliably redacted.
    # The S3 URIs are printed below for manual retrieval.
    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        S3_ONLY=true \
            "${REPO_ROOT}/scripts/dev/dump-env.sh" || true
    fi
fi

echo ""
echo "=== E2E Test Summary ==="
print_suite_result "Platform API"       "$platform_rc"  "$([[ "${E2E_SKIP_PLATFORM_API}" == "true" ]] && echo true)"
print_suite_result "HCP Creation"       "$hcp_rc"       "$([[ "${E2E_SKIP_HCP}" == "true" ]] && echo true)"
print_suite_result "ROSA CLI"           "$rosa_cli_rc"  "$([[ "${E2E_SKIP_ROSA_CLI}" != "false" ]] && echo true)"
print_suite_result "Platform Monitoring" "$monitoring_rc" "$([[ "${E2E_SKIP_MONITORING}" == "true" ]] && echo true)"
print_suite_result "ZOA"                "$zoa_exit"     "$([[ "${E2E_SKIP_ZOA}" == "true" ]] && echo true)"

if [[ $platform_rc -ne 0 ]] || [[ $hcp_rc -ne 0 ]] || [[ $monitoring_rc -ne 0 ]] || [[ $rosa_cli_rc -ne 0 ]] || [[ $zoa_exit -ne 0 ]]; then
    echo ""
    echo "Result: FAILED"
    exit 1
fi
echo ""
echo "Result: PASSED"