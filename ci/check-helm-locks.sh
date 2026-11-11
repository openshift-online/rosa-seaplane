#!/usr/bin/env bash
# Fail if a wrapper chart's Chart.lock is missing, stale vs Chart.yaml
# (name, version, and repository), missing a vendored
# charts/<name>-<version>.tgz, or has extra archives that are not locked.
# Offline / hermetic — does not fetch.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
yq_bin="${YQ:-yq}"
if ! command -v "$yq_bin" >/dev/null 2>&1 && [[ -x "$root/bin/yq" ]]; then
	yq_bin="$root/bin/yq"
fi
if ! command -v "$yq_bin" >/dev/null 2>&1; then
	echo "yq is required (install via make check-helm-locks, which fetches ./bin/yq)." >&2
	exit 1
fi

config_dir="$root/argocd/config"
if [[ ! -d "$config_dir" ]]; then
	echo "missing $config_dir" >&2
	exit 1
fi

# Command substitution fails the script under set -e if find fails.
chart_files="$(find "$config_dir" -name Chart.yaml)"
if [[ -z "$chart_files" ]]; then
	echo "find returned no Chart.yaml under $config_dir" >&2
	exit 1
fi

# Pipe delimiter: CI yq v4.44 treats "\t" as the two characters backslash+t.
# Include repository so a Chart.yaml repo change cannot keep a stale lock.
dep_ids() {
	"$yq_bin" -r '.dependencies[]? | .name + "|" + (.version | tostring) + "|" + .repository' "$1" | sort
}

fail=0
while IFS= read -r chart; do
	[[ -n "$chart" ]] || continue
	dir="$(dirname "$chart")"
	case "$dir" in
	*/upstream | */jetstack-chart | */cert-manager/upstream) continue ;;
	esac
	yaml_deps="$(dep_ids "$chart")"
	if [[ -z "$yaml_deps" ]]; then
		continue
	fi
	if [[ ! -f "$dir/Chart.lock" ]]; then
		echo "missing Chart.lock: $dir"
		fail=1
		continue
	fi
	lock_deps="$(dep_ids "$dir/Chart.lock")"
	if [[ "$yaml_deps" != "$lock_deps" ]]; then
		echo "Chart.lock is stale vs Chart.yaml: $dir"
		echo "  Chart.yaml:"
		echo "$yaml_deps" | sed 's/^/    /'
		echo "  Chart.lock:"
		echo "$lock_deps" | sed 's/^/    /'
		fail=1
	fi

	expected=""
	while IFS='|' read -r name version _repository; do
		[[ -n "$name" ]] || continue
		archive="$dir/charts/${name}-${version}.tgz"
		expected="${expected}${name}-${version}.tgz"$'\n'
		if [[ ! -f "$archive" ]]; then
			echo "missing $archive"
			fail=1
		fi
	done <<<"$lock_deps"

	shopt -s nullglob
	for archive in "$dir"/charts/*.tgz; do
		base="$(basename "$archive")"
		if ! grep -Fxq -- "$base" <<<"$expected"; then
			echo "unexpected archive $archive (not in Chart.lock)"
			fail=1
		fi
	done
	shopt -u nullglob
done <<<"$chart_files"

if ((fail)); then
	echo "Helm deps must be vendored (matching Chart.lock + charts/<name>-<version>.tgz). Run: helm dependency update <chart>"
	exit 1
fi
echo "Helm Chart.lock matches Chart.yaml and vendored tgz are present."
