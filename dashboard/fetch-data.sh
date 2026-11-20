#!/usr/bin/env bash
# Fetches open PRs labelled "ready-for-human-review", "discussion-needed", or "needs-ok-to-test" across all
# ROSA Seaplane repos and writes dashboard/data.json.
#
# Uses `gh pr list` (not `gh search prs`) so we can include reviewRequests.
#
# Requires: gh (authenticated), jq
# Usage:    ./dashboard/fetch-data.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${SCRIPT_DIR}/data.json"

REPOS=(
  openshift-online/rosa-seaplane
  openshift-online/rosa-seaplane-api
  openshift-online/rosa-seaplane-internal
  openshift-online/rosa-seaplane-zoa
  openshift-online/rosa-seaplane-kube-applier
  openshift-online/rosa-seaplane-ecr-creds-sync
  openshift-online/rosa-seaplane-compliance
  openshift-online/aws-nuke-cf
)

JSON_FIELDS="number,title,author,labels,reviewRequests,createdAt,updatedAt,url"

fetch_label() {
  local label="$1"
  local tmp
  tmp=$(mktemp)
  echo '[]' > "$tmp"

  for repo in "${REPOS[@]}"; do
    local result
    result=$(gh pr list --repo "$repo" --label "$label" --state open \
      --limit 100 --json "$JSON_FIELDS" 2>/dev/null) || result='[]'

    # Inject repository.name into each PR (gh pr list doesn't include it)
    local repo_name="${repo#*/}"
    result=$(echo "$result" | jq --arg name "$repo_name" '[.[] | . + {repository: {name: $name}}]')

    jq -s '.[0] + .[1]' "$tmp" <(echo "$result") > "${tmp}.new" && mv "${tmp}.new" "$tmp"
  done

  cat "$tmp"
  rm -f "$tmp"
}

echo "Fetching ready-for-human-review PRs..."
fetch_label "ready-for-human-review" > /tmp/rr.json

echo "Fetching discussion-needed PRs..."
fetch_label "discussion-needed" > /tmp/dn.json

BOT_AUTHORS="app/dependabot|app/red-hat-konflux-kflux-prd-rh02|redhat-chai-bot"

echo "Fetching needs-ok-to-test PRs (bot authors only)..."
fetch_label "needs-ok-to-test" | jq --arg bots "$BOT_AUTHORS" \
  '[.[] | select(.author.login | test($bots))]' > /tmp/okt.json

echo "Fetching all open bot PRs (regardless of label)..."
for repo in "${REPOS[@]}"; do
  gh pr list --repo "$repo" --author redhat-chai-bot --state open \
    --limit 100 --json "$JSON_FIELDS" 2>/dev/null | \
    jq --arg name "${repo#*/}" '[.[] | . + {repository: {name: $name}}]'
done | jq -s 'add // []' > /tmp/bot_all.json

# Merge bot PRs into okt, deduplicating by URL
jq -s '(.[0] + .[1]) | unique_by(.url)' /tmp/okt.json /tmp/bot_all.json > /tmp/okt_merged.json
mv /tmp/okt_merged.json /tmp/okt.json

jq -n \
  --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile rr /tmp/rr.json \
  --slurpfile dn /tmp/dn.json \
  --slurpfile okt /tmp/okt.json \
  '{updated: $updated, review_ready: $rr[0], discussion_needed: $dn[0], needs_ok_to_test: $okt[0]}' \
  > "$OUT"

echo "Wrote $OUT ($(jq '.review_ready | length' "$OUT") ready-for-human-review, $(jq '.discussion_needed | length' "$OUT") discussion-needed, $(jq '.needs_ok_to_test | length' "$OUT") needs-ok-to-test)"
