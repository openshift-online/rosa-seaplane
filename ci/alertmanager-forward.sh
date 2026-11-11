#!/usr/bin/env bash
# Ephemeral CI: tunnel regional Alertmanager to localhost for e2e-cli silence specs.
#
# Uses scripts/dev/env-common.sh bastion_port_forward (same pattern as dev port-forward).
# Sets ALERTMANAGER_URL (Makefile maps to E2E_ALERTMANAGER_URL for ginkgo).

set -euo pipefail

_AM_CLEANUP_REGISTERED=false
_AM_PRIOR_EXIT_TRAP=""
_AM_CLEANED=false

cleanup_alertmanager_forward() {
  # Idempotent: after-suites.sh stops the tunnel explicitly; the EXIT trap
  # (registered for early exits) then runs again — the guard prevents a
  # repeated remote port-forward kill.
  if [[ "${_AM_CLEANED}" == "true" ]]; then
    return 0
  fi
  _AM_CLEANED=true
  if declare -F bastion_port_forward_cleanup >/dev/null 2>&1; then
    bastion_port_forward_cleanup
  fi
}

_register_am_cleanup_trap() {
  if [[ "${_AM_CLEANUP_REGISTERED}" == "true" ]]; then
    return 0
  fi
  local trap_output
  trap_output="$(trap -p EXIT 2>/dev/null || true)"
  if [[ -n "${trap_output}" ]]; then
    _AM_PRIOR_EXIT_TRAP="${trap_output#trap -- \'}"
    _AM_PRIOR_EXIT_TRAP="${_AM_PRIOR_EXIT_TRAP%\' EXIT}"
  fi
  trap '_am_run_exit_traps' EXIT
  _AM_CLEANUP_REGISTERED=true
}

_am_run_exit_traps() {
  cleanup_alertmanager_forward
  if [[ -n "${_AM_PRIOR_EXIT_TRAP}" ]]; then
    eval "${_AM_PRIOR_EXIT_TRAP}"
  fi
}

# Start bastion + SSM tunnel. Uses CLUSTER_PREFIX (eph-<hash>-) when cluster_id omitted.
start_alertmanager_forward() {
  local cluster_id="${1:-}"
  local local_port="${ALERTMANAGER_LOCAL_PORT:-9093}"
  local remote_port="${ALERTMANAGER_REMOTE_PORT:-9093}"
  local am_url="http://127.0.0.1:${local_port}"

  if [[ -z "${cluster_id}" ]]; then
    [[ -n "${CLUSTER_PREFIX:-}" ]] || {
      echo "ERROR: CLUSTER_PREFIX required to derive ephemeral cluster id" >&2
      return 1
    }
    cluster_id="${CLUSTER_PREFIX}regional"
  fi

  local repo_root script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  # shellcheck source=scripts/dev/env-common.sh
  source "${repo_root}/scripts/dev/env-common.sh"

  _register_am_cleanup_trap

  echo "=== Alertmanager forward: cluster_id=${cluster_id} ==="
  export REPO_ROOT="${repo_root}"
  if ! bastion_port_forward "${cluster_id}" monitoring monitoring-alertmanager 9093 "${remote_port}" "${local_port}"; then
    cleanup_alertmanager_forward
    return 1
  fi

  local i
  for i in $(seq 1 30); do
    if curl -sf --connect-timeout 2 --max-time 5 "${am_url}/-/healthy" >/dev/null; then
      export ALERTMANAGER_URL="${am_url}"
      export E2E_ALERTMANAGER_URL="${am_url}"
      echo "ALERTMANAGER_FORWARD_OK url=${ALERTMANAGER_URL}"
      return 0
    fi
    sleep 1
  done

  echo "ERROR: Alertmanager health check failed at ${am_url}" >&2
  cleanup_alertmanager_forward
  return 1
}
