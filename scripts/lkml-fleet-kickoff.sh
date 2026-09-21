#!/usr/bin/env bash
# lkml-fleet-kickoff.sh — Compose (and optionally send) a fleet kickoff mail
# for a local patch series or single patch.
#
# Usage: lkml-fleet-kickoff.sh <repo> <range> --from <addr> --to <addr>
#            [--cc <addr>] --subject <subject> [--summary <text>]
#            [--focus <text>] [--template <file>] [--hops <n>]
#            [--ci-first <ci-addr>] [--version <n>]
#            [--allow-ambiguous-version] [--patches] [--seats <addr-list>]
#            [--send]
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
#              --reply-to <message-id>`. See --version below for the
#              related refusal when such a template's subject carries
#              no determinable version.
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
#              `git format-patch -v -n` so the per-patch reply messages'
#              own Subject lines agree with the cover subject instead of
#              contradicting it -- -n so a single-patch range, numbered
#              "0/1" on the cover, is numbered "1/1" on the one patch
#              message too, since format-patch does not number a
#              single-commit range on its own. A subject with no LEADING bracket
#              containing the word "PATCH" -- "[PATCH ...]", but also
#              "[RFC PATCH ...]", "[RESEND PATCH ...]" and other prefixed
#              forms real list traffic uses -- is stamped v1 by default
#              even without this flag -- an unmarked kickoff is the
#              defect this flag exists to fix, so stamping is not
#              opt-in. A subject that carries a version marker which is
#              not leading -- it follows a reply prefix such as "Re: ",
#              or another bracket precedes it -- is refused
#              unconditionally, whether or not --version was given and
#              whether or not the template is focused: stamping over it
#              would prepend a second bracket in front of the one
#              already there instead of replacing it, and passing
#              --version cannot fix a bracket that already exists, so
#              the fix named is to reword the subject instead. That v1
#              default also does not apply to a focused template (one
#              containing ${FOCUS}): such a round is a reply into an
#              existing thread that already has versions on the wire,
#              so a subject with no determinable version at all (no
#              bracket anywhere, leading or otherwise) and no --version
#              is refused instead, naming --version <n> as the fix. A
#              bare "v<digits>" in prose, or an unversioned
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
#              list. This detection is intentionally narrower than
#              the Versions section on lkml-fleet-status.sh: that parser
#              matches "v<digits>" anywhere in a Subject, by design, to
#              stay robust across however panel replies and other tools
#              format theirs. A subject with a stray "v<digits>" outside
#              this leading bracket (e.g. "fix the v2 parser") is still
#              stamped correctly here, but the final subject -- whether
#              just stamped or already marked -- is then re-parsed with
#              that same status-screen pipeline: if it would read as
#              more than one version -- a stray token and the marker
#              landing on distinct numbers -- the whole kickoff is
#              refused rather than sent, since a reply inherits the
#              Subject verbatim and the Versions section cannot tell a
#              real second round from a phantom one. This applies to an
#              already-marked subject too: the ambiguity may predate
#              this script, but the phantom round it produces on the
#              status screen is identical either way, so it is caught
#              here rather than left for the status screen to discover.
#              A stray token that happens to already match the marker's
#              version is not ambiguous and is let through. The stray
#              token is not always a rewording problem: a subsystem name
#              ("v4l2", "v9fs") or an upstream tag ("v6.12") in the
#              subject is not a word the operator can drop without
#              changing what the series is about. Pass
#              --allow-ambiguous-version to send anyway; the phantom
#              round this produces is display-only (see
#              --allow-ambiguous-version below) and refusing outright
#              left no way to run a truthful round on such a subject at
#              all.
# --allow-ambiguous-version
#              proceed with a subject the multi-version re-parse guard
#              (above) would otherwise refuse, printing a Warning
#              instead of an Error. Only reaches for this when the extra
#              "v<digits>" token lkml-fleet-status.sh's Versions section
#              will read is known not to be a real version: nothing else
#              consumes a subject-borne version -- lkml-mailbox.sh keys
#              off the X-Version header, not the Subject -- so the only
#              cost of proceeding is a phantom extra row on that one
#              status screen for this thread.
# --patches    format the range with `git format-patch`, post the cover
#              via `fork-sandbox mail send`, then post one
#              `fork-sandbox mail reply` per patch -- same sender, same
#              Reply-To-Id (the cover's own message id), subject taken
#              from the patch file's own Subject line (already numbered
#              by `git format-patch -n -v`), `To: @operator` so a patch
#              message never wakes anyone; it exists on the thread to be
#              read, the way a patch on a mailing list is. Without this
#              flag, the mail carries only the branch name for reviewers
#              to check out themselves. In print-only mode, since nothing
#              is actually sent, the cover's real message id does not
#              exist yet: the printed sequence opens with a
#              `cover_id=$(...)` shell assignment around the cover
#              command, followed by one `mail reply --reply-to
#              "$cover_id"` line per patch, so the whole sequence can be
#              pasted into a shell and run as one paste.
# --attach     deprecated alias for --patches; attachments are never
#              posted by this script -- kept only so an existing caller
#              spelling --attach still works, with a Warning pointing at
#              --patches.
# --seats      comma-separated fleet addresses -- seats and/or list
#              addresses such as @panel -- expanded through this
#              script's own lkml-fleet.sh wrapper (the same registry
#              --ci-first's gate consults) and stamped, de-duplicated in
#              first-seen order, as an X-Seats header on the COVER ONLY,
#              in the store's canonical address-list format (e.g.
#              "X-Seats: @core, @ci, @docs"). This is the seated-panel
#              roster lkml-render.py trusts for its convergence verdict:
#              a To:/Cc: header is wave-based on this transport and
#              cannot stand in for it. An address that does not resolve
#              REFUSES the whole kickoff rather than stamping a partial
#              or wrong roster. Optional: omitted, nothing changes for
#              existing callers. Never added to the per-patch replies
#              --patches posts; those are not review seats.
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
post_patches=0
send=0
hops=""
ci_first=""
version=""
version_given=0
allow_ambiguous_version=0
seats=""

while (( $# > 0 )); do
    case "$1" in
        --from|--to|--cc|--subject|--summary|--focus|--template|--hops|--ci-first|--version|--seats)
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
        --seats) seats="$2"; shift 2 ;;
        --allow-ambiguous-version) allow_ambiguous_version=1; shift ;;
        --patches) post_patches=1; shift ;;
        --attach) post_patches=1; echo "Warning: --attach is a deprecated alias for --patches; attachments are never posted -- this now posts one mail reply per patch instead. Use --patches." >&2; shift ;;
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
# Resolved as a sibling, the same way default_template is, so both
# --ci-first's gate and --seats's expansion consult lkml's own persona
# registry rather than whatever fleet the machine's ~/.config/fork-sandbox
# happens to describe. Without this they resolve against the wrong
# registry, or against none, and refuse (or stamp) for the wrong reason.
fleet_cmd="$script_dir/lkml-fleet.sh"
if [[ -n "$ci_first" ]]; then
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

seats_header=""
if [[ -n "$seats" ]]; then
    if [[ ! -x "$fleet_cmd" ]]; then
        echo "Error: --seats requires '$fleet_cmd', which is missing or not executable; expansion cannot be skipped." >&2
        exit 1
    fi
    declare -A seats_seen=()
    seats_expanded=()
    IFS=',' read -r -a seats_addrs <<<"$seats"
    for seats_addr in "${seats_addrs[@]}"; do
        # Trim surrounding whitespace so "@a, @b" (a space after the
        # comma, the natural way to type a list by hand) splits into
        # clean addresses instead of a literal leading-space name.
        seats_addr="${seats_addr#"${seats_addr%%[![:space:]]*}"}"
        seats_addr="${seats_addr%"${seats_addr##*[![:space:]]}"}"
        [[ -z "$seats_addr" ]] && continue
        if ! seats_expansion="$("$fleet_cmd" fleet expand "$seats_addr")"; then
            echo "Error: --seats address '$seats_addr' did not resolve; refusing to stamp a partial or wrong X-Seats roster." >&2
            exit 1
        fi
        while IFS= read -r seats_name; do
            [[ -z "${seats_name//[$'\t\r ']/}" ]] && continue
            if [[ -z "${seats_seen[$seats_name]+x}" ]]; then
                seats_seen[$seats_name]=1
                seats_expanded+=("$seats_name")
            fi
        done <<<"$seats_expansion"
    done
    if (( ${#seats_expanded[@]} == 0 )); then
        echo "Error: --seats '$seats' expanded to no addresses; refusing to stamp an empty X-Seats roster." >&2
        exit 1
    fi
    for seats_name in "${seats_expanded[@]}"; do
        if [[ -z "$seats_header" ]]; then
            seats_header="$seats_name"
        else
            seats_header="$seats_header, $seats_name"
        fi
    done
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
# (an earlier behaviour) silently suppressed the default v1 stamp for a
# subject like "fix the v2 scheduler entry" and blocked --version from
# reaching it at all, since the marker-conflict refusal above fired on
# the misdetected marker regardless of the flag's value. Not treating
# it as a marker lets --version reach the stamp again, but the
# multi-version re-parse guard further down can still refuse the
# result: only a --version equal to the stray prose token stamps
# cleanly, since any other value leaves two distinct "v<digits>" tokens
# in the final subject. leading_patch_prefix is the whole bracket,
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
# "No determinable version" is not the same as "no version anywhere in
# the subject": a reply-shaped subject like "Re: [PATCH v3 0/2] ..."
# carries one, just not leading (the leading-bracket regex above does
# not match past "Re: "), and a bracket that is not itself a PATCH
# marker can precede the real one too (e.g. "[net-next] Re: [PATCH v3
# 0/2] ..."). Stamping onto such a subject -- whether the v1 default or
# an operator-given --version -- would prepend a second, whole bracket
# in front of the one already there instead of replacing it, and if the
# given --version happens to equal the embedded marker's version, the
# multi-version re-parse guard further down dedups the two identical
# tokens down to one and lets the double-stamped subject through with
# no warning at all. So scan every bracket in the subject, not just the
# leftmost (which a leading non-PATCH bracket would otherwise hide the
# real marker behind), for one -- other than the already-detected
# leading bracket -- that carries the word "PATCH". This applies
# whether or not the template is focused: the corruption is the same
# either way, only the fix (reword, not --version) differs from the
# no-determinable-version case below.
non_leading_patch_bracket=""
if [[ -z "$existing_display" ]]; then
    rest="$subject"
    first_bracket=1
    while [[ "$rest" =~ \[([^]]*)\] ]]; do
        bracket="${BASH_REMATCH[0]}"
        content="${BASH_REMATCH[1]}"
        rest="${rest#*"$bracket"}"
        if (( first_bracket )); then
            first_bracket=0
            if [[ "$bracket" == "$leading_patch_prefix" ]]; then
                continue
            fi
        fi
        if [[ "$content" =~ (^|[^[:alnum:]])PATCH($|[^[:alnum:]]) ]]; then
            non_leading_patch_bracket="$bracket"
            break
        fi
    done
fi
if [[ -n "$non_leading_patch_bracket" ]]; then
    echo "Error: subject '$subject' carries a version marker that is not leading (it follows a reply prefix such as 'Re: ', or another bracket precedes it: '$non_leading_patch_bracket'); stamping would prepend a second bracket in front of the existing one instead of replacing it, corrupting the subject. Reword the subject to drop the stale marker/reply prefix -- passing --version cannot fix this, since the bracket it would stamp is already there." >&2
    exit 1
fi
# A focused round (template carries ${FOCUS}) is by definition a reply
# into a thread that already has versions on the wire, unlike a
# new-thread round for which the v1 default below is correct. If the
# subject carries no determinable version at all (no bracket, leading or
# otherwise, ruled out above) and the operator did not say --version,
# silently stamping v1 would mislabel the round, so refuse instead of
# defaulting. Scope is focused templates only -- a non-focused template
# keeps the v1 default untouched.
# shellcheck disable=SC2016  # ${FOCUS} is the literal placeholder text
# being searched for in the stripped body, not a variable to expand.
if [[ "$body" == *'${FOCUS}'* ]] && [[ -z "$existing_display" ]] && (( ! version_given )); then
    echo "Error: template '$template' contains \${FOCUS} and subject '$subject' carries no determinable version (no leading '[PATCH v<n> ...]' marker); a focused round replies into an existing thread that already has versions on the wire, so defaulting to v1 would mislabel it. Pass --version <n> to state the version explicitly." >&2
    exit 1
fi
effective_version="${existing_display#v}"
effective_version="${effective_version:-${version:-1}}"

tmpdir="$(mktemp -d)"
# Cleaned up unless something downstream tells the caller where to find
# it: print-only mode's success path prints a command sequence whose
# --body arguments (cover and, with --patches, each patch reply) name
# files under $tmpdir and a trailing Note pointing at the directory, for
# a caller to paste later, so it sets
# tmpdir_kept and cleanup leaves the directory alone. Every other exit
# -- every refusal above and below included -- never prints anything
# pointing at $tmpdir, so leaving it behind there would be a silent
# leak rather than a kept artifact.
tmpdir_kept=0
cleanup() { if (( ! tmpdir_kept )); then rm -rf -- "$tmpdir"; fi; }
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

# The final subject -- whether just stamped or already marked -- is
# re-parsed with the exact pipeline lkml-fleet-status.sh's
# fs_subject_versions() uses -- not because this script needs the
# numbers for anything else, but because that is the parser that will
# read this Subject once it is sent, and every reply in the thread
# inherits it verbatim ("Re: ..."). A subject with any other
# "v<digits>" token besides the marker (e.g. "fix the v2 parser"
# stamped to "[PATCH v1 0/2] fix the v2 parser", or an already-marked
# "[PATCH v2 0/2] fix the v3 parser" passed through as-is) parses here
# as more than one distinct version, and the == Versions == section
# would then report a second round for this thread that never
# happened, silently. Refuse rather than guess which token was meant;
# a stray token that happens to already equal the marker's version
# parses as one version and is not ambiguous.
#
# Run whether this script stamped the subject or found it already
# marked: the phantom round this produces on the status screen reads
# identically either way, so letting an already-marked subject through
# unchecked would be the same silent misreport this guard exists to
# close. Only the wording of the refusal differs below, since an
# already-marked subject was never stamped by this run.
#
# "Reword the subject" is not always possible: the extra token can be a
# subsystem name ("v4l2", "v9fs") or an upstream tag ("v6.12") that is
# part of what the series is about, not a word the operator chose.
# --allow-ambiguous-version is the escape hatch for that case: it turns
# this refusal into a Warning and lets the send proceed. That is safe
# to offer because the phantom round it produces is display-only --
# V_COUNT feeds nothing but this one printf in
# lkml-fleet-status.sh's == Versions == section, and lkml-mailbox.sh
# resolves a thread's version from the X-Version header, never from the
# Subject -- so the only cost of proceeding is a wrong extra row on
# that one status screen for this thread.
subject_versions="$(printf '%s\n' "$subject" | grep -oE '(^|[^[:alnum:]])v[0-9]+' | sed 's/^.*v//' | sort -un)"
if [[ "$(wc -l <<<"$subject_versions")" -gt 1 ]]; then
    subject_versions_list="$(paste -sd' ' - <<<"$subject_versions")"
    if (( allow_ambiguous_version )); then
        if [[ -z "$existing_display" ]]; then
            echo "Warning: stamping v${effective_version} produces subject '$subject', which lkml-fleet-status.sh's == Versions == section parses as $subject_versions_list -- more than one version for what is a single series. Sending anyway because --allow-ambiguous-version was given; the status screen will show a phantom extra version for this thread." >&2
        else
            echo "Warning: subject '$subject' already carries version marker '$existing_display', but lkml-fleet-status.sh's == Versions == section parses it as $subject_versions_list -- more than one version for what is a single series. Sending anyway because --allow-ambiguous-version was given; the status screen will show a phantom extra version for this thread." >&2
        fi
    else
        if [[ -z "$existing_display" ]]; then
            echo "Error: stamping v${effective_version} produces subject '$subject', which lkml-fleet-status.sh's == Versions == section parses as $subject_versions_list -- more than one version for what is a single series. Reword the subject so it carries no other \"v<digits>\" token, or pass --allow-ambiguous-version if the token names something else (a subsystem, an upstream tag) and cannot be reworded away; the status screen reads that token anywhere in the subject as a version of the series." >&2
        else
            echo "Error: subject '$subject' already carries version marker '$existing_display', but lkml-fleet-status.sh's == Versions == section parses it as $subject_versions_list -- more than one version for what is a single series. Reword the subject so it carries no other \"v<digits>\" token besides the marker, or pass --allow-ambiguous-version if it cannot be reworded away; the status screen reads that token anywhere in the subject as a version of the series." >&2
        fi
        exit 1
    fi
fi

# "a..b" or "a...b" both split on the first/last ".." respectively; a bare
# ref with no ".." leaves base and branch equal to the ref itself, a
# harmless degenerate case for the single-patch template's display.
base="${range%%..*}"
branch="${range##*..}"

# The template body tells reviewers to `git fetch origin $branch; git
# checkout $branch` as a genuine alternative to the per-patch reply
# messages -- unconditionally, in both variants -- so $branch must
# actually be a branch (or other symbolic ref) git can check out by
# that name in EITHER mode, not just whatever string happened to be on
# the right of "..", e.g. "HEAD" from a range like "HEAD~1..HEAD". A
# reviewer who takes that fallback with an unresolvable name silently
# reviews the wrong tree, so this check applies whether or not
# --patches was passed.
resolved_branch="$(git -C "$repo" rev-parse --abbrev-ref "$branch" 2>/dev/null || true)"
if [[ "$resolved_branch" != "$branch" ]]; then
    echo "Error: range '$range' does not resolve to a checkout-able branch name on its right side ('$branch'); the kickoff template always offers reviewers a fetch/checkout fallback and needs a real branch for it. Pass a range like '<base>..<branch>'." >&2
    exit 1
fi

# fill <content-varname> <PLACEHOLDER-NAME> <value> — literal substring
# replace, since ${var} values here never contain glob metacharacters.
# An own-line placeholder that fills to empty also removes its own line
# and one following blank (see below).
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
    echo "Warning: template '$template' contains \${FOCUS}: a focused round is a reply inside an existing thread, and the command below is \`fork-sandbox mail send\`, which starts a new thread and throws away the earlier round. To run this round, send the body file with \`fork-sandbox mail reply --reply-to <message-id>\` (follow with one more \`mail reply\` per patch, same --reply-to, if the seats cannot check the branch out)." >&2
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

# patch_subject() reads a produced patch file's own Subject: header --
# already numbered "i/K" by `git format-patch -n -v` above -- so each
# reply's subject is exactly what git chose, not retyped here. Two
# things a single `grep -m1` misses: `git format-patch` folds a header
# past 78 columns onto indented continuation lines (ordinary with the
# "[PATCH vN i/K] " prefix added), and RFC-2047-encodes a non-ASCII
# subject, sometimes as several adjacent encoded-words split across
# folds. The awk pass below un-folds the header before it is read;
# decoding the encoded-words needs an actual RFC 2047 decoder, which
# this repo already reaches for python3 to get elsewhere (see
# lkml-mailbox.sh, lkml-status.sh) with the same graceful-absence
# fallback -- here, a subject left encoded rather than decoded, since a
# folded-but-undecoded subject is still less wrong than one silently
# truncated.
patch_subject() {
    local f="$1" raw
    raw="$(awk '
        /^Subject: / { sub(/^Subject: /, ""); buf = $0; insub = 1; next }
        insub && /^[ \t]/ { sub(/^[ \t]+/, " "); buf = buf $0; next }
        insub { exit }
        END { print buf }
    ' "$f")"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import email.header, sys
raw = sys.stdin.read().rstrip("\n")
print(str(email.header.make_header(email.header.decode_header(raw))))
' <<<"$raw" 2>/dev/null || printf '%s\n' "$raw"
    else
        printf '%s\n' "$raw"
    fi
}

cover_cmd=(fork-sandbox mail send --from "$from" --to "$to")
[[ -n "$cc" ]] && cover_cmd+=(--cc "$cc")
[[ -n "$hops" ]] && cover_cmd+=(--hops "$hops")
[[ -n "$seats_header" ]] && cover_cmd+=(--header "X-Seats: $seats_header")
cover_cmd+=(--subject "$subject" --body "$body_file")

if (( send )); then
    if (( post_patches )); then
        # Command substitution only captures stdout, so the transport's
        # human-readable "sent ..." line on stderr still reaches the
        # operator's terminal even though $cover_id is assigned here.
        # Only done in this branch: capturing it unconditionally would
        # swallow `fork-sandbox mail send`'s printed message id even
        # when no patches follow, breaking `id=$(lkml-fleet-kickoff.sh
        # ... --send)` for the plain, no-`--patches` case that has no
        # need of it.
        cover_id="$("${cover_cmd[@]}")"
        [[ -n "$cover_id" ]] || { echo "Error: fork-sandbox mail send printed no message id on stdout; cannot post per-patch replies without one." >&2; exit 1; }
        for f in "${patches[@]}"; do
            fork-sandbox mail reply --from "$from" --to @operator \
                --reply-to "$cover_id" --subject "$(patch_subject "$f")" --body "$f"
        done
    else
        "${cover_cmd[@]}"
    fi
else
    if (( post_patches )); then
        # Print-only mode never actually sends the cover, so its real
        # message id does not exist yet. The printed sequence is a single
        # paste-able shell snippet: a `cover_id=$(...)` assignment around
        # the cover command, then one `mail reply --reply-to "$cover_id"`
        # line per patch that expands against it when run. The
        # `--reply-to "$cover_id"` token is written out raw, not through
        # the `printf '%q '` loop used for every other argument, so the
        # pasted line contains a literal, unescaped `"$cover_id"` that
        # expands at paste time instead of an inert copy of those
        # characters.
        # shellcheck disable=SC2016  # single-quoted on purpose: these are
        # the literal characters `cover_id=$(` and `"$cover_id" ` to appear
        # in the printed shell snippet, not expansions to run now.
        printf 'cover_id=$('
        printf '%q ' "${cover_cmd[@]}"
        printf ')\n'
        for f in "${patches[@]}"; do
            printf '%q ' fork-sandbox mail reply --from "$from" --to @operator --reply-to
            # shellcheck disable=SC2016
            printf '"$cover_id" '
            printf '%q ' --subject "$(patch_subject "$f")" --body "$f"
            printf '\n'
        done
    else
        printf '%q ' "${cover_cmd[@]}"
        printf '\n'
    fi
    printf 'Note: temp files for this command are left under %s -- nothing removes them; delete it yourself once done.\n' "$tmpdir" >&2
    tmpdir_kept=1
fi
