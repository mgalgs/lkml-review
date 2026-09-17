#!/usr/bin/env bash
# lkml-fleet-kickoff.sh — Compose (and optionally send) a fleet kickoff mail
# for a local patch series or single patch.
#
# Usage: lkml-fleet-kickoff.sh <repo> <range> --from <addr> --to <addr>
#            [--cc <addr>] --subject <subject> [--summary <text>]
#            [--focus <text>] [--template <file>] [--hops <n>]
#            [--ci-first <ci-addr>] [--version <n>] [--attach] [--send]
#
# <repo>       path to a local git repository.
# <range>      a revision range passed straight to `git format-patch`
#              (e.g. "main..topic" or "main...topic"); a bare ref works
#              too, degenerately, for the single-patch case.
# --from       sending address (required).
# --to         recipient address(es), comma-separated (required).
# --cc         optional Cc address(es), comma-separated. Incompatible with
#              --ci-first, whose kickoff must address CI alone.
# --subject    the mail subject (required).
# --summary    one paragraph/sentence filled into ${SUMMARY}; default empty.
# --focus      what this round is concentrating on, filled into
#              ${FOCUS}; default empty. Refused when the template
#              contains ${FOCUS} and --focus was not given: a focused
#              round with nothing to concentrate on wakes the whole
#              panel for nothing, the same reason an empty range is
#              refused below. Warned when --focus was given and the
#              template has no ${FOCUS}: the focus text would never
#              reach the mail, and the panel would wake to an ordinary
#              round while the command line says this one is focused.
#              A template that contains ${FOCUS} is a
#              reply template: a focused round lands inside an
#              existing thread, and this harness composes
#              `fork-sandbox mail send`, which starts a new thread and
#              throws the earlier round away. --send is refused for
#              such a template; print-only mode warns and leaves the
#              body file for a manual `fork-sandbox mail reply
#              --reply-to <message-id>`.
# --template   kickoff template to fill; defaults to this repo's own
#              fleet/kickoffs/series-review.md.
# --hops       non-negative mail reply-hop budget. Omit it to retain the
#              transport's own default.
# --ci-first   address the kickoff to this CI seat alone, then have its
#              reply wake the --to panel with test results. This adds a hop,
#              so it defaults to 9 and warns below that. Before composing,
#              the script requires fork-sandbox and verifies CI plus a
#              non-CI panel recipient; its gate cannot verify that CI's
#              suite can actually run in this repository.
# --version    stamp the subject as a series version: "[PATCH v<n>
#              0/<patch-count>] <subject>", and pass the same <n> to
#              `git format-patch -v -n` so the attached patches' own
#              Subject lines agree with the cover subject instead of
#              contradicting it -- -n so a single-patch range, numbered
#              "0/1" on the cover, is numbered "1/1" on the one
#              attachment too, since format-patch does not number a
#              single-commit range on its own. A subject with no LEADING bracket
#              containing the word "PATCH" -- "[PATCH ...]", but also
#              "[RFC PATCH ...]", "[RESEND PATCH ...]" and other prefixed
#              forms real list traffic uses -- is stamped v1 by default
#              even without this flag -- an unmarked kickoff is the
#              defect this flag exists to fix, so stamping is not
#              opt-in. A bare "v<digits>" in prose, or an unversioned
#              leading PATCH bracket, is not a marker: the former is
#              stamped over (the leading bracket added in front, prose
#              left alone), the latter has the version and patch count
#              inserted into its existing bracket rather than nested
#              inside a second one -- a bare "[PATCH]" becomes
#              "[PATCH v1 0/N]", and a qualified one keeps its
#              qualifier: "[RFC PATCH 0/5]" becomes "[RFC PATCH v1
#              0/N]", not a bare "[PATCH v1 0/N]" with the RFC tag
#              silently dropped. A subject that already
#              carries a leading versioned marker (a "v<digits>" inside
#              that leading bracket) is passed through unchanged and
#              unwarned when --version is omitted (an operator composing
#              a reply-shaped subject by hand has already said what the
#              version is), and refused when --version is given (two
#              contradictory statements about the field that identifies
#              the series); it is also refused when the leading marker's
#              own "i/N" names a patch count that disagrees with the
#              range's real count, the same kind of contradiction. Must
#              be a positive integer; v0 is not a thing on a mailing
#              list. A template containing ${FOCUS} is a reply, by
#              construction round two or later, so its
#              subject is refused rather than silently defaulted to v1
#              unless --version is given or the subject is already
#              marked. This detection is intentionally narrower than
#              the Versions section on lkml-fleet-status.sh: that parser
#              matches "v<digits>" anywhere in a Subject, by design, to
#              stay robust across however panel replies and other tools
#              format theirs. A subject with a stray "v<digits>" outside
#              this leading bracket (e.g. "fix the v2 parser") still
#              gets stamped correctly here, but will still read as an
#              extra, phantom version round on that report -- a
#              pre-existing limitation of that parser, not something
#              this flag can fix from here.
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
focus=""
template="$default_template"
attach=0
send=0
hops=""
ci_first=""
version=""
version_given=0

while (( $# > 0 )); do
    case "$1" in
        --from|--to|--cc|--subject|--summary|--focus|--template|--hops|--ci-first|--version)
            (( $# >= 2 )) || { echo "Error: $1 requires a value. See --help." >&2; exit 1; }
            ;;
    esac
    case "$1" in
        --from) from="$2"; shift 2 ;;
        --to) to="$2"; shift 2 ;;
        --cc) cc="$2"; shift 2 ;;
        --subject) subject="$2"; shift 2 ;;
        --summary) summary="$2"; shift 2 ;;
        --focus) focus="$2"; shift 2 ;;
        --template) template="$2"; shift 2 ;;
        --hops) hops="$2"; shift 2 ;;
        --ci-first) ci_first="$2"; shift 2 ;;
        --version) version="$2"; version_given=1; shift 2 ;;
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
if [[ -n "$hops" && ! "$hops" =~ ^[0-9]+$ ]]; then
    echo "Error: --hops must be a non-negative integer. See --help." >&2
    exit 1
fi
if (( version_given )) && [[ ! "$version" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --version must be a positive integer, got '$version'. v0 is not a thing on a mailing list. See --help." >&2
    exit 1
fi
if [[ -n "$ci_first" && -n "$cc" ]]; then
    echo "Error: --cc is incompatible with --ci-first: the kickoff must address the CI seat alone so Cc recipients are not woken before its results." >&2
    exit 1
fi

ci_first_refusal() {
    printf '%s\n' "Error: $1" >&2
    printf '%s\n' "Use a services-backed \`ci\` seat so its suite executes, or an explicit \"tests were run elsewhere\" injection with provenance." >&2
    printf '%s\n' "Addressing the kickoff to the panel directly \"just for this repo\" is wrong: it silently restores the ordering gap." >&2
    exit 1
}

panel="$to"
handoff=""
if [[ -n "$ci_first" ]]; then
    # Resolved as a sibling, the same way default_template is, so the
    # gate consults lkml's own persona registry rather than whatever
    # fleet the machine's ~/.config/fork-sandbox happens to describe.
    # Without this the panel resolves against the wrong registry, or
    # against none, and every gate below refuses for the wrong reason.
    fleet_cmd="$script_dir/lkml-fleet.sh"
    if [[ ! -x "$fleet_cmd" ]]; then
        ci_first_refusal "--ci-first requires '$fleet_cmd', which is missing or not executable; the gate cannot be skipped."
    fi
    if ! command -v fork-sandbox >/dev/null 2>&1; then
        ci_first_refusal "--ci-first requires the missing fork-sandbox command; the gate cannot be skipped."
    fi
    if ! ci_expansion="$("$fleet_cmd" fleet expand "$ci_first")" || [[ -z "${ci_expansion//[$'\t\r\n ']/}" ]]; then
        ci_first_refusal "CI address '$ci_first' would have addressed nobody and the panel would have silently never started."
    fi
    ci_recipients=0
    while IFS= read -r ci_address; do
        [[ -z "${ci_address//[$'\t\r ']/}" ]] && continue
        (( ci_recipients += 1 ))
    done <<<"$ci_expansion"
    if (( ci_recipients != 1 )); then
        ci_first_refusal "CI address '$ci_first' expands to $ci_recipients recipients; --ci-first must address exactly one CI seat."
    fi
    if ! panel_expansion="$("$fleet_cmd" fleet expand "$panel")" || [[ -z "${panel_expansion//[$'\t\r\n ']/}" ]]; then
        ci_first_refusal "Panel address '$panel' has no recipients: wave two would wake nobody."
    fi
    panel_has_other=0
    while IFS= read -r panel_address; do
        [[ -z "$panel_address" ]] && continue
        if ! grep -Fqx -- "$panel_address" <<<"$ci_expansion"; then
            panel_has_other=1
            break
        fi
    done <<<"$panel_expansion"
    if (( ! panel_has_other )); then
        ci_first_refusal "Panel address '$panel' expands to the CI seat alone: wave two would wake nobody."
    fi
    if [[ -z "$hops" ]]; then
        hops=9
        echo "Note: --ci-first defaults --hops to 9 because the two-wave shape costs an extra hop." >&2
    elif (( 10#$hops < 9 )); then
        echo "Warning: --ci-first's two-wave shape costs an extra hop; --hops $hops may exhaust the thread sooner." >&2
    fi
    handoff="$(cat <<EOF
## Wave one: test results first

This kickoff is addressed to you alone. The rest of the panel has not been
woken, and will not see this series until you reply.

Run the suites and reply as your standing instructions describe. Address
that reply's \`To:\` to $panel — delivery is what wakes the panel, so your
reply is the thing that starts this review. They will wake with this
message, the diff, and your numbers all in the same prompt.

If you cannot run the suites at all, say so plainly and address the reply
to $panel anyway. A panel told "the suite could not run here, and why"
is informed. A panel that is never woken is not.
EOF
)"
    to="$ci_first"
fi

# Comments are stripped by finding "-->" as a substring anywhere in the
# line, not by anchoring to end-of-line -- a closing "-->" followed by
# trailing whitespace or by more text on the same line still closes the
# comment, instead of leaving in_comment set and swallowing the rest of
# the file. Computed up front, before any git work, so the FOCUS-shaped
# checks just below can refuse before format-patch or a version stamp
# ever runs.
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
# shellcheck disable=SC2016  # ${FOCUS} is the literal placeholder text
# being searched for in the stripped body, not a variable to expand.
# Keyed on the placeholder, not a filename, so a site's own focused
# template gets the same refusal.
if [[ -z "$focus" && "$body" == *'${FOCUS}'* ]]; then
    echo "Error: template '$template' contains \${FOCUS} but --focus was not given; a focused round with nothing to concentrate on wakes the whole panel for nothing. Pass --focus <text>." >&2
    exit 1
fi

# Detect an existing version marker, restricted to a LEADING bracket
# that carries the word "PATCH" -- not just a bracket that starts with
# it: "[RFC PATCH v2 0/5]" and "[RESEND PATCH v3 0/5]" are the common
# versioned-series forms on a real list, and anchoring on "^\[PATCH"
# alone missed both, letting them fall through as unmarked and get a
# second, contradictory version stamped in front. A bare "v<n>" outside
# this leading bracket is prose, not a marker, and treating it as one
# (an earlier behaviour) both silently suppressed the default v1 stamp
# for a subject like "fix the v2 scheduler entry" and made --version
# unable to override it -- there was no way to get a correct stamp onto
# such a subject at all. leading_patch_prefix is the whole bracket,
# versioned or not, so an already-bracketed but unversioned subject
# (e.g. "[PATCH] fix the thing", the form single-patch.md documents for
# ${SUBJECT}) gets that bracket replaced below instead of a second one
# nested inside it.
leading_patch_prefix=""
existing_display=""
if [[ "$subject" =~ ^(\[([^]]*)\]) ]]; then
    leading_bracket="${BASH_REMATCH[1]}"
    bracket_content="${BASH_REMATCH[2]}"
    if [[ "$bracket_content" =~ (^|[^[:alnum:]])PATCH($|[^[:alnum:]]) ]]; then
        leading_patch_prefix="$leading_bracket"
        if [[ "$leading_patch_prefix" =~ (^|[^[:alnum:]])v([0-9]+) ]]; then
            existing_display="v${BASH_REMATCH[2]}"
        fi
    fi
fi
if (( version_given )) && [[ -n "$existing_display" ]]; then
    echo "Error: --version $version was given but subject '$subject' already carries a version marker ('$existing_display'); refusing to stamp a second, possibly contradictory, version onto the field that identifies the series." >&2
    exit 1
fi
# shellcheck disable=SC2016  # ${FOCUS} is the literal placeholder text
# being searched for in the stripped body, not a variable to expand.
# A ${FOCUS} template is a reply, by construction round two or later
# (see the --focus header comment): its subject cannot default to v1
# the way a new thread's can, so an unmarked subject here must be told
# its version explicitly rather than silently guessing "1".
if [[ -z "$existing_display" && "$body" == *'${FOCUS}'* ]] && (( ! version_given )); then
    echo "Error: template '$template' contains \${FOCUS}: a focused round is a reply, by construction round two or later, so its subject cannot silently default to v1. Pass --version <n> naming the round this reply belongs to, or a subject that already carries the right marker." >&2
    exit 1
fi
effective_version="${existing_display#v}"
effective_version="${effective_version:-${version:-1}}"

tmpdir="$(mktemp -d)"
# Only clean up once actually sent: in print-only mode the printed command
# names files under $tmpdir, and a caller pasting it later needs them to
# still exist.
cleanup() { if (( send )); then rm -rf -- "$tmpdir"; fi; }
trap cleanup EXIT

# -n forces numbering even for a single-patch range: git format-patch
# only numbers on its own once a range has more than one commit, so
# without it a single-patch series' cover claims "0/1" while the sole
# attached patch's own Subject carries no "1/1" to match.
git -C "$repo" format-patch -o "$tmpdir" -n -v "$effective_version" "$range" >/dev/null

patches=()
while IFS= read -r -d '' f; do
    patches+=("$f")
done < <(find "$tmpdir" -maxdepth 1 -name '*.patch' -print0 | sort -z)
patch_count="${#patches[@]}"

if (( patch_count == 0 )); then
    echo "Error: range '$range' produced no patches; refusing to send a kickoff with nothing to review." >&2
    exit 1
fi

# A subject passed through unchanged (existing_display set) still names
# a patch count in its "i/N" marker, and that N is never checked against
# the range's real patch_count -- so a stale or hand-typed count sails
# through untouched while the cover body's ${PATCH_COUNT} fill and (since
# --version now reaches `git format-patch -v`) every attached patch's own
# "i/N" both carry the real number, leaving the Subject as a third,
# contradicting statement of the series size with no warning at all.
if [[ -n "$existing_display" && "$leading_patch_prefix" =~ [0-9]+/([0-9]+) ]]; then
    declared_count="${BASH_REMATCH[1]}"
    if [[ "$declared_count" != "$patch_count" ]]; then
        echo "Error: subject '$subject' already claims $declared_count patches ('$leading_patch_prefix') but range '$range' produced $patch_count; refusing to send a cover letter whose subject count contradicts the series it will actually attach/reference." >&2
        exit 1
    fi
fi

if [[ -z "$existing_display" ]]; then
    if [[ -n "$leading_patch_prefix" ]]; then
        subject="${subject#"$leading_patch_prefix"}"
        subject="${subject# }"
        # An unversioned leading bracket can carry qualifier words of
        # its own -- "RFC PATCH", "PATCH net-next", "RESEND PATCH" --
        # and even a stale declared count; only the version and the
        # real count are this script's to add. Insert v<n> at the
        # PATCH keyword, drop any existing count, and append the real
        # one, rather than discarding the whole bracket (qualifier
        # included) the way a bare "[PATCH]" is replaced below -- doing
        # that here silently turned "[RFC PATCH 0/5] x" into
        # "[PATCH v1 0/2] x", dropping the RFC tag that tells the panel
        # this is not a merge-ready series.
        before_patch="${bracket_content%%PATCH*}"
        after_patch="${bracket_content#*PATCH}"
        rebuilt_bracket="${before_patch}PATCH v${effective_version}${after_patch}"
        if [[ "$rebuilt_bracket" =~ ^(.*)[0-9]+/[0-9]+(.*)$ ]]; then
            rebuilt_bracket="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        fi
        read -r -a rebuilt_words <<<"$rebuilt_bracket"
        subject="[${rebuilt_words[*]} 0/${patch_count}] ${subject}"
    else
        subject="[PATCH v${effective_version} 0/${patch_count}] ${subject}"
    fi
fi

# "a..b" or "a...b" both split on the first/last ".." respectively; a bare
# ref with no ".." leaves base and branch equal to the ref itself, a
# harmless degenerate case for the single-patch template's display.
base="${range%%..*}"
branch="${range##*..}"

# The template body tells reviewers to `git fetch origin $branch; git
# checkout $branch` as a genuine alternative to the attached patches --
# unconditionally, in both variants -- so $branch must actually be a
# branch (or other symbolic ref) git can check out by that name in
# EITHER mode, not just whatever string happened to be on the right of
# "..", e.g. "HEAD" from a range like "HEAD~1..HEAD". A reviewer who
# takes that fallback with an unresolvable name silently reviews the
# wrong tree, so this check applies whether or not --attach was passed.
resolved_branch="$(git -C "$repo" rev-parse --abbrev-ref "$branch" 2>/dev/null || true)"
if [[ "$resolved_branch" != "$branch" ]]; then
    echo "Error: range '$range' does not resolve to a checkout-able branch name on its right side ('$branch'); the kickoff template always offers reviewers a fetch/checkout fallback and needs a real branch for it. Pass a range like '<base>..<branch>'." >&2
    exit 1
fi

# fill <content-varname> <PLACEHOLDER-NAME> <value> — literal substring
# replace, since ${var} values here never contain glob metacharacters.
#
# An own-line placeholder (the whole line is nothing but the
# placeholder) that fills to the empty string removes its own line and
# one immediately-following blank line, so a template built with a
# blank line on each side of a placeholder doesn't leave that blank
# line stranded when the placeholder has nothing to say. An inline
# placeholder -- anything else on its line -- is untouched by this and
# just substitutes to empty, same as always.
#
# That "one blank per placeholder" accounting is exact for an isolated
# occurrence but not for two own-line placeholders of the same name
# with no blank between them (e.g. "${NAME}\n${NAME}\n\n\nx"): the
# fixed-point re-scan below (needed so back-to-back occurrences separated
# by a blank still both resolve, see its own comment) can let an earlier
# occurrence consume a blank line that, by strict left-to-right reading,
# belonged to a later one. The net blank-line count can end up one
# fewer than the per-occurrence rule promises. No template shipped in
# this repo has adjacent same-name own-line placeholders, so this is
# latent; a --template author relying on the letter of the rule for
# that shape should verify the rendered output.
#
# A sentinel newline is prefixed before matching so a placeholder that
# opens the body (no real newline ahead of it) still matches the same
# "\n${NAME}\n" pattern as one in the middle; it's stripped back off
# before returning. local is named "padded", not "body", because this
# is always invoked as `fill body NAME value` and a local actually
# named "body" would shadow the nameref target instead of extending it.
fill() {
    local -n content_ref="$1"
    local name="$2" value="$3"
    if [[ -z "$value" ]]; then
        local padded=$'\n'"$content_ref" prev
        # ${var//pat/repl} scans left to right for non-overlapping
        # matches, so two own-line-with-blank occurrences of the same
        # name back to back compete for the same newlines: consuming
        # one occurrence's trailing blank leaves the next occurrence's
        # leading newline already spent, and it falls through to the
        # no-blank pattern with a stray blank line left behind. Looping
        # each pattern to a fixed point re-scans the newlines the prior
        # pass freed up, so repeats resolve one at a time regardless of
        # whether a blank line separates them.
        while :; do
            prev="$padded"
            padded="${padded//$'\n'\$\{$name\}$'\n'$'\n'/$'\n'}"
            [[ "$padded" == "$prev" ]] && break
        done
        while :; do
            prev="$padded"
            padded="${padded//$'\n'\$\{$name\}$'\n'/$'\n'}"
            [[ "$padded" == "$prev" ]] && break
        done
        padded="${padded%$'\n'\$\{"$name"\}}"
        content_ref="${padded:1}"
    fi
    content_ref="${content_ref//\$\{$name\}/$value}"
}

# shellcheck disable=SC2016  # ${HANDOFF} is the literal placeholder text
# being searched for in the template, not a variable to expand.
if [[ -n "$ci_first" && "$body" != *'${HANDOFF}'* ]]; then
    echo "Error: --ci-first requires template '$template' to contain \${HANDOFF} in its body so CI receives the wave-one routing instructions." >&2
    exit 1
fi
# shellcheck disable=SC2016  # ${FOCUS} is the literal placeholder text
# being searched for in the stripped body, not a variable to expand.
# Same key as the refusal above: a ${FOCUS} template is a reply
# template, and this harness builds `fork-sandbox mail send`, which
# starts a new thread. --send would throw away the earlier round the
# focus points at, so it is refused; print-only mode only warns,
# because its leftover body file is the input to the manual
# `mail reply` bridge.
if [[ "$body" == *'${FOCUS}'* ]]; then
    if (( send )); then
        echo "Error: template '$template' contains \${FOCUS}: a focused round is a reply inside the thread it concentrates, but --send would run \`fork-sandbox mail send\`, which starts a new thread and throws away the earlier round. Compose without --send and send the leftover body file with \`fork-sandbox mail reply --reply-to <message-id>\`, or use a non-focused template for a new thread." >&2
        exit 1
    fi
    echo "Warning: template '$template' contains \${FOCUS}: a focused round is a reply inside an existing thread, and the command below is \`fork-sandbox mail send\`, which starts a new thread and throws away the earlier round. To run this round, send the body file with \`fork-sandbox mail reply --reply-to <message-id>\` (add --attach files if the seats cannot check the branch out)." >&2
fi
# shellcheck disable=SC2016  # ${FOCUS} is the literal placeholder text
# being searched for in the stripped body, not a variable to expand.
# The mirror of the refusal above, from the operator's side: a --focus
# for a template with no ${FOCUS} would be dropped by the fill below
# and the panel would wake to an ordinary round while the command line
# says this one is focused. A warning, not a refusal: the mail still
# composes, the same way an unfilled --summary does.
if [[ -n "$focus" && "$body" != *'${FOCUS}'* ]]; then
    echo "Warning: template '$template' has no \${FOCUS} placeholder, so --focus '$focus' does not reach the mail and the panel will wake to an ordinary round. Use a focused template, or fold the focus into --summary." >&2
fi
fill body FROM "$from"
fill body TO "$to"
fill body CC "$cc"
fill body SUBJECT "$subject"
fill body SUMMARY "$summary"
fill body FOCUS "$focus"
fill body BASE "$base"
fill body BRANCH "$branch"
fill body PATCH_COUNT "$patch_count"
fill body PANEL "$panel"
fill body HANDOFF "$handoff"

# fill() above already removes an empty own-line placeholder's line and
# one following blank, so this is now a backstop rather than the
# primary mechanism: it catches template shapes that rule doesn't cover,
# such as a placeholder followed by two blank lines at the very top. (A
# template that simply opens on a blank line of its own can't reach
# here: the awk comment-stripper above drops every leading blank line
# before $body is ever set, and the command substitution that captures
# it strips trailing newlines too.) Strip only leading newlines:
# indentation on the first real line, should a template ever want it,
# is the template's business.
while [[ "$body" == $'\n'* ]]; do
    body="${body#$'\n'}"
done

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
[[ -n "$hops" ]] && cmd+=(--hops "$hops")
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
