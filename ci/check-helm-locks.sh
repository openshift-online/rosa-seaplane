#!/usr/bin/env bash
# Fail if a wrapper chart's Chart.lock is missing/stale vs Chart.yaml
# (name, version, and repository), a vendored archive is missing, or there
# are extra archives/unpacked subcharts. Git-sourced archives are checked
# against Chart.sources.yaml and Chart.sources.sha256. Offline / hermetic.
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

# Keep Prow output stable, and let pipefail surface find/sort errors.
chart_files="$(find "$config_dir" -name Chart.yaml | sort)"
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
chart_fail=0
chart_skip=0

mark_failure() {
	fail=1
	chart_fail=1
}

report_chart() {
	if ((chart_fail)); then
		printf 'FAIL: %s\n' "$1"
	elif ((chart_skip)); then
		printf 'SKIP: %s (inline chart; Chart.lock not required)\n' "$1"
	else
		printf 'OK: %s\n' "$1"
	fi
}

# charts/ may only contain locked <name>-<version>.tgz. Helm also loads
# unpacked directories, so leftover dirs are undeclared subcharts.
reject_unexpected() {
	local dir="$1"
	local expected="$2"
	local path base
	shopt -s nullglob
	for path in "$dir"/charts/*; do
		base="$(basename "$path")"
		if [[ -d "$path" ]]; then
			echo "unexpected unpacked subchart $path (vendor the tgz only)"
			mark_failure
		elif [[ "$base" == *.tgz ]]; then
			if ! grep -Fxq -- "$base" <<<"$expected"; then
				echo "unexpected archive $path (not in Chart.lock)"
				mark_failure
			fi
		else
			echo "unexpected file $path (charts/ may only contain locked tgz)"
			mark_failure
		fi
	done
	shopt -u nullglob
}

check_git_sources() {
	local dir="$1"
	local chart="$dir/Chart.yaml"
	local sources="$dir/Chart.sources.yaml"
	local checksums="$dir/Chart.sources.sha256"
	local dependency_count source_count i name repository dependency_repository revision chart_path version archive archive_name chart_name chart_version expected_sha checksum_entries actual_sha checksum_count
	if [[ ! -f "$sources" ]]; then
		local git_dependencies
		git_dependencies="$("$yq_bin" -r '.dependencies[]? | select((.repository // "") | test("^git[+]")) | .name' "$chart")"
		if [[ -n "$git_dependencies" ]]; then
			echo "missing Git source manifest $sources for dependencies: $(tr '\n' ' ' <<<"$git_dependencies")"
			mark_failure
		fi
		return 0
	fi

	dependency_count="$("$yq_bin" -r '.dependencies | length' "$chart")"
	source_count="$("$yq_bin" -r '.sources | length' "$sources")"
	if [[ "$dependency_count" != "$source_count" ]]; then
		echo "Chart.sources.yaml must pin every dependency in $dir"
		mark_failure
		return
	fi
	if [[ ! -f "$checksums" ]]; then
		echo "missing Git-vendor checksum file $checksums"
		mark_failure
		return
	fi

	for ((i = 0; i < source_count; i++)); do
		name="$("$yq_bin" -r ".sources[$i].name" "$sources")"
		repository="$("$yq_bin" -r ".sources[$i].repository" "$sources")"
		dependency_repository="$(SOURCE_NAME="$name" "$yq_bin" -r '.dependencies[] | select(.name == strenv(SOURCE_NAME)) | .repository' "$chart")"
		revision="$("$yq_bin" -r ".sources[$i].revision" "$sources")"
		chart_path="$("$yq_bin" -r ".sources[$i].chartPath" "$sources")"
		version="$(SOURCE_NAME="$name" "$yq_bin" -r '.dependencies[] | select(.name == strenv(SOURCE_NAME)) | .version' "$chart")"
		archive_name="$name-$version.tgz"
		archive="$dir/charts/$archive_name"

		if [[ -z "$version" || "$version" == "null" ]]; then
			echo "Git source $name in $sources has no matching Chart.yaml dependency"
			mark_failure
			continue
		fi
		if [[ "$dependency_repository" != "git+$repository" ]]; then
			echo "Chart.yaml Git source marker does not match $sources for $name"
			mark_failure
		fi
		if [[ ! "$repository" =~ ^https://.+\.git$ || ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
			echo "invalid Git source URL or full commit SHA for $name in $sources"
			mark_failure
			continue
		fi
		case "$chart_path" in
			""|/*|../*|*/../*|*/..)
				echo "invalid chartPath for $name in $sources: $chart_path"
				mark_failure
				continue
			;;
		esac
		if [[ ! -f "$archive" ]]; then
			echo "missing Git-vendored archive $archive"
			mark_failure
			continue
		fi
		checksum_entries="$(awk -v path="charts/$archive_name" '$2 == path { count++ } END { print count + 0 }' "$checksums")"
		expected_sha="$(awk -v path="charts/$archive_name" '$2 == path { print $1 }' "$checksums")"
		if [[ "$checksum_entries" != "1" || ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
			echo "missing or duplicate canonical-tar checksum for $archive in $checksums"
			mark_failure
			continue
		fi
		if ! actual_sha="$(gzip -dc "$archive" 2>/dev/null | sha256sum | awk '{print $1}')"; then
			echo "invalid gzip chart archive $archive"
			mark_failure
			continue
		fi
		if [[ "$actual_sha" != "$expected_sha" ]]; then
			echo "Git-vendored chart content checksum mismatch for $archive"
			mark_failure
		fi

		chart_name="$(tar -xOzf "$archive" "$name/Chart.yaml" | "$yq_bin" -r '.name')"
		chart_version="$(tar -xOzf "$archive" "$name/Chart.yaml" | "$yq_bin" -r '.version')"
		if [[ "$chart_name" != "$name" || "$chart_version" != "$version" ]]; then
			echo "Git-vendored chart metadata mismatch for $archive: got $chart_name@$chart_version"
			mark_failure
		fi
		done
	checksum_count="$(awk '$1 !~ /^#/ && NF == 2 { count++ } END { print count + 0 }' "$checksums")"
	if [[ "$checksum_count" != "$source_count" ]]; then
		echo "expected $source_count canonical-tar checksums in $checksums, found $checksum_count"
		mark_failure
	fi
}

while IFS= read -r chart; do
	[[ -n "$chart" ]] || continue
	dir="$(dirname "$chart")"
	display_chart="${chart#"$root"/}"
	chart_fail=0
	chart_skip=0
	yaml_deps="$(dep_ids "$chart")"
	if [[ -z "$yaml_deps" ]]; then
		chart_skip=1
		# Last dependency removed: still reject leftover lock + charts/.
		if [[ -f "$dir/Chart.lock" ]]; then
			lock_deps="$(dep_ids "$dir/Chart.lock")"
			if [[ -n "$lock_deps" ]]; then
				echo "Chart.lock is stale vs Chart.yaml: $dir"
				echo "  Chart.yaml has no dependencies"
				echo "  Chart.lock:"
				echo "$lock_deps" | sed 's/^/    /'
				mark_failure
			fi
		fi
		reject_unexpected "$dir" ""
		report_chart "$display_chart"
		continue
	fi
	if [[ ! -f "$dir/Chart.lock" ]]; then
		echo "missing Chart.lock: $dir"
		mark_failure
		report_chart "$display_chart"
		continue
	fi
	lock_deps="$(dep_ids "$dir/Chart.lock")"
	if [[ "$yaml_deps" != "$lock_deps" ]]; then
		echo "Chart.lock is stale vs Chart.yaml: $dir"
		echo "  Chart.yaml:"
		echo "$yaml_deps" | sed 's/^/    /'
		echo "  Chart.lock:"
		echo "$lock_deps" | sed 's/^/    /'
		mark_failure
	fi

	expected=""
	while IFS='|' read -r name version _repository; do
		[[ -n "$name" ]] || continue
		archive="$dir/charts/${name}-${version}.tgz"
		expected="${expected}${name}-${version}.tgz"$'\n'
		if [[ ! -f "$archive" ]]; then
			echo "missing $archive"
			mark_failure
		fi
	done <<<"$lock_deps"

	reject_unexpected "$dir" "$expected"
	check_git_sources "$dir"
	report_chart "$display_chart"
done <<<"$chart_files"

if ((fail)); then
	echo "Helm deps must be vendored (matching Chart.lock + charts/<name>-<version>.tgz). Run: make helm-deps"
	exit 1
fi
echo "All Helm Chart.lock checks passed."
