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

# "a..b" or "a...b" both split on the first/last ".." respectively; a bare
# ref with no ".." leaves base and branch equal to the ref itself, a
# harmless degenerate case for the single-patch template's display.
base="${range%%..*}"
branch="${range##*..}"

# fill <content-varname> <PLACEHOLDER-NAME> <value> — literal substring
# replace, since ${var} values here never contain glob metacharacters.
fill() {
    local -n content_ref="$1"
    content_ref="${content_ref//\$\{$2\}/$3}"
}

body="$(awk '
    BEGIN { in_comment = 0; started = 0 }
    {
        if (!started) {
            if ($0 ~ /^<!--/) { in_comment = 1 }
            if (in_comment) {
                if ($0 ~ /-->$/) { in_comment = 0 }
                next
            }
            if ($0 == "") { next }
            started = 1
        }
        print
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
fi
