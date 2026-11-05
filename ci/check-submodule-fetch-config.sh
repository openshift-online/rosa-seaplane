#!/bin/bash
# CI entrypoint for the submodule fetch-recursion guard.
#
# Asserts that every submodule in .gitmodules disables fetch-time recursion, and
# then demonstrates that the setting still does its job on the git in use, by
# replaying Prow's clonerefs checkout sequence against throwaway fixture
# repositories. See "Checkout and Submodules" in ci/README.md for the full
# rationale; the short version is that clonerefs checks this repo out with a
# sparse checkout, so a PR that moves a submodule's pinned commit makes
# `git fetch <pr head>` recurse into a submodule directory that does not exist
# and abort with "Could not access submodule '<path>'".
#
# The check is hermetic and offline: it never contacts the submodule's upstream
# URL, and non-file transports are disabled for the fixtures so that an
# accidental attempt fails immediately instead of hanging.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
GITMODULES="$PWD/.gitmodules"

if [ ! -f "$GITMODULES" ]; then
    echo "❌ Expected a .gitmodules file at the repository root; none found." >&2
    echo "   If the submodule was removed on purpose, drop this check and its" >&2
    echo "   Makefile target. Otherwise the repository layout changed." >&2
    exit 1
fi

TMPDIR_CHECK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CHECK"' EXIT

# Keep fixture operations away from the caller's git configuration, and away
# from any repository the caller may have pinned through the environment -- a
# git hook or `git rebase --exec` exports GIT_DIR, which would otherwise send
# `git init` and every later command at the wrong repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
export GIT_CONFIG_GLOBAL="$TMPDIR_CHECK/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="submodule-fetch-check"
export GIT_AUTHOR_EMAIL="submodule-fetch-check@localhost"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
: >"$GIT_CONFIG_GLOBAL"
git config --global init.defaultBranch main
git config --global advice.detachedHead false
# The fixtures only ever use file:// transport. Anything else means the replay
# stopped testing what it is supposed to test, so fail fast rather than reach
# for the network.
git config --global protocol.https.allow never
git config --global protocol.ssh.allow never

# Two arbitrary, non-existent commit ids. The fixture only needs the gitlink
# value to differ between the base and head commits; the submodule itself is
# never cloned.
PIN_BASE="1111111111111111111111111111111111111111"
PIN_HEAD="2222222222222222222222222222222222222222"

# Exit status used when the fixture itself is broken, so that a collapsed setup
# is never mistaken for a passing or failing checkout.
FIXTURE_BROKEN=90

# ---------------------------------------------------------------------------
# 1. Static assertion: every submodule disables fetch-time recursion.
# ---------------------------------------------------------------------------
echo "🔍 Checking submodule fetch-recursion settings in .gitmodules..."

# `git config --list` is run inside a process substitution below, where its exit
# status would be discarded, so check that .gitmodules parses first. Otherwise a
# syntax error yields no submodules and the check passes vacuously.
if ! git config -f "$GITMODULES" --list >/dev/null; then
    echo "❌ .gitmodules could not be parsed by git (see the error above)." >&2
    exit 1
fi

mapfile -t SUBMODULES < <(
    git config -f "$GITMODULES" --name-only --list |
        sed -n 's/^submodule\.\(.*\)\.path$/\1/p'
)

if [ "${#SUBMODULES[@]}" -eq 0 ]; then
    echo "✅ .gitmodules declares no submodules; nothing to check"
    exit 0
fi

missing=false
for name in "${SUBMODULES[@]}"; do
    value="$(git config -f "$GITMODULES" --get "submodule.$name.fetchRecurseSubmodules" || true)"
    case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    false | no | off | 0)
        echo "   ✓ $name: fetchRecurseSubmodules = $value"
        ;;
    *)
        missing=true
        echo "   ✗ $name: fetchRecurseSubmodules is '${value:-<unset>}', expected false"
        ;;
    esac
done

if [ "$missing" = true ]; then
    cat >&2 <<-'EOF'

		❌ Every submodule in .gitmodules must set 'fetchRecurseSubmodules = false'.

		   Without it, any PR that changes a submodule's pinned commit fails in
		   Prow at checkout time with "Could not access submodule '<path>'",
		   because clonerefs fetches the PR head into a sparse checkout that does
		   not contain the submodule directory. See "Checkout and Submodules" in
		   ci/README.md.
	EOF
    exit 1
fi

# ---------------------------------------------------------------------------
# 2./3. Behavioural replay of the clonerefs checkout sequence.
# ---------------------------------------------------------------------------

# build_fixture <dir> <gitmodules-file>
#
# Creates a superproject with three commits:
#   A  build-root context only, no submodules
#   B  adds every gitlink from <gitmodules-file>, pinned at PIN_BASE  (= main)
#   C  moves every gitlink to PIN_HEAD                                (= PR head)
build_fixture() {
    local dir="$1" gitmodules="$2" name path

    git init -q "$dir"
    # Without this the server silently ignores --filter=blob:none, and the
    # replay would no longer reproduce Prow's blobless fetch.
    git -C "$dir" config uploadpack.allowFilter true

    mkdir -p "$dir/ci"
    echo "FROM scratch" >"$dir/ci/Containerfile"
    git -C "$dir" add ci/Containerfile
    git -C "$dir" commit -qm "A: build-root context only"

    cp "$gitmodules" "$dir/.gitmodules"
    git -C "$dir" add .gitmodules
    for name in "${SUBMODULES[@]}"; do
        path="$(git config -f "$gitmodules" --get "submodule.$name.path")"
        git -C "$dir" update-index --add --cacheinfo "160000,$PIN_BASE,$path"
    done
    git -C "$dir" commit -qm "B: add submodule gitlinks"

    for name in "${SUBMODULES[@]}"; do
        path="$(git config -f "$gitmodules" --get "submodule.$name.path")"
        git -C "$dir" update-index --add --cacheinfo "160000,$PIN_HEAD,$path"
    done
    git -C "$dir" commit -qm "C: bump submodule gitlinks"
}

# replay_clonerefs <fixture-dir> <work-dir> <log-file>
#
# Reproduces, in order, the commands clonerefs emits for a presubmit with
# decoration_config.sparse_checkout_files = [ci/Containerfile], up to and
# including the fetch of the PR head.
#
# Returns that fetch's exit status, or $FIXTURE_BROKEN if the checkout did not
# end up in the state the test depends on. errexit does not apply inside this
# subshell (the function is used as an `if` condition), so the preconditions are
# asserted explicitly rather than relied upon.
replay_clonerefs() {
    local fixture="$1" work="$2" log="$3"
    local base head
    base="$(git -C "$fixture" rev-parse HEAD~1)"
    head="$(git -C "$fixture" rev-parse HEAD)"

    mkdir -p "$work"
    (
        cd "$work" || exit "$FIXTURE_BROKEN"
        git init -q || exit "$FIXTURE_BROKEN"
        git config user.name ci-robot
        git config user.email ci-robot@k8s.io
        git sparse-checkout init || exit "$FIXTURE_BROKEN"
        git fetch -q --filter=blob:none --no-tags "file://$fixture" "$base" ||
            exit "$FIXTURE_BROKEN"
        git sparse-checkout set ci/Containerfile || exit "$FIXTURE_BROKEN"
        git checkout -q "$base" || exit "$FIXTURE_BROKEN"
        git branch -q --force main "$base" || exit "$FIXTURE_BROKEN"
        git checkout -q main || exit "$FIXTURE_BROKEN"

        # The whole point of the replay is a gitlink that is in the index but
        # absent from the working tree. If that is not what we built, the result
        # of the fetch below would mean nothing.
        for name in "${SUBMODULES[@]}"; do
            path="$(git config -f "$fixture/.gitmodules" --get "submodule.$name.path")"
            git ls-files -t -- "$path" | grep -q '^S ' || {
                echo "precondition failed: '$path' is not skip-worktree in the index"
                exit "$FIXTURE_BROKEN"
            }
            [ ! -e "$path" ] || {
                echo "precondition failed: '$path' unexpectedly exists in the working tree"
                exit "$FIXTURE_BROKEN"
            }
        done

        git fetch --filter=blob:none "file://$fixture" "$head"
    ) >"$log" 2>&1
}

report_fixture_broken() {
    local log="$1"
    echo "   ✗ the fixture did not reach the state under test:" >&2
    sed 's/^/     /' "$log" >&2
    echo "" >&2
    echo "❌ ci/check-submodule-fetch-config.sh could not run its replay." >&2
    exit 1
}

echo ""
echo "🔍 Replaying the Prow clonerefs checkout sequence (offline fixture)..."

build_fixture "$TMPDIR_CHECK/super-real" "$GITMODULES"
real_rc=0
replay_clonerefs "$TMPDIR_CHECK/super-real" "$TMPDIR_CHECK/work-real" \
    "$TMPDIR_CHECK/real.log" || real_rc=$?
case "$real_rc" in
0)
    echo "   ✓ PR-head fetch succeeds with this repository's .gitmodules"
    ;;
"$FIXTURE_BROKEN")
    report_fixture_broken "$TMPDIR_CHECK/real.log"
    ;;
*)
    echo "   ✗ PR-head fetch FAILED with this repository's .gitmodules:" >&2
    sed 's/^/     /' "$TMPDIR_CHECK/real.log" >&2
    cat >&2 <<-'EOF'

		❌ A PR that changes a submodule pin would fail Prow's checkout.
		   See "Checkout and Submodules" in ci/README.md.
	EOF
    exit 1
    ;;
esac

# Negative control: strip the setting with git's own parser and confirm the
# failure comes back. This is informational -- if a future git stops failing
# here the replay simply no longer reproduces the bug, which is not a reason to
# fail the build.
cp "$GITMODULES" "$TMPDIR_CHECK/gitmodules-stripped"
for name in "${SUBMODULES[@]}"; do
    git config -f "$TMPDIR_CHECK/gitmodules-stripped" \
        --unset-all "submodule.$name.fetchRecurseSubmodules" || true
done

build_fixture "$TMPDIR_CHECK/super-stripped" "$TMPDIR_CHECK/gitmodules-stripped"
stripped_rc=0
replay_clonerefs "$TMPDIR_CHECK/super-stripped" "$TMPDIR_CHECK/work-stripped" \
    "$TMPDIR_CHECK/stripped.log" || stripped_rc=$?
case "$stripped_rc" in
0)
    echo "   ℹ negative control did not reproduce on git $(git --version | awk '{print $3}')."
    echo "     The setting is kept because Prow's clonerefs image may run a git that does."
    ;;
"$FIXTURE_BROKEN")
    report_fixture_broken "$TMPDIR_CHECK/stripped.log"
    ;;
*)
    echo "   ✓ negative control reproduces: removing the setting breaks the fetch with"
    echo "     \"$(grep -m1 'Could not access submodule' "$TMPDIR_CHECK/stripped.log" || echo 'a fetch error')\""
    ;;
esac

echo ""
echo "✅ Submodule fetch-recursion check complete"
