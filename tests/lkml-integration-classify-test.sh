#!/usr/bin/env bash
# lkml-integration-classify-test.sh — Run the ancestor rule from
# fleet/personas/pr-author.md ("Integrating the human author's push",
# step 2 (a)) against scratch repos, and check each classification by
# hand-derived expectation. The rule is prose the persona follows with git;
# this transcribes it so a stacked revert or a pull-then-edit cannot go
# unnoticed again (a single-commit revert passes a naive per-commit
# forward-apply test; stacked commits do not).
#
# Usage: tests/lkml-integration-classify-test.sh

set -uo pipefail

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# classify <c> <vN sha> <frozen head> — the persona's step 2 (a), run in $PWD
# with a branch called `upstream`, for a commit c that is an ancestor of it.
classify() {
    local c="$1" vn="$2" fh="$3" p
    p="$(git diff --no-renames --name-only "$c^" "$c")"
    [[ -z "$p" ]] && { echo taken; return; }
    # shellcheck disable=SC2086  # P is a newline-separated path list
    set -- $p
    if git diff --quiet "$vn" upstream -- "$@"; then echo taken
    elif git diff --quiet "$c" upstream -- "$@"; then echo taken
    elif git diff --quiet "$c^" upstream -- "$@" \
      || git diff --quiet "$fh" upstream -- "$@"; then echo "not taken"
    else echo changed
    fi
}

# fixture — F has a=a and other=o; c1 a->b; c2 b->c; vN = c2. Leaves the repo
# on branch `upstream` at vN, and sets F, C1, C2.
fixture() {
    rm -rf "$work/r"; git init -q -b main "$work/r"; cd "$work/r" || exit 1
    printf 'a\n' > a; printf 'o\n' > other; git add .; git commit -qm F; F="$(git rev-parse HEAD)"
    printf 'b\n' > a; git commit -qam c1; C1="$(git rev-parse HEAD)"
    printf 'c\n' > a; git commit -qam c2; C2="$(git rev-parse HEAD)"
    git branch upstream
    git switch -q upstream
}

expect() { # $1=name $2=commit sha $3=want
    local got; got="$(classify "$2" "$C2" "$F")"
    if [[ "$got" == "$3" ]]; then ok "$1: $3"; else no "$1" "want '$3', got '$got'"; fi
}

fixture   # the human fast-forwards to the tip
expect "fast-forward, c1" "$C1" "taken"
expect "fast-forward, c2" "$C2" "taken"

fixture   # pulls vN, then reverts both commits: H's tree equals F's
git revert --no-edit "$C2" "$C1" >/dev/null
expect "pull then revert both, c1" "$C1" "not taken"
expect "pull then revert both, c2" "$C2" "not taken"

fixture   # pulls vN, then edits the panel's line in a commit of their own
printf 'z\n' > a; git commit -qam "take the tip, fix a nit"
expect "pull then edit, c1" "$C1" "changed"
expect "pull then edit, c2" "$C2" "changed"

fixture   # pulls vN, then reverts only the tip
git revert --no-edit "$C2" >/dev/null
expect "pull then revert the tip, c1" "$C1" "taken"
expect "pull then revert the tip, c2" "$C2" "not taken"

fixture   # pulls vN and adds an unrelated commit of their own
printf 'o2\n' > other; git commit -qam "unrelated"
expect "pull plus unrelated commit, c1" "$C1" "taken"
expect "pull plus unrelated commit, c2" "$C2" "taken"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
