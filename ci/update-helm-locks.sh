#!/usr/bin/env bash
# Refresh Chart.lock and charts/<name>-<version>.tgz from Chart.yaml.
#
#   make helm-deps
#   make helm-deps CHART=argocd/config/shared/argocd
#
# Needs network. Does not unpack archives. After a Chart.yaml version bump,
# commit the lock and tgz this writes; make check-helm-locks must pass.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v helm >/dev/null 2>&1; then
	echo "helm is required" >&2
	exit 1
fi

yq_bin="${YQ:-yq}"
if ! command -v "$yq_bin" >/dev/null 2>&1 && [[ -x "$root/bin/yq" ]]; then
	yq_bin="$root/bin/yq"
fi
if ! command -v "$yq_bin" >/dev/null 2>&1; then
	echo "yq is required (install via make helm-deps, which fetches ./bin/yq)." >&2
	exit 1
fi

skip_dir() {
	case "$1" in
	*/upstream | */jetstack-chart | */cert-manager/upstream) return 0 ;;
	esac
	return 1
}

has_deps() {
	[[ -n "$("$yq_bin" -r '.dependencies[]? | .name' "$1")" ]]
}

update_one() {
	local dir="$1"
	local chart="$dir/Chart.yaml"
	if [[ ! -f "$chart" ]]; then
		echo "missing $chart" >&2
		return 1
	fi
	if skip_dir "$dir"; then
		return 0
	fi
	if ! has_deps "$chart"; then
		echo "skip $dir (no dependencies)"
		return 0
	fi
	echo "helm dependency update $dir"
	rm -f "$dir"/charts/*.tgz
	helm dependency update "$dir"
}

if [[ -n "${CHART:-}" ]]; then
	dir="${CHART%/}"
	[[ "$dir" == /* ]] || dir="$root/$dir"
	update_one "$dir"
	exit 0
fi

config_dir="$root/argocd/config"
if [[ ! -d "$config_dir" ]]; then
	echo "missing $config_dir" >&2
	exit 1
fi

chart_files="$(find "$config_dir" -name Chart.yaml)"
if [[ -z "$chart_files" ]]; then
	echo "find returned no Chart.yaml under $config_dir" >&2
	exit 1
fi

while IFS= read -r chart; do
	[[ -n "$chart" ]] || continue
	update_one "$(dirname "$chart")"
done <<<"$chart_files"
