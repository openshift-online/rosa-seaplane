#!/usr/bin/env bash
# Fail if a wrapper chart declares dependencies but has no Chart.lock or
# vendored charts/*.tgz. Offline / hermetic — does not fetch.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

while IFS= read -r chart; do
	dir="$(dirname "$chart")"
	case "$dir" in
	*/upstream | */jetstack-chart | */cert-manager/upstream) continue ;;
	esac
	if ! grep -q '^dependencies:' "$chart"; then
		continue
	fi
	if [[ ! -f "$dir/Chart.lock" ]]; then
		echo "missing Chart.lock: $dir"
		fail=1
	fi
	shopt -s nullglob
	tgz=("$dir"/charts/*.tgz)
	shopt -u nullglob
	if ((${#tgz[@]} == 0)); then
		echo "missing charts/*.tgz: $dir"
		fail=1
	fi
done < <(find "$root/argocd/config" -name Chart.yaml)

if ((fail)); then
	echo "Helm deps must be vendored (Chart.lock + charts/*.tgz). Run: helm dependency update <chart>"
	exit 1
fi
echo "Helm Chart.lock and vendored tgz present."
