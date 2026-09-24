#!/usr/bin/env bash
# lkml-fleet-personas-test.sh — Confirm every fleet/personas/*.md file's
# frontmatter parses cleanly under the REAL fork-sandbox fleet parser,
# not a stub or a reimplementation. A fixture written by whoever wrote
# the persona files cannot catch a misread of that external format (see
# CLAUDE.md's "false green" hazard) -- only the real parser can, which
# is why this suite shells out to `fork-sandbox fleet resolve` instead
# of parsing the YAML itself.
#
# Usage: tests/lkml-fleet-personas-test.sh

set -uo pipefail

if ! command -v fork-sandbox >/dev/null 2>&1; then
    echo "SKIP: fork-sandbox not installed; this suite needs the real fleet parser on PATH."
    exit 0
fi

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
personas_dir="$repo_dir/fleet/personas"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

fleet_file="$(mktemp)"
trap 'rm -f -- "$fleet_file"' EXIT
printf 'agents: {}\nlists: {}\n' > "$fleet_file"

export FORK_SANDBOX_PERSONAS_DIR="$personas_dir"
export FORK_SANDBOX_FLEET_FILE="$fleet_file"

if out="$(fork-sandbox fleet check 2>&1)"; then
    ok "fleet check accepts every persona file's frontmatter"
else
    no "fleet check accepts every persona file's frontmatter" "$out"
fi

for f in "$personas_dir"/*.md; do
    name="$(basename "$f" .md)"
    resolved="$(fork-sandbox fleet resolve "$name" 2>&1)"
    description="$(printf '%s\n' "$resolved" | sed -n '6p')"
    if [[ -n "$description" ]]; then
        ok "$name resolves a non-empty description"
    else
        no "$name resolves a non-empty description" "$resolved"
    fi
done

# ci pins network: sealed in its own persona frontmatter -- the seat
# that executes untrusted code -- and it must resolve, not silently
# fall into an ignored comment.
ci_network="$(fork-sandbox fleet resolve ci 2>&1 | sed -n '4p')"
if [[ "$ci_network" == "sealed" ]]; then
    ok "ci resolves network=sealed"
else
    no "ci resolves network=sealed" "got '$ci_network'"
fi

# The ci persona's suite source is a two-path contract: an executable
# .agents/ci/run-tests at the repo root wins (the repo's own statement
# of how to run its whole suite); otherwise the persona falls back to
# tests/*-test.sh. Pin both paths and the contract path's reporting.
ci_md="$personas_dir/ci.md"
has() { # $1=file $2=fixed string $3=description
    if grep -qF -- "$2" "$1"; then
        ok "$3"
    else
        no "$3" "'$2' not found in $(basename "$1")"
    fi
}

has "$ci_md" '.agents/ci/run-tests' \
    "ci.md names the .agents/ci/run-tests entrypoint"
has "$ci_md" 'executable' \
    "ci.md requires the entrypoint to be executable"
has "$ci_md" 'repo root' \
    "ci.md runs the entrypoint from the repo root"
has "$ci_md" 'ls tests/*-test.sh' \
    "ci.md keeps the tests/*-test.sh fallback"
has "$ci_md" 'exit code' \
    "ci.md's contract path records the exit code"
has "$ci_md" 'non-zero' \
    "ci.md states a non-zero exit is not green"

# Only the seat that executes anything may grow the contract; the other
# eight personas must not pick it up.
mentioners=""
for f in "$personas_dir"/*.md; do
    if grep -qF '.agents/ci/run-tests' "$f"; then
        mentioners+=" $(basename "$f" .md)"
    fi
done
if [[ "$mentioners" == " ci" ]]; then
    ok "only ci.md mentions .agents/ci/run-tests"
else
    no "only ci.md mentions .agents/ci/run-tests" "mentioned in:$mentioners"
fi

# The reply-format section is a hard contract with the router, not
# advice: a malformed stanza is discarded wholesale and the seat
# respawned, so every persona carries the same salient section. The
# suite compares the sections against each other rather than trusting
# one file to be right.
extract_reply_format() {
    awk '/^## Reply format$/{ f = 1; print; next }
         f && /^## / { exit }
         f { print }' "$1"
}

count=0
baseline=""
baseline_name=""
for f in "$personas_dir"/*.md; do
    name="$(basename "$f" .md)"
    count=$(( count + 1 ))
    section="$(extract_reply_format "$f")"
    if [[ -z "$section" ]]; then
        no "$name carries the Reply format section" "no '## Reply format' heading"
        continue
    fi
    # pr-author is the one seat whose stanza may carry Version:, so its
    # section is the shared text plus a documented extension, checked
    # against the baseline after the loop rather than byte-compared here.
    if [[ "$name" == "pr-author" ]]; then
        pr_author_reply_format="$section"
        continue
    fi
    if [[ -z "$baseline" ]]; then
        baseline="$section"
        baseline_name="$name"
        ok "$name carries the Reply format section"
        continue
    fi
    if [[ "$section" == "$baseline" ]]; then
        ok "$name's Reply format section matches $baseline_name's"
    else
        no "$name's Reply format section matches $baseline_name's" "section text diverges"
    fi
done
if (( count == 11 )); then
    ok "fleet/personas holds exactly eleven personas"
else
    no "fleet/personas holds exactly eleven personas" "found $count"
fi
if [[ -n "$baseline" && -n "${pr_author_reply_format:-}" ]]; then
    if [[ "$pr_author_reply_format" == "$baseline"* ]]; then
        ok "pr-author's Reply format section is the shared section plus an extension"
    else
        no "pr-author's Reply format section is the shared section plus an extension" "shared text diverges"
    fi
    ext="${pr_author_reply_format#"$baseline"}"
    # shellcheck disable=SC2016  # literal backticks in the needle
    if grep -qF 'legal for this seat alone: `Version: <n>`' <<<"$ext"; then
        ok "pr-author's Reply format extension documents Version: as legal for this seat alone"
    else
        no "pr-author's Reply format extension documents Version: as legal for this seat alone"
    fi
    # No other persona may document Version: as a legal key.
    others=""
    for f in "$personas_dir"/*.md; do
        [[ "$(basename "$f" .md)" == "pr-author" ]] && continue
        if grep -qF 'Version: <n>' "$f"; then others+=" $(basename "$f" .md)"; fi
    done
    if [[ -z "$others" ]]; then
        ok "no persona but pr-author documents a Version: stanza key"
    else
        no "no persona but pr-author documents a Version: stanza key" "found in:$others"
    fi
else
    no "pr-author's Reply format section is the shared section plus an extension" "missing baseline or pr-author section"
fi
if [[ -n "$baseline" ]]; then
    if grep -q 'Reply-To-Id:' <<<"$baseline" && ! grep -q 'In-Reply-To:' <<<"$baseline"; then
        ok "Reply format section names Reply-To-Id and no In-Reply-To"
    else
        no "Reply format section names Reply-To-Id and no In-Reply-To"
    fi
    # @localhost is the dialect the router cannot parse; a persona that
    # shows it as an example primes the seats to write it.
    if ! grep -rqF '@localhost' "$personas_dir"; then
        ok "no persona file contains @localhost"
    else
        no "no persona file contains @localhost" "found '@localhost' in fleet/personas/"
    fi
fi

# Every reply delivered to a seat spawns a full session that re-reads
# and re-verifies before concluding "nothing to add" -- a terminal
# closing statement triggers a whole round of such wakes whose only
# possible outcome is silence. The triage section cuts that cost, so
# every persona must carry it, worded identically (the same reasoning
# as the Reply format pin above: a hard contract, compared against
# itself rather than trusted from one file).
extract_triage() {
    awk '/^## Triage the wake first$/{ f = 1; print; next }
         f && /^## / { exit }
         f { print }' "$1"
}

triage_baseline=""
triage_baseline_name=""
triage_baseline_set=0
for f in "$personas_dir"/*.md; do
    name="$(basename "$f" .md)"
    section="$(extract_triage "$f")"
    # pr-author replaces the generic triage with its own wake checklist
    # (pinned in its own block near the end of this file).
    if [[ "$name" == "pr-author" ]]; then
        if [[ -z "$section" ]]; then
            ok "pr-author.md does not carry the generic Triage the wake first section"
        else
            no "pr-author.md does not carry the generic Triage the wake first section" "found the heading"
        fi
        continue
    fi
    if (( ! triage_baseline_set )); then
        triage_baseline="$section"
        triage_baseline_name="$name"
        triage_baseline_set=1
        if [[ -n "$section" ]]; then
            ok "$name's Triage the wake first section is the comparison baseline"
        else
            no "$name's Triage the wake first section is the comparison baseline" "no '## Triage the wake first' heading"
        fi
        continue
    fi
    if [[ -n "$section" && "$section" == "$triage_baseline" ]]; then
        ok "$name's Triage the wake first section matches $triage_baseline_name's"
    else
        no "$name's Triage the wake first section matches $triage_baseline_name's" "section text diverges or missing"
    fi
done

# The shared Triage the wake first section's negative list names "a
# tag-only reply" without excluding blocking tags, so a bare NAK or
# Changes-requested addressed to the author would otherwise read as a
# no-reply wake. author.md's carve-out bullet is the fix, and it lives
# outside the byte-identical-pinned section above (in its own Rules
# list), so nothing else here would catch its removal.
has "$personas_dir/author.md" 'Your lane is the whole series' \
    "author.md's Rules list carries the whole-series carve-out"

# Triage (above) cuts the cost of a no-op REPLY after a seat is woken;
# it does nothing about the wake itself, which is the part that is
# paid for. A v3 panel flight measured the gap directly: one
# productive distiller wake next to three no-op wakes seats bought it
# by mirroring the kickoff's own Cc, plus a map sent To: @panel that
# spawned the whole panel before wave one's promised ordering had
# played out. The Addressing the distiller section is the fix, pinned
# the same way as Triage: present and byte-identical across the nine
# non-distiller personas, and absent from distiller.md, which carries
# the opposite-direction rule instead.
extract_addressing_distiller() {
    awk '/^## Addressing the distiller$/{ f = 1; print; next }
         f && /^## / { exit }
         f { print }' "$1"
}

addressing_baseline=""
addressing_baseline_name=""
addressing_baseline_set=0
addressing_count=0
for f in "$personas_dir"/*.md; do
    name="$(basename "$f" .md)"
    section="$(extract_addressing_distiller "$f")"
    if [[ "$name" == "distiller" ]]; then
        if [[ -z "$section" ]]; then
            ok "distiller.md does not carry the Addressing the distiller section"
        else
            no "distiller.md does not carry the Addressing the distiller section" "found '## Addressing the distiller' heading"
        fi
        continue
    fi
    if [[ -z "$section" ]]; then
        no "$name carries the Addressing the distiller section" "no '## Addressing the distiller' heading"
        continue
    fi
    addressing_count=$(( addressing_count + 1 ))
    if (( ! addressing_baseline_set )); then
        addressing_baseline="$section"
        addressing_baseline_name="$name"
        addressing_baseline_set=1
        ok "$name's Addressing the distiller section is the comparison baseline"
        continue
    fi
    if [[ "$section" == "$addressing_baseline" ]]; then
        ok "$name's Addressing the distiller section matches $addressing_baseline_name's"
    else
        no "$name's Addressing the distiller section matches $addressing_baseline_name's" "section text diverges"
    fi
done
if (( addressing_count == 10 )); then
    ok "Addressing the distiller section appears in exactly the ten non-distiller personas"
else
    no "Addressing the distiller section appears in exactly the ten non-distiller personas" "found in $addressing_count"
fi

# The byte-identity comparison above only proves the nine copies agree
# with each other -- it would pass just as green if all nine were
# edited to say nothing at once. Pin the load-bearing content itself,
# the same way the Reply format and Triage sections are backed by
# content assertions above, not just mutual comparison.
if [[ -n "$addressing_baseline" ]]; then
    if grep -qF 'only when your mail asks it a' <<<"$addressing_baseline"; then
        ok "Addressing the distiller section requires a concrete question before addressing it"
    else
        no "Addressing the distiller section requires a concrete question before addressing it"
    fi
    if grep -qF 'Do not mirror the kickoff' <<<"$addressing_baseline"; then
        ok "Addressing the distiller section forbids mirroring the kickoff's own Cc"
    else
        no "Addressing the distiller section forbids mirroring the kickoff's own Cc"
    fi
    if grep -qF 'reply-all' <<<"$addressing_baseline"; then
        ok "Addressing the distiller section names the reply-all default hazard"
    else
        no "Addressing the distiller section names the reply-all default hazard"
    fi
    # The explicit To: rule must describe reply-all's real recipient
    # set (parent's From + To + Cc, not just To:/Cc:) and tell seats to
    # subtract from it rather than reconstruct a fresh list -- a fresh
    # list built from the kickoff's visible To: silently drops the
    # author, who reaches a reply only via the kickoff's From:.
    # shellcheck disable=SC2016  # literal backtick in the needle
    if grep -qF '`From:`, `To:` and `Cc:` into yours' <<<"$addressing_baseline"; then
        ok "Addressing the distiller section's reply-all description includes From:"
    else
        no "Addressing the distiller section's reply-all description includes From:"
    fi
    if grep -qF 'reply-all set' <<<"$addressing_baseline" && grep -qF 'not a fresh list' <<<"$addressing_baseline"; then
        ok "Addressing the distiller section tells seats to subtract from reply-all, not rebuild it"
    else
        no "Addressing the distiller section tells seats to subtract from reply-all, not rebuild it"
    fi
    # The subtraction base must be each persona's OWN addressing rules,
    # not a hardcoded "the reply-all set": ci.md's Wave one section and
    # secretary.md's Addressing your reply section both already name a
    # To: that is not reply-all, and a rule that overrides either with
    # a reply-all-derived address silently defeats it (ci: the panel
    # never wakes; secretary: a one-reader summary wakes the whole
    # panel). See docs/ci-first-ordering.md for the wave-one contract.
    if grep -qF 'already have you addressing' <<<"$addressing_baseline"; then
        ok "Addressing the distiller section subtracts from each persona's own addressing, not a hardcoded reply-all"
    else
        no "Addressing the distiller section subtracts from each persona's own addressing, not a hardcoded reply-all"
    fi
    # The kickoff Cc'ing @distiller is a site convention (the template's
    # ${CC} is documented as "optional observers", fleet/kickoffs/*.md
    # never sets it), not a repo-wide guarantee -- so the fold-in clause
    # must be conditional on it, not asserted as always true.
    if grep -qF "If the cover Cc'd" <<<"$addressing_baseline"; then
        ok "Addressing the distiller section hedges the kickoff-Cc'd-distiller fold-in as conditional"
    else
        no "Addressing the distiller section hedges the kickoff-Cc'd-distiller fold-in as conditional"
    fi
fi

# distiller.md's own outbound rule: summaries and maps go To:
# @operator, never To:/Cc: the panel or a seat, except to answer a
# seat's direct question -- pin its load-bearing strings the same way
# ci.md's contract-path strings are pinned above. The heading and the
# prohibition itself are pinned too: the two has() checks that existed
# before this (To: @operator, the answer-the-asker-alone exception)
# would both still pass if the prohibition sentence were deleted.
extract_addressing_outbound() {
    awk '/^## Addressing your reply$/{ f = 1; print; next }
         f && /^## / { exit }
         f { print }' "$1"
}
if [[ -n "$(extract_addressing_outbound "$personas_dir/distiller.md")" ]]; then
    ok "distiller.md carries the Addressing your reply section"
else
    no "distiller.md carries the Addressing your reply section" "no '## Addressing your reply' heading"
fi
has "$personas_dir/distiller.md" 'To: @operator' \
    "distiller.md's Addressing your reply section names To: @operator"
has "$personas_dir/distiller.md" "seat's direct question" \
    "distiller.md's Addressing your reply section carries the answer-the-asker-alone exception"
# shellcheck disable=SC2016  # literal backtick in the needle
has "$personas_dir/distiller.md" 'never `To:` or `Cc:` the panel, a list, or any individual seat' \
    "distiller.md's Addressing your reply section forbids panel/list/seat addressing"
has "$personas_dir/distiller.md" 'reply-all' \
    "distiller.md's Addressing your reply section names the reply-all default hazard"

# Wake prompts are moving to trigger-only delivery (the fork-sandbox
# lane's half of this change), so a reply that only makes sense next to
# the rest of the thread is a reply a woken seat cannot act on. Every
# persona's Reply format section must carry the quote-reply instruction,
# worded once and reused verbatim -- pinned the same way as the section
# itself above, so this is redundant with that byte-identical check but
# still asserted directly per persona per the operator's own ask.
for f in "$personas_dir"/*.md; do
    name="$(basename "$f" .md)"
    has "$f" "Quote what you're answering" \
        "$name carries the quote-reply discipline"
done

# The message-per-patch rewrite of author.md's step 5 replaces the old
# single-body-inline instruction; the stable phrase below is the one
# this round introduced, and the old instruction's own wording must be
# gone, not just superseded further down the file.
has "$personas_dir/author.md" 'one message per patch' \
    "author.md instructs one message per patch"
if grep -qF 'paste each patch into the reply' "$personas_dir/author.md"; then
    no "author.md no longer instructs inlining the whole series into one reply"
else
    ok "author.md no longer instructs inlining the whole series into one reply"
fi

# The six reviewer seats carry one byte-identical section on who hears
# their review and what verdict they cast. The panel protocol has no
# orchestrator: the author acts only once every Panel seat has replied on
# the current version, so a reviewer that does not reply -- or replies
# without a verdict -- stalls or falsely greens the round. Compared
# against each other AND pinned on content, for the same reason as the
# sections above.
extract_verdict_section() {
    awk '/^## Who hears your review, and your verdict$/{ f = 1; print; next }
         f && /^## / { exit }
         f { print }' "$1"
}
reviewers="architecture core docs newcomer security tests"
verdict_baseline=""
for name in $reviewers; do
    f="$personas_dir/$name.md"
    section="$(extract_verdict_section "$f")"
    if [[ -z "$section" ]]; then
        no "$name carries the verdict section" "no '## Who hears your review, and your verdict' heading"
        continue
    fi
    if [[ -z "$verdict_baseline" ]]; then
        verdict_baseline="$section"
        ok "$name carries the verdict section (comparison baseline)"
    elif [[ "$section" == "$verdict_baseline" ]]; then
        ok "$name's verdict section matches the baseline"
    else
        no "$name's verdict section matches the baseline" "section text diverges"
    fi
    # Placed right before Triage: the heading that follows it is Triage.
    next_heading="$(awk '/^## Who hears your review, and your verdict$/{ f = 1; next }
                         f && /^## / { print; exit }' "$f")"
    if [[ "$next_heading" == "## Triage the wake first" ]]; then
        ok "$name's verdict section sits right before Triage the wake first"
    else
        no "$name's verdict section sits right before Triage the wake first" "next heading: '$next_heading'"
    fi
done
for name in ci author distiller secretary pr-author; do
    if [[ -z "$(extract_verdict_section "$personas_dir/$name.md")" ]]; then
        ok "$name.md does not carry the reviewer verdict section"
    else
        no "$name.md does not carry the reviewer verdict section" "found the heading"
    fi
done
if [[ -n "$verdict_baseline" ]]; then
    # The section is flattened to one line so a needle may span a wrap.
    flat="$(tr '\n' ' ' <<<"$verdict_baseline" | sed 's/  */ /g')"
    # shellcheck disable=SC2016  # literal backticks in the needles
    for needle in \
        '`Author:`' \
        '`To:` the Author' \
        'Never rely on reply-all' \
        '`X-Review-Target`' \
        '`git rev-parse HEAD`' \
        'LAST non-empty line' \
        '`Reviewed-by: <your' \
        '`Acked-by: <your' \
        '`Tested-by: <your' \
        '`Changes-requested`' \
        '`Question`' \
        '`NAK`' \
        'Having nothing to add is' \
        'does not carry forward'
    do
        if grep -qF -- "$needle" <<<"$flat"; then
            ok "verdict section pins: $needle"
        else
            no "verdict section pins: $needle" "not found"
        fi
    done
fi

# secretary: the terminal message of a panel thread. Its Panel-* trailer
# lines are a machine contract read by a separate parser, so spelling and
# order are pinned exactly, and the summary goes to @operator alone.
sec="$personas_dir/secretary.md"
extract_closing() {
    awk '/^## Closing the panel$/{ f = 1; print; next }
         f && /^## / { exit }
         f { print }' "$1"
}
closing="$(extract_closing "$sec")"
if [[ -n "$closing" ]]; then
    ok "secretary.md carries the Closing the panel section"
else
    no "secretary.md carries the Closing the panel section" "no '## Closing the panel' heading"
fi
panel_lines="$(grep -E '^ +Panel-[A-Za-z]+: ' <<<"$closing" | sed 's/^ *//')"
expected_panel_lines='Panel-Version: <N>
Panel-Status: CONVERGED
Panel-Verdict: SIGNED-OFF'
if [[ "$panel_lines" == "$expected_panel_lines" ]]; then
    ok "secretary.md shows the three Panel-* lines, in order"
else
    no "secretary.md shows the three Panel-* lines, in order" "got: $panel_lines"
fi
has "$sec" 'To: @operator' \
    "secretary.md addresses its summary To: @operator"
if grep -qF 'whoever invoked you' "$sec"; then
    no "secretary.md no longer addresses whoever invoked it" "old wording still present"
else
    ok "secretary.md no longer addresses whoever invoked it"
fi
# shellcheck disable=SC2016  # literal backticks in the needles
{
has "$sec" '`Panel-Status` is `CONVERGED` only when every' \
    "secretary.md ties CONVERGED to every Panel seat's non-blocking verdict"
has "$sec" 'NO `Panel-Verdict:` line at all' \
    "secretary.md writes no Panel-Verdict line unless converged"
has "$sec" '`IN-PROGRESS`' \
    "secretary.md names Panel-Status IN-PROGRESS"
has "$sec" '`SIGNED-OFF` if N is 1' \
    "secretary.md signs off only a converged v1"
has "$sec" '`RESPIN` if N is greater than 1' \
    "secretary.md respins a converged later version"
has "$sec" 'verify it from the thread yourself' \
    "secretary.md verifies verdicts from the thread, not the Author's summary"
has "$sec" 'last in the body' \
    "secretary.md makes the Panel-* lines last in the body"
}

# pr-author: the fleet's in-cluster PR author. Its wake checklist IS the
# round protocol (no orchestrator drives the rounds), so the strings
# that carry the protocol are pinned, not just the frontmatter.
pra="$personas_dir/pr-author.md"
pra_fm="$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f { print }' "$pra")"
if grep -qE '^description: .+' <<<"$pra_fm"; then
    ok "pr-author.md frontmatter has a description"
else
    no "pr-author.md frontmatter has a description"
fi
pra_resolved="$(fork-sandbox fleet resolve pr-author 2>&1)"
if [[ "$(sed -n '1p' <<<"$pra_resolved")" == "claude" && "$(sed -n '2p' <<<"$pra_resolved")" == "opus" ]]; then
    ok "pr-author resolves harness=claude model=opus"
else
    no "pr-author resolves harness=claude model=opus" "$pra_resolved"
fi
# backend and review-target are fleet.yaml-only; the real parser refuses
# them in frontmatter, and the persona must not try.
if grep -qE '^(backend|review-target):' <<<"$pra_fm"; then
    no "pr-author.md frontmatter carries no fleet.yaml-only keys" "found backend: or review-target:"
else
    ok "pr-author.md frontmatter carries no fleet.yaml-only keys"
fi
has "$pra" '## The wake checklist' \
    "pr-author.md carries the wake checklist section"
has "$pra" 'Frozen-Head:' \
    "pr-author.md reads the frozen head from the root's Frozen-Head line"
has "$pra" 'X-Version' \
    "pr-author.md counts replies per version by X-Version"
has "$pra" 'write no reply file and end the' \
    "pr-author.md ends the wake with no reply until every Panel seat has replied"
# shellcheck disable=SC2016  # literal backticks in the needle
has "$pra" '`Version:` is N+1' \
    "pr-author.md documents the Version: N+1 cover"
has "$pra" 'per wake, on the cover only' \
    "pr-author.md allows one Version: per wake, on the cover only"
has "$pra" 'Post no per-patch messages' \
    "pr-author.md says no per-patch messages"
has "$pra" 'git range-diff' \
    "pr-author.md puts a range-diff in the cover's Since section"
has "$pra" 'GIT_SEQUENCE_EDITOR=true' \
    "pr-author.md re-rolls with autosquash"
has "$pra" 'Comment-only:' \
    "pr-author.md keeps the Comment-only trailer rule"

# pr-review kickoff: the roster lines are how every seat finds the
# author, the panel, the secretary and the frozen head, so each must sit
# alone at the start of its own line in the body (after the header
# comment), spelled exactly as the personas read them.
prk="$repo_dir/fleet/kickoffs/pr-review.md"
if [[ -f "$prk" ]]; then
    ok "fleet/kickoffs/pr-review.md exists"
    prk_body="$(awk 'BEGIN { c = 0 } c == 0 && /^<!--/ { c = 1 } c == 1 { if (index($0, "-->")) c = 2; next } { print }' "$prk")"
    # shellcheck disable=SC2016  # ${...} is the literal placeholder text
    for roster in 'Author: ${AUTHOR}' 'Panel: ${PANEL}' 'Secretary: ${SECRETARY}' \
                  'Version-Limit: ${VERSION_LIMIT}' 'Frozen-Head: ${FROZEN_HEAD}'; do
        if grep -qxF -- "$roster" <<<"$prk_body"; then
            ok "pr-review.md body carries '$roster' alone on its line"
        else
            no "pr-review.md body carries '$roster' alone on its line" "not found as a whole line"
        fi
    done
    # shellcheck disable=SC2016  # ${...} is the literal placeholder text
    for ph in '${SUMMARY}' '${BASE}' '${BRANCH}' '${PATCH_COUNT}'; do
        if grep -qF -- "$ph" <<<"$prk_body"; then
            ok "pr-review.md body uses $ph"
        else
            no "pr-review.md body uses $ph"
        fi
    done
    has "$prk" 'Silence is NOT a' \
        "pr-review.md says silence is not a valid outcome"
    has "$prk" 'lkml-fleet-kickoff.sh --template pr-review' \
        "pr-review.md header points at the kickoff script that fills its placeholders"
    if grep -qF 'does not yet fill' "$prk"; then
        no "pr-review.md drops the stale 'does not yet fill' note" "still present"
    else
        ok "pr-review.md drops the stale 'does not yet fill' note"
    fi
    if grep -qF 'Silence is a valid outcome' "$prk"; then
        no "pr-review.md does not call silence valid" "series-review's wording leaked in"
    else
        ok "pr-review.md does not call silence valid"
    fi
else
    no "fleet/kickoffs/pr-review.md exists" "missing"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
