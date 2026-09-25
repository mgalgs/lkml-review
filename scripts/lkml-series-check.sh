#!/usr/bin/env bash
# lkml-series-check.sh — Refuse a series that is not a clean re-roll.
#
# Usage: lkml-series-check.sh --repo <path> --boundary <sha-or-ref>
#            [--allow-fixups-for <lo>..<hi>] <tip>
#
# A series in this project must read like a real mailing-list series, not
# a review log: every version is a clean re-roll, accepted feedback is
# folded into the commit it belongs to, one logical change per commit. The
# commits at and below <boundary> are FROZEN (the reviewed pull request's
# own commits, or the series base when nothing is stacked on one);
# everything in <boundary>..<tip> is the author's series. This checks that
# range and prints one line per violation:
#
#     <short sha> <subject>: <why>
#
# Exit 0 when clean, 1 on any violation, 2 on a usage or git error.
# lkml-revise.sh runs it on every post; run it by hand before a final
# series is bundled.
#
# Checks:
#   1. <boundary> is an ancestor of <tip>. Otherwise the frozen commits
#      were rewritten, or the series is not on the boundary.
#   2. The range is not empty.
#   3. No merge commits: a series is linear.
#   4. No subject starting fixup!, squash! or amend!. With
#      `--allow-fixups-for <lo>..<hi>` such a commit passes IFF its target
#      is a commit in <lo>..<hi> (a slice of the frozen commits under
#      review, whose fixes are left unfolded for a human). <lo> and <hi>
#      must name commits, <lo> must be an ancestor of <hi>, and <hi> an
#      ancestor of (or equal to) <boundary>; otherwise exit 2. The target
#      is resolved the way `git rebase --autosquash` does: strip the
#      prefix (repeatedly, for `fixup! fixup! X`); if the rest is a sha
#      (prefix) naming an earlier commit, that is the target; else the
#      rest is matched against the subjects of ALL earlier commits, not
#      just the range, an exact match first, else a subject that STARTS
#      WITH the rest; when several match, the EARLIEST wins (as git does,
#      checked against `git rebase -i --autosquash`). Only then
#      is the target tested for membership in <lo>..<hi>, so a fixup aimed
#      at a frozen commit outside the slice is not captured by a slice
#      commit whose subject merely starts with the same text. A target
#      outside the range, or none, is a violation:
#      `<short> <subject>: fixup target is not a commit in <lo>..<hi>`.
#      A fixup that passes this way is exempt from check 5, because it
#      folds into its target.
#   5. No comment-only commit, unless the message carries a trailer
#      `Comment-only: <reason>` (non-empty reason, on any line of
#      the message body). The legitimate case
#      is a comment fix to the FROZEN commits' code, which cannot be
#      folded anywhere, so it stands alone and says why. A commit is
#      comment-only when it modifies at least one file, adds or deletes
#      none, and every modified file is comment-only:
#        - *.py: the ASTs of the two versions are equal once docstrings
#          are removed. A file that does not parse is NOT comment-only.
#        - any other file: every changed line is a comment line -- it
#          starts, after leading whitespace, with `//`, `/*`, `*` (alone
#          or followed by whitespace or `/`), `<!--`, `#`, `--` or `;`.
#          Each of `#`, `--` and `;` counts only for file types known to
#          use it, because elsewhere it is code: `#` is a shell, Ruby,
#          Perl, YAML, TOML, config, Makefile/Kconfig/Kbuild, assembly
#          (lowercase .s) and INI comment, but a preprocessor line, a
#          device-tree property, a CSS id selector or a private field in
#          C, .S, .dts, .css, .js and everything unlisted; `#!` is never a
#          comment. `--` counts only in SQL, Lua, Ada, VHDL, Elm and
#          Haskell files (elsewhere it is an option continuation line),
#          `;` only in Lisp-family, assembly and INI
#          files. Whitespace-only lines are ignored. Documentation
#          (*.md, *.rst, *.txt, *.adoc, anything under doc/ or docs/) is
#          real content, never comment-only.
#
# This runs on the host over agent-written commits, so it never executes
# anything from them: it reads objects with `git -C <repo>` (rev-list,
# diff-tree, diff between two blobs, cat-file, log), never checks out, runs
# no hook and none of the project's code. Python is parsed, not run.

set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
py_helper="$script_dir/lkml-series-check-py.py"

usage() {
    sed -n '2,/^set -euo/{ /^#/s/^# \?//p }' "$0"
}

die2() { echo "lkml-series-check: Error: $*" >&2; exit 2; }

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
    esac
done

repo=""
boundary=""
tip=""
allow_spec=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2:?--repo requires a path}"; shift 2 ;;
        --boundary) boundary="${2:?--boundary requires a sha or ref}"; shift 2 ;;
        --allow-fixups-for) allow_spec="${2:?--allow-fixups-for requires <lo>..<hi>}"; shift 2 ;;
        -*) die2 "unknown option '$1'." ;;
        *)
            [[ -z "$tip" ]] || die2 "more than one <tip> given."
            tip="$1"; shift ;;
    esac
done

[[ -n "$repo" ]] || die2 "--repo is required."
[[ -n "$boundary" ]] || die2 "--boundary is required."
[[ -n "$tip" ]] || die2 "a <tip> is required."
[[ "$boundary" != -* && "$tip" != -* ]] || die2 "refs must not start with '-'."
command -v git >/dev/null 2>&1 || die2 "git not found on PATH."
command -v python3 >/dev/null 2>&1 || die2 "python3 not found on PATH."
[[ -f "$py_helper" ]] || die2 "helper $py_helper is missing."

boundary_sha="$(git -C "$repo" rev-parse --verify --quiet "${boundary}^{commit}" 2>/dev/null)" ||
    die2 "--boundary '$boundary' does not name a commit in $repo."
tip_sha="$(git -C "$repo" rev-parse --verify --quiet "${tip}^{commit}" 2>/dev/null)" ||
    die2 "tip '$tip' does not name a commit in $repo."

allow_lo_sha=""
allow_hi_sha=""
if [[ -n "$allow_spec" ]]; then
    allow_lo="${allow_spec%%..*}"
    allow_hi="${allow_spec#*..}"
    [[ "$allow_spec" == *..* && -n "$allow_lo" && -n "$allow_hi" &&
        "$allow_hi" != .* && "$allow_lo" != -* && "$allow_hi" != -* ]] ||
        die2 "--allow-fixups-for '$allow_spec' is not of the form <lo>..<hi>."
    allow_lo_sha="$(git -C "$repo" rev-parse --verify --quiet "${allow_lo}^{commit}" 2>/dev/null)" ||
        die2 "--allow-fixups-for: '$allow_lo' does not name a commit in $repo."
    allow_hi_sha="$(git -C "$repo" rev-parse --verify --quiet "${allow_hi}^{commit}" 2>/dev/null)" ||
        die2 "--allow-fixups-for: '$allow_hi' does not name a commit in $repo."
    git -C "$repo" merge-base --is-ancestor "$allow_lo_sha" "$allow_hi_sha" ||
        die2 "--allow-fixups-for: '$allow_lo' is not an ancestor of '$allow_hi'."
    git -C "$repo" merge-base --is-ancestor "$allow_hi_sha" "$boundary_sha" ||
        die2 "--allow-fixups-for: '$allow_hi' is not at or below the boundary."
fi

tmp="$(mktemp -d)" || die2 "mktemp failed."
trap 'rm -rf -- "$tmp"' EXIT

violations=()

# Control characters in an agent-written subject must not reach the
# operator's terminal.
subject_of() {
    git -C "$repo" log -1 --format=%s "$1" | LC_ALL=C tr -d '[:cntrl:]'
}

flag() {
    local sha="$1" why="$2"
    violations+=("$(git -C "$repo" rev-parse --short "$sha") $(subject_of "$sha"): $why")
}

finish() {
    local v
    if (( ${#violations[@]} == 0 )); then
        exit 0
    fi
    for v in "${violations[@]}"; do
        printf '%s\n' "$v"
    done
    exit 1
}

if ! git -C "$repo" merge-base --is-ancestor "$boundary_sha" "$tip_sha"; then
    flag "$tip_sha" "the frozen commits were rewritten or the series is not on the boundary (${boundary_sha:0:12} is not an ancestor of the tip)"
    finish
fi

mapfile -t range < <(git -C "$repo" rev-list --reverse "$boundary_sha..$tip_sha")
if (( ${#range[@]} == 0 )); then
    flag "$tip_sha" "no commits above the boundary"
    finish
fi

# True when one modified file changes nothing but comments.
file_comment_only() {
    local path="$1" old="$2" new="$3" hash=0 dash=0 semi=0
    case "$path" in
        *.md|*.rst|*.txt|*.adoc) return 1 ;;
    esac
    case "/$path" in
        */doc/*|*/docs/*) return 1 ;;
    esac
    case "$path" in
        *.py)
            git -C "$repo" cat-file blob "$old" > "$tmp/old.py" || return 1
            git -C "$repo" cat-file blob "$new" > "$tmp/new.py" || return 1
            python3 "$py_helper" "$tmp/old.py" "$tmp/new.py"
            return
            ;;
        *.sh|*.bash|*.zsh|*.ksh|*.rb|*.pl|*.pm|*.yaml|*.yml|*.toml|*.cfg|*.conf|*.mk|*.cmake|*.tcl|*.r|*.R|*.ps1|*.awk|*.sed|*.gitignore|*.gitattributes) hash=1 ;;
        */Makefile|Makefile|*/Kconfig*|Kconfig*|*/Kbuild|Kbuild|*/Dockerfile|Dockerfile|*/CMakeLists.txt|CMakeLists.txt) hash=1 ;;
        *.sql|*.lua|*.adb|*.ads|*.vhd|*.vhdl|*.elm) dash=1 ;;
        *.hs) dash=1 ;;
        *.el|*.lisp|*.lsp|*.scm|*.rkt|*.clj|*.cljs) semi=1 ;;
        *.asm|*.s|*.ini) semi=1; hash=1 ;;
    esac
    git -C "$repo" diff --no-ext-diff --no-textconv --no-color -U0 \
        --diff-algorithm=myers "$old" "$new" | awk -v hash="$hash" -v dash="$dash" -v semi="$semi" '
        /^(Binary files|GIT binary patch)/ { bad = 1 }
        /^@@/ { inh = 1; next }
        inh && /^[-+]/ {
            s = substr($0, 2)
            sub(/^[ \t\r]+/, "", s)
            if (s ~ /^[ \t\r]*$/) next
            n++
            if (s ~ /^\/\// || s ~ /^\/\*/ || s ~ /^\*($|[ \t\/])/ || (dash && s ~ /^--/) ||
                (semi && s ~ /^;/) || s ~ /^<!--/ ||
                (hash && s ~ /^#/ && s !~ /^#!/)) next
            bad = 1
        }
        END { exit (bad || n == 0) ? 1 : 0 }'
}

# True when the commit modifies at least one file, adds/deletes/renames
# none, and every modified file is comment-only. A raw diff-tree record
# is `:<mode> <mode> <sha> <sha> <status>` NUL `<path>` NUL.
commit_comment_only() {
    local sha="$1" n=0 meta path om nm osha nsha st
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        read -r om nm osha nsha st <<< "${meta#:}"
        n=$(( n + 1 ))
        [[ "$st" == "M" ]] || return 1
        [[ "$om" == "$nm" && ( "$nm" == "100644" || "$nm" == "100755" ) ]] || return 1
        file_comment_only "$path" "$osha" "$nsha" || return 1
    done < <(git -C "$repo" diff-tree -r --no-renames -z --raw "${sha}^" "$sha")
    (( n > 0 ))
}

# Any body line counts, not only a git trailer in the final paragraph: an
# author who glues it to a body paragraph must not lose a re-roll to layout.
has_comment_only_trailer() {
    git -C "$repo" log -1 --format=%B "$1" | sed 1d |
        grep -Eiq '^Comment-only:[[:space:]]*[^[:space:]]'
}

# Slice membership for --allow-fixups-for.
declare -A in_slice=()
if [[ -n "$allow_spec" ]]; then
    while IFS= read -r line; do
        in_slice["$line"]=1
    done < <(git -C "$repo" rev-list "$allow_lo_sha..$allow_hi_sha")
fi

# True when the fixup!/squash!/amend! commit $1 targets a slice commit.
# The target is resolved the way `git rebase --autosquash` does, against
# every commit before the fixup, oldest first (git takes the earliest
# match, exact before prefix), not just the slice: a fixup aimed at a
# frozen commit outside the slice must not be captured by a slice commit
# whose subject merely starts with the same text. Membership in the
# slice is tested only after the target is resolved.
fixup_targets_slice() {
    local sha="$1" rest full target
    rest="$(git -C "$repo" log -1 --format=%s "$sha")"
    while :; do
        case "$rest" in
            "fixup! "*) rest="${rest#fixup! }" ;;
            "squash! "*) rest="${rest#squash! }" ;;
            "amend! "*) rest="${rest#amend! }" ;;
            *) break ;;
        esac
    done
    [[ -n "$rest" ]] || return 1
    if [[ "$rest" =~ ^[0-9a-fA-F]{4,40}$ ]] &&
        full="$(git -C "$repo" rev-parse --verify --quiet "${rest}^{commit}" 2>/dev/null)" &&
        git -C "$repo" merge-base --is-ancestor "$full" "$sha^"; then
        [[ -n "${in_slice[$full]:-}" ]]
        return
    fi
    target="$(git -C "$repo" log --reverse --format='%H %s' "$sha^" |
        REST="$rest" awk '
            BEGIN { rest = ENVIRON["REST"]; n = length(rest) }
            {
                i = index($0, " "); subj = substr($0, i + 1)
                if (subj == rest) { print substr($0, 1, i - 1); found = 1; exit }
                if (!pre && substr(subj, 1, n) == rest) pre = substr($0, 1, i - 1)
            }
            END { if (!found && pre) print pre }')"
    [[ -n "$target" && -n "${in_slice[$target]:-}" ]]
}

for sha in "${range[@]}"; do
    subject="$(git -C "$repo" log -1 --format=%s "$sha")"
    read -r -a parents <<< "$(git -C "$repo" rev-list --parents -n1 "$sha")"
    if (( ${#parents[@]} > 2 )); then
        flag "$sha" "merge commit; a series is linear"
        continue
    fi
    case "$subject" in
        "fixup! "*|"squash! "*|"amend! "*)
            if [[ -n "$allow_spec" ]]; then
                if fixup_targets_slice "$sha"; then
                    continue
                fi
                flag "$sha" "fixup target is not a commit in $allow_spec"
                continue
            fi
            flag "$sha" "${subject%%!*}! commit; fold it into the commit it belongs to" ;;
        fixup!*|squash!*|amend!*)
            flag "$sha" "${subject%%!*}! commit; fold it into the commit it belongs to" ;;
    esac
    if commit_comment_only "$sha" && ! has_comment_only_trailer "$sha"; then
        flag "$sha" "changes only comments; fold it into the commit it belongs to, or, if it fixes a comment in a frozen commit, say why with a 'Comment-only: <reason>' trailer"
    fi
done

finish
