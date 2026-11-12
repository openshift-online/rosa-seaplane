#!/usr/bin/env bash
# =============================================================================
# before-suites.sh — platform setup hook for the rosa-hyperfleet parallel e2e
# runner (ROSAENG-75287).
#
# SOURCED by the runner before any suite starts. Must NOT:
#   - change shell options (set -e/-u/-x) or install EXIT traps that would
#     affect the runner shell
#   - exit the shell; every block fails soft and reports
#   - print secrets (profile names and account IDs only, never credentials)
#
# Contract:
#   Inputs (already in the environment when sourced):
#     REPO_ROOT        rosa-seaplane checkout root
#     BASE_URL         platform API URL (resolved by rosa-hyperfleet-e2e-env)
#     AWS_REGION       region (default us-east-1)
#     CREDS_DIR        Prow-mounted credentials (default /var/run/rosa-credentials)
#     SHARED_DIR       ephemeral provisioning shared dir (terraform outputs)
#     CLUSTER_PREFIX   optional; computed here for ephemeral runs when unset
#   Outputs (exported for suites):
#     RC_AWS_PROFILE, AWS_DEFAULT_REGION
#     E2E_ACCOUNT_ID, CUSTOMER_AWS_PROFILE, E2E_CUSTOMER_ACCOUNT_ID (optional)
#     E2E_ALERTMANAGER_URL (when the tunnel is up)
#     E2E_DUMP_ENV, PRE_CLEANUP_HOOK (env-dump command for suites/back-compat)
#   State for after-suites.sh (exported, runner-shell local):
#     _E2E_HOOKS_AM_STARTED     "true" when this hook started the tunnel
#     E2E_CUSTOMER_ALLOWLISTED  "true"/"false" — suites that need the customer
#                              account fail fast on false instead of failing
#                              later with an unclear error
#     _E2E_HOOKS_ALLOWLISTED    "true" when the customer account was allowlisted (legacy alias)
#
# Follow-up (not yet implemented): generic cluster access exports
# (E2E_RC_KUBECONFIG, E2E_MC_KUBECONFIG, E2E_PORT_FORWARD). Kubeconfigs carry
# credentials and live only inside the runner pod — never in e2e.env or logs.
# =============================================================================

# --- AWS profiles ------------------------------------------------------------
# rrp-rc (regional), rrp-mc (management), rrp-customer (customer account).
# The sourced script enables `set -euo pipefail`; preserve the runner
# shell's options across the source so a setup failure cannot change or
# exit the runner shell.
_e2e_hooks_prior_opts="$(set +o)"
# Command substitutions do not inherit errexit, so $(set +o) records it as
# OFF even when the caller runs with -e. Capture it separately and restore
# it after the other options, or the hook would disable the caller's -e.
_e2e_hooks_had_errexit=false
[[ $- == *e* ]] && _e2e_hooks_had_errexit=true
# shellcheck source=ci/setup-aws-profiles.sh
if [[ -r "${REPO_ROOT}/ci/setup-aws-profiles.sh" ]]; then
  source "${REPO_ROOT}/ci/setup-aws-profiles.sh" \
    || echo "WARNING: ci/setup-aws-profiles.sh failed — AWS profiles may be incomplete" >&2
else
  echo "WARNING: ${REPO_ROOT}/ci/setup-aws-profiles.sh not found — AWS profiles not set up" >&2
fi
eval "${_e2e_hooks_prior_opts}"
${_e2e_hooks_had_errexit} && set -e || true

# Export named profiles for suites; do NOT set AWS_PROFILE globally — each
# suite's run script sets it explicitly for the credentials it needs.
export RC_AWS_PROFILE="${RC_AWS_PROFILE:-rrp-rc}"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

# Print the signing principal (not credentials) to diagnose grant mismatches.
echo "Regional API caller (${RC_AWS_PROFILE}):"
AWS_PROFILE="${RC_AWS_PROFILE}" aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output json \
  || echo "WARNING: could not resolve signing principal — check AWS profiles/credentials" >&2

# --- Account IDs -------------------------------------------------------------
if [[ -z "${E2E_ACCOUNT_ID:-}" ]]; then
  E2E_ACCOUNT_ID="$(AWS_PROFILE="${RC_AWS_PROFILE}" aws sts get-caller-identity --query Account --output text)" || true
  [[ -n "${E2E_ACCOUNT_ID:-}" ]] && echo "Regional account ID: ${E2E_ACCOUNT_ID}"
fi
export E2E_ACCOUNT_ID

# Customer credentials are optional: suites that need them (rosa-cli, sdk)
# degrade gracefully when absent. Subprocesses use credential_process
# auto-refresh, avoiding the 15-minute STS TTL cliff.
export E2E_CUSTOMER_ALLOWLISTED=false
export _E2E_HOOKS_ALLOWLISTED=false
if aws configure export-credentials --profile rrp-customer --format process &>/dev/null; then
  export CUSTOMER_AWS_PROFILE="rrp-customer"
  echo "Customer profile rrp-customer is available"
  if [[ -z "${E2E_CUSTOMER_ACCOUNT_ID:-}" ]]; then
    E2E_CUSTOMER_ACCOUNT_ID="$(aws sts get-caller-identity --profile rrp-customer --query Account --output text)" || true
    [[ -n "${E2E_CUSTOMER_ACCOUNT_ID:-}" ]] && echo "Customer account ID: ${E2E_CUSTOMER_ACCOUNT_ID:0:8}..."
  fi
  export E2E_CUSTOMER_ACCOUNT_ID

  # --- Customer-account allowlisting (once, before any suite) -----------------
  # Register the customer account as the RC account. "privileged" is for the
  # legacy accounts API; the Cedar allowlist ignores it. Runs once here so
  # concurrent suites never race the registration.
  if [[ -n "${E2E_CUSTOMER_ACCOUNT_ID:-}" && -n "${BASE_URL:-}" ]]; then
    echo "Allowlisting customer account ${E2E_CUSTOMER_ACCOUNT_ID:0:8}..."
    if AWS_PROFILE="${RC_AWS_PROFILE}" awscurl --service execute-api --region "${AWS_DEFAULT_REGION}" --fail-with-body \
      -X POST -H "Content-Type: application/json" \
      -d "{\"accountId\":\"${E2E_CUSTOMER_ACCOUNT_ID}\",\"privileged\":true}" \
      "${BASE_URL}/api/v0/accounts"; then
      export E2E_CUSTOMER_ALLOWLISTED=true
      export _E2E_HOOKS_ALLOWLISTED=true
    else
      echo "ERROR: allowlisting customer account failed — environment not ready" >&2
      return 1
    fi
  fi
else
  echo "No rrp-customer profile available — customer-account suites will be skipped"
fi

# --- Cluster prefix (log collection / cluster-id derivation) ------------------
# Callers may set CLUSTER_PREFIX directly (ephemeral-env.sh, standing envs use
# ""). Ephemeral CI derives eph-<hash>- from BUILD_ID.
if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
  echo "Using caller-provided CLUSTER_PREFIX=${CLUSTER_PREFIX}"
elif [[ -r "${CREDS_DIR:-/var/run/rosa-credentials}/api_url" ]]; then
  export CLUSTER_PREFIX=""
elif [[ -n "${BUILD_ID:-}" ]]; then
  _hash="$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-6)" || _hash=""
  if [[ -n "${_hash}" ]]; then
    export CLUSTER_PREFIX="eph-${_hash}-"
  fi
else
  echo "WARNING: no ${CREDS_DIR:-/var/run/rosa-credentials}/api_url and BUILD_ID not set — CLUSTER_PREFIX unset, log collection disabled" >&2
fi

# --- Alertmanager tunnel (once per runner pod) --------------------------------
# Opt-in silence e2e: tunnel regional Alertmanager unless the caller already
# set ALERTMANAGER_URL / E2E_ALERTMANAGER_URL (local dev wrappers) or disabled
# forwarding via E2E_SKIP_ALERTMANAGER_FORWARD.
export _E2E_HOOKS_AM_STARTED=false
if [[ "${E2E_SKIP_ALERTMANAGER_FORWARD:-}" != "true" ]]; then
  # Note: the -n check means standing environments (CLUSTER_PREFIX="") skip
  # the tunnel — intentional, inherited from ci/e2e-tests.sh: standing envs
  # expose their own Alertmanager; only ephemeral (prefixed) envs need it.
  if [[ -z "${ALERTMANAGER_URL:-}" && -z "${E2E_ALERTMANAGER_URL:-}" && -n "${CLUSTER_PREFIX:-}" ]]; then
    echo "=== Alertmanager tunnel for silence e2e specs ==="
    # The helper enables set -euo pipefail when sourced: save and restore
    # the runner shell's options around the whole tunnel-setup block (with
    # errexit handled separately — command substitutions do not inherit it),
    # so a setup failure cannot change or exit the runner shell.
    _e2e_hooks_am_prior_opts="$(set +o)"
    _e2e_hooks_am_had_errexit=false
    [[ $- == *e* ]] && _e2e_hooks_am_had_errexit=true
    # shellcheck source=ci/alertmanager-forward.sh
    if source "${REPO_ROOT}/ci/alertmanager-forward.sh" && start_alertmanager_forward; then
      export _E2E_HOOKS_AM_STARTED=true
      # The helper installed its own EXIT trap (_am_run_exit_traps), which
      # replaces the runner's. Take ownership back: keep the tunnel cleanup
      # for early exits, but through a hook-owned function that also runs the
      # trap content the runner had before (the helper captured it in
      # _AM_PRIOR_EXIT_TRAP). after-suites.sh stops the tunnel explicitly on
      # the normal path; the cleanup is idempotent, so the EXIT run is a
      # no-op there.
      _e2e_hooks_prior_exit_trap_cmd="${_AM_PRIOR_EXIT_TRAP:-}"
      _e2e_hooks_am_exit() {
        # Preserve the runner's exit status: the cleanup and the prior trap
        # must not clobber $? (a failing cleanup or `|| true` would turn an
        # exit 7 into 0 for the prior trap and the script's final status).
        local rc=$?
        cleanup_alertmanager_forward || true
        if [[ -n "${_e2e_hooks_prior_exit_trap_cmd}" ]]; then
          (exit "${rc}") # restore $? for the prior trap
          eval "${_e2e_hooks_prior_exit_trap_cmd}"
        fi
        (exit "${rc}") # and for the shell's final exit status
        return 0
      }
      trap '_e2e_hooks_am_exit' EXIT
      echo "Silence e2e specs enabled (E2E_ALERTMANAGER_URL=${E2E_ALERTMANAGER_URL})"
    else
      echo "WARNING: Alertmanager tunnel failed — silence-installing/silence-ready specs will skip" >&2
    fi
    eval "${_e2e_hooks_am_prior_opts}"
    ${_e2e_hooks_am_had_errexit} && set -e || true
  fi
fi

# --- Env dump command (parallel-safe) -----------------------------------------
# dump-env.sh derives a unique S3 key per invocation (timestamp-pid-random),
# so per-suite pre-cleanup dumps and the final dump never overwrite each other.
# Logs stay in S3 (S3_ONLY) because they may contain sensitive data that
# cannot be reliably redacted; the S3 URIs are printed for manual retrieval.
# `env` prefixes the assignment so the command works after word-splitting in
# consumers that do not re-parse it (after-suites.sh expands ${E2E_DUMP_ENV}
# directly; the legacy PRE_CLEANUP_HOOK consumer re-parses via bash -c, where
# both forms work).
export E2E_DUMP_ENV="env S3_ONLY=true ${REPO_ROOT}/scripts/dev/dump-env.sh"
# Back-compat alias: suites captured by the old flow read PRE_CLEANUP_HOOK.
export PRE_CLEANUP_HOOK="${E2E_DUMP_ENV}"

echo "before-suites: platform setup complete"
