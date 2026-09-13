#!/usr/bin/env bash
# lkml-fleet-kickoff.sh — Compose (and optionally send) a fleet kickoff mail
# for a local patch series or single patch.
#
# Usage: lkml-fleet-kickoff.sh <repo> <range> --from <addr> --to <addr>
#            [--cc <addr>] --subject <subject> [--summary <text>]
#            [--template <file>] [--attach] [--send]
#
# <repo>       path to a local git repository.
# <range>      a revision range passed straight to `git format-patch`
#              (e.g. "main..topic" or "main...topic"); a bare ref works
#              too, degenerately, for the single-patch case.
# --from       sending address (required).
# --to         recipient address(es), comma-separated (required).
# --cc         optional Cc address(es), comma-separated.
# --subject    the mail subject (required).
# --summary    one paragraph/sentence filled into ${SUMMARY}; default empty.
# --template   kickoff template to fill; defaults to this repo's own
#              fleet/kickoffs/series-review.md.
# --attach     format the range with `git format-patch` and attach each
#              produced patch file to the mail. Without this flag, the
#              mail carries only the branch name for reviewers to check
#              out themselves.
# --send       actually run the composed `fork-sandbox mail send`
#              command. Without it, the command is printed, shell-quoted,
#              and nothing is sent.
#
# This script is LOCAL ONLY: it formats patches and fills a template. It
# never talks to GitHub or the network in any way — the postmaster and
# `fork-sandbox mail` handle everything past composing the message.

set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
default_template="$script_dir/../fleet/kickoffs/series-review.md"

usage() {
    sed -n '2,/^set -euo/{ /^#/s/^# \?//p }' "$0"
}

case "${1-}" in
    -h|--help) usage; exit 0 ;;
esac

repo="${1:?Usage: lkml-fleet-kickoff.sh <repo> <range> --from <addr> --to <addr> --subject <subject> [options]. See --help.}"
range="${2:?Usage: lkml-fleet-kickoff.sh <repo> <range> --from <addr> --to <addr> --subject <subject> [options]. See --help.}"
shift 2

from=""
to=""
cc=""
subject=""
summary=""
template="$default_template"
attach=0
send=0

while (( $# > 0 )); do
    case "$1" in
        --from|--to|--cc|--subject|--summary|--template)
            (( $# >= 2 )) || { echo "Error: $1 requires a value. See --help." >&2; exit 1; }
            ;;
    esac
    case "$1" in
        --from) from="$2"; shift 2 ;;
        --to) to="$2"; shift 2 ;;
        --cc) cc="$2"; shift 2 ;;
        --subject) subject="$2"; shift 2 ;;
        --summary) summary="$2"; shift 2 ;;
        --template) template="$2"; shift 2 ;;
        --attach) attach=1; shift ;;
        --send) send=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown argument '$1'. See --help." >&2; exit 1 ;;
    esac
done

[[ -n "$from" ]] || { echo "Error: --from is required. See --help." >&2; exit 1; }
[[ -n "$to" ]] || { echo "Error: --to is required. See --help." >&2; exit 1; }
[[ -n "$subject" ]] || { echo "Error: --subject is required. See --help." >&2; exit 1; }
[[ -f "$template" ]] || { echo "Error: template '$template' does not exist." >&2; exit 1; }

tmpdir="$(mktemp -d)"
# Only clean up once actually sent: in print-only mode the printed command
# names files under $tmpdir, and a caller pasting it later needs them to
# still exist.
cleanup() { if (( send )); then rm -rf -- "$tmpdir"; fi; }
trap cleanup EXIT

git -C "$repo" format-patch -o "$tmpdir" "$range" >/dev/null

patches=()
while IFS= read -r -d '' f; do
    patches+=("$f")
done < <(find "$tmpdir" -maxdepth 1 -name '*.patch' -print0 | sort -z)
patch_count="${#patches[@]}"

if (( attach )) && (( patch_count == 0 )); then
    echo "Error: range '$range' produced no patches; refusing to send an --attach kickoff with nothing attached." >&2
    exit 1
fi

# "a..b" or "a...b" both split on the first/last ".." respectively; a bare
# ref with no ".." leaves base and branch equal to the ref itself, a
# harmless degenerate case for the single-patch template's display.
base="${range%%..*}"
branch="${range##*..}"

# The branch-name variant tells reviewers to `git fetch origin $branch;
# git checkout $branch`, so $branch must actually be a branch (or other
# symbolic ref) git can check out by that name -- not just whatever
# string happened to be on the right of "..", e.g. "HEAD" from a range
# like "HEAD~1..HEAD". --attach doesn't rely on the name, only on the
# already-formatted patch files, so it is exempt from this check.
if (( ! attach )); then
    resolved_branch="$(git -C "$repo" rev-parse --abbrev-ref "$branch" 2>/dev/null || true)"
    if [[ "$resolved_branch" != "$branch" ]]; then
        echo "Error: range '$range' does not resolve to a checkout-able branch name on its right side ('$branch'); the branch-name variant needs a real branch for reviewers to fetch and check out. Use --attach instead, or pass a range like '<base>..<branch>'." >&2
        exit 1
    fi
fi

# fill <content-varname> <PLACEHOLDER-NAME> <value> — literal substring
# replace, since ${var} values here never contain glob metacharacters.
fill() {
    local -n content_ref="$1"
    content_ref="${content_ref//\$\{$2\}/$3}"
}

# Comments are stripped by finding "-->" as a substring anywhere in the
# line, not by anchoring to end-of-line -- a closing "-->" followed by
# trailing whitespace or by more text on the same line still closes the
# comment, instead of leaving in_comment set and swallowing the rest of
# the file.
body="$(awk '
    BEGIN { in_comment = 0; started = 0 }
    {
        line = $0
        if (!started) {
            if (in_comment) {
                idx = index(line, "-->")
                if (idx == 0) { next }
                in_comment = 0
                line = substr(line, idx + 3)
                sub(/^[ \t]+/, "", line)
            } else if (line ~ /^<!--/) {
                idx = index(line, "-->")
                if (idx == 0) { in_comment = 1; next }
                line = substr(line, idx + 3)
                sub(/^[ \t]+/, "", line)
            }
            if (line == "") { next }
            started = 1
        }
        print line
    }
' "$template")"
fill body FROM "$from"
fill body TO "$to"
fill body CC "$cc"
fill body SUBJECT "$subject"
fill body SUMMARY "$summary"
fill body BASE "$base"
fill body BRANCH "$branch"
fill body PATCH_COUNT "$patch_count"

# An unterminated (or entirely swallowed) template comment would
# otherwise post an empty kickoff to the whole panel and report success.
if [[ -z "${body//[$'\t\r\n ']/}" ]]; then
    echo "Error: template '$template' produced an empty body (check for an unterminated HTML comment)." >&2
    exit 1
fi

body_file="$tmpdir/body.txt"
printf '%s\n' "$body" > "$body_file"

cmd=(fork-sandbox mail send --from "$from" --to "$to")
[[ -n "$cc" ]] && cmd+=(--cc "$cc")
cmd+=(--subject "$subject" --body "$body_file")
if (( attach )); then
    for f in "${patches[@]}"; do
        cmd+=(--attach "$f")
    done
fi

if (( send )); then
    "${cmd[@]}"
else
    printf '%q ' "${cmd[@]}"
    printf '\n'
    printf 'Note: temp files for this command are left under %s -- nothing removes them; delete it yourself once done.\n' "$tmpdir" >&2
fi
