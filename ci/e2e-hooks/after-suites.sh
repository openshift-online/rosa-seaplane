#!/usr/bin/env bash
# =============================================================================
# after-suites.sh — platform teardown hook for the rosa-hyperfleet parallel
# e2e runner (ROSAENG-75287).
#
# SOURCED by the runner once, after all suites have finished. Must NOT:
#   - change shell options, exit the shell, or fail the job on its own
#   - print secrets
#
# Contract:
#   Inputs (in the environment when sourced):
#     E2E_OVERALL_RESULT  "pass" | "fail" (set by the runner; defaults to fail
#                          so a misconfigured runner never skips the dump)
#     plus the state exported by before-suites.sh:
#       _E2E_HOOKS_AM_STARTED, CLUSTER_PREFIX, E2E_DUMP_ENV, REPO_ROOT
#
# Behaviour:
#   - On failure: run the env dump (S3 only) once, on top of any per-suite
#     pre-cleanup dumps suites took themselves. dump-env.sh keys are unique
#     per invocation, so parallel dumps never overwrite each other.
#   - Stop the Alertmanager tunnel if before-suites.sh started it.
# =============================================================================

# --- Final env dump on failure (best-effort, never fails the job) -------------
if [[ "${E2E_OVERALL_RESULT:-fail}" != "pass" ]]; then
  echo "after-suites: one or more suites failed — collecting environment logs"
  if [[ -n "${CLUSTER_PREFIX+set}" && -n "${E2E_DUMP_ENV:-}" ]]; then
    # shellcheck disable=SC2086 — E2E_DUMP_ENV is an intentional word-split command
    if ! ${E2E_DUMP_ENV}; then
      echo "WARNING: final env dump failed (see errors above)" >&2
    fi
  else
    echo "WARNING: CLUSTER_PREFIX/E2E_DUMP_ENV unavailable — final env dump skipped" >&2
  fi
else
  echo "after-suites: all suites passed — no env dump"
fi

# --- Alertmanager tunnel teardown ---------------------------------------------
if [[ "${_E2E_HOOKS_AM_STARTED:-false}" == "true" ]]; then
  echo "after-suites: stopping Alertmanager tunnel"
  if declare -F cleanup_alertmanager_forward >/dev/null 2>&1; then
    cleanup_alertmanager_forward || echo "WARNING: Alertmanager tunnel cleanup failed" >&2
  else
    echo "WARNING: cleanup_alertmanager_forward not found — tunnel left to pod teardown" >&2
  fi
fi

echo "after-suites: platform teardown complete"
