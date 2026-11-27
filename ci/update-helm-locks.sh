#!/usr/bin/env bash
# Refresh Chart.lock and charts/<name>-<version>.tgz from Chart.yaml.
# Charts with Chart.sources.yaml are packaged from their pinned Git commits.
#
#   make helm-deps
#   make helm-deps CHART=argocd/config/shared/argocd
#
# Needs network. Git-sourced dependencies are fetched at their pinned commit
# and packaged deterministically without a Helm binary. Other dependencies use
# Helm's normal repository resolver.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

has_deps() {
	local yq_bin="${YQ:-yq}"
	local deps
	if ! command -v "$yq_bin" >/dev/null 2>&1 && [[ -x "$root/bin/yq" ]]; then
		yq_bin="$root/bin/yq"
	fi
	deps="$("$yq_bin" -r '.dependencies[]? | .name' "$1")" || return 2
	[[ -n "$deps" ]]
}

ensure_yq() {
	local yq_bin="${YQ:-yq}"
	if command -v "$yq_bin" >/dev/null 2>&1 || [[ -x "$root/bin/yq" ]]; then
		return 0
	fi
	echo "installing yq for repository-based chart dependencies"
	make "$root/bin/yq"
}

update_one() {
	local dir="$1"
	local chart="$dir/Chart.yaml"
	if [[ ! -f "$chart" ]]; then
		echo "missing $chart" >&2
		return 1
	fi
	if [[ -f "$dir/Chart.sources.yaml" ]]; then
		uv run "$root/ci/vendor-git-helm-chart.py" "$dir"
		return
	fi
	if [[ -f "$dir/Chart.lock" ]] && grep -Eq '^[[:space:]]*repository:[[:space:]]*git\+' "$dir/Chart.lock"; then
		echo "$dir has a git+ Chart.lock dependency but no Chart.sources.yaml" >&2
		return 1
	fi
	ensure_yq
	if has_deps "$chart"; then
		:
	else
		local has_deps_status=$?
		if [[ "$has_deps_status" != "1" ]]; then
			return "$has_deps_status"
		fi
		echo "skip $dir (no dependencies)"
		rm -f "$dir/Chart.lock" "$dir/Chart.sources.sha256" "$dir"/charts/*.tgz
		return 0
	fi
	if ! command -v helm >/dev/null 2>&1; then
		echo "helm is required for non-Git chart dependencies" >&2
		return 1
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
