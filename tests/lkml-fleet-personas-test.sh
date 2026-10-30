#!/usr/bin/env bash
# lkml-fleet-personas-test.sh — Confirm every fleet/personas/*.md file's
# frontmatter parses cleanly under the REAL fork-sandbox fleet parser,
# not a stub or a reimplementation. A fixture written by whoever wrote
# the persona files cannot catch a misread of that external format (see
# CLAUDE.md's "false green" hazard) -- only the real parser can, which
# is why this suite shells out to `fork-sandbox fleet resolve` instead
# of parsing the YAML itself. Without fork-sandbox on PATH those checks
# SKIP and the rest of the suite still runs.
#
# The text checks run on each seat's assembled text: the persona file,
# then the fleet/prompts/protocol-<name>.md its `protocol:` frontmatter
# names, the order fork-sandbox prints them in at wake time. A reviewer
# persona is role-only; the shared reviewer protocol lives once, in
# protocol-reviewer.md, and the machinery seats' own copies of its
# sections are compared against it.
#
# Usage: tests/lkml-fleet-personas-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
personas_dir="$repo_dir/fleet/personas"
prompts_dir="$repo_dir/fleet/prompts"
reviewers="architecture core devils-advocate docs newcomer operability second-opinion security tests"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fleet_file="$work/fleet.yaml"
printf 'agents: {}\nlists: {}\n' > "$fleet_file"

export FORK_SANDBOX_PERSONAS_DIR="$personas_dir"
export FORK_SANDBOX_PROMPTS_DIR="$prompts_dir"
export FORK_SANDBOX_FLEET_FILE="$fleet_file"

have_fork_sandbox=false
command -v fork-sandbox >/dev/null 2>&1 && have_fork_sandbox=true
if ! $have_fork_sandbox; then
    echo "SKIP: fork-sandbox not installed; the fleet parser checks need it on PATH."
else
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

# core's bug-hunt first pass asks for high effort; on a claude seat
# `thinking` is what becomes `claude --effort`, so it must resolve.
core_thinking="$(fork-sandbox fleet resolve core 2>&1 | sed -n '3p')"
if [[ "$core_thinking" == "high" ]]; then
    ok "core resolves thinking=high"
else
    no "core resolves thinking=high" "got '$core_thinking'"
fi

# The pi reviewers name the harness and nothing else: which model and
# endpoint they run on is site config, carried by the fleet entry. A
# model in the frontmatter would pin a backend into a public persona.
for name in operability second-opinion; do
    resolved="$(fork-sandbox fleet resolve "$name" 2>&1)"
    harness="$(sed -n '1p' <<<"$resolved")"
    model="$(sed -n '2p' <<<"$resolved")"
    if [[ "$harness" == "pi" && -z "$model" ]]; then
        ok "$name resolves harness=pi with no model"
    else
        no "$name resolves harness=pi with no model" "got harness '$harness', model '$model'"
    fi
done
da="$(fork-sandbox fleet resolve devils-advocate 2>&1 | sed -n '1,3p' | tr '\n' ' ')"
if [[ "$da" == "claude opus high " ]]; then
    ok "devils-advocate resolves claude/opus/thinking=high"
else
    no "devils-advocate resolves claude/opus/thinking=high" "got '$da'"
fi
fi

# Assemble each seat's text the way the protocol slot does: the persona
# file, then the protocol file its frontmatter names, verbatim. Every
# text check below reads these, so a section a reviewer gets from the
# shared protocol is checked exactly where the seat sees it.
frontmatter_protocol() {
    awk 'NR == 1 && $0 != "---" { exit }
         NR > 1 && /^---$/ { exit }
         NR > 1 && sub(/^protocol:[ \t]*/, "") { print; exit }' "$1"
}
body_after_frontmatter() {
    awk 'NR == 1 && $0 == "---" { fm = 1; next }
         fm && /^---$/ { fm = 0; next }
         !fm { print }' "$1"
}
texts_dir="$work/texts"; mkdir -p -- "$texts_dir"
for f in "$personas_dir"/*.md; do
    name="$(basename "$f" .md)"
    cp -- "$f" "$texts_dir/$name.md"
    protocol="$(frontmatter_protocol "$f")"
    [[ -n "$protocol" ]] || continue
    if [[ -f "$prompts_dir/protocol-$protocol.md" ]]; then
        cat -- "$prompts_dir/protocol-$protocol.md" >> "$texts_dir/$name.md"
    else
        no "$name's protocol file exists" "no $prompts_dir/protocol-$protocol.md"
    fi
done

# A reviewer persona is role-only: it names the shared protocol, and
# carries none of the protocol's sections itself.
protocol_file="$prompts_dir/protocol-reviewer.md"
if [[ -f "$protocol_file" ]]; then
    ok "fleet/prompts/protocol-reviewer.md exists"
else
    no "fleet/prompts/protocol-reviewer.md exists" "missing"
fi
for name in $reviewers; do
    f="$personas_dir/$name.md"
    check "$name names protocol: reviewer" "reviewer" "$(frontmatter_protocol "$f")"
    if grep -qxF '## Tier focus and recheck scope' "$f"; then
        no "$name.md does not carry the protocol tail itself" "found '## Tier focus and recheck scope'"
    else
        ok "$name.md does not carry the protocol tail itself"
    fi
    dup="$(grep -xF -f <(grep '^## ' "$protocol_file" 2>/dev/null) "$f" | tr '\n' ' ')"
    if [[ -z "$dup" ]]; then
        ok "$name.md repeats no protocol section heading"
    else
        no "$name.md repeats no protocol section heading" "found: $dup"
    fi
done
for name in ci author distiller secretary pr-author; do
    check "$name names no protocol (machinery keeps its own text)" "" "$(frontmatter_protocol "$personas_dir/$name.md")"
done
# The protocol opens with the blank line that ends the role text, so a
# persona body ends on its last line of prose and an editor trimming
# trailing blank lines cannot change the assembled prompt.
check "protocol-reviewer.md opens with the separating blank line" "" "$(head -n 1 "$protocol_file" 2>/dev/null)"
check "protocol-reviewer.md's first heading is the tier focus section" \
    "## Tier focus and recheck scope" "$(sed -n '2p' "$protocol_file" 2>/dev/null)"
# Moving the tail out of the personas changed no seat's prompt: each
# reviewer's body plus the protocol file is byte-identical to the body
# its persona file carried before the split. Pinned as a hash of that
# assembled body so drift in either half fails here; a deliberate edit
# to a persona or the protocol updates its hash in the same commit.
while read -r name want; do
    got="$( { body_after_frontmatter "$personas_dir/$name.md"; cat -- "$protocol_file"; } 2>/dev/null \
            | sha256sum | cut -d' ' -f1)"
    check "$name's body + protocol-reviewer.md is its pre-split body" "$want" "$got"
done <<'HASHES'
architecture 0610ef60a6296739beb5018d14a553a5acf03e622f801a5058b1025496303fe3
core 952823825c958b55e6fbb051d3bb8da9900af101d58dc16b0c728062f171e858
devils-advocate fc8bcbc80874bafe7090c8e65bbfbcd432b53349d3b6424e829ebcb977df7870
docs f99c94f5a3b3ae3811e5eaeb3bc4de0e1922ec78df756bf53e4075552d99cd6e
newcomer 7b29708aaede99819a91220160d346d0ae04a7c0dc96203b559f306236a73a84
operability 4f5e4ba909b9b75ef8bb32eda81bd0bdcf6bca4cb275e736f0daf0188e4614a6
second-opinion e59653b19195d40b2daaf4442a94c451a96631a3e508e14bcad2d1f8c4ea9b9b
security c5581d247bb3d569ecf3f9d444961b8ec3eff23a304974b91099d9c7d5d150e0
tests 1c1f26198505bfe4f8866c5c525e1b6358d6177ea11716c2d154d9cf2f9e95b1
HASHES

# The ci persona's suite source is a two-path contract: an executable
# .agents/ci/run-tests at the repo root wins (the repo's own statement
# of how to run its whole suite); otherwise the persona falls back to
# tests/*-test.sh. Pin both paths and the contract path's reporting.
ci_md="$texts_dir/ci.md"
has_flat() { # like has, but the file is flattened so a needle may span a wrap
    if tr '\n' ' ' < "$1" | sed 's/  */ /g' | grep -qF -- "$2"; then
        ok "$3"
    else
        no "$3" "'$2' not found in $(basename "$1")"
    fi
}
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
for f in "$texts_dir"/*.md; do
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
for f in "$texts_dir"/*.md; do
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
if (( count == 14 )); then
    ok "fleet/personas holds exactly fourteen personas"
else
    no "fleet/personas holds exactly fourteen personas" "found $count"
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
    for f in "$texts_dir"/*.md; do
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
    if ! grep -rqF '@localhost' "$texts_dir"; then
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
for f in "$texts_dir"/*.md; do
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
has "$texts_dir/author.md" 'Your lane is the whole series' \
    "author.md's Rules list carries the whole-series carve-out"

# Triage (above) cuts the cost of a no-op REPLY after a seat is woken;
# it does nothing about the wake itself, which is the part that is
# paid for. A v3 panel flight measured the gap directly: one
# productive distiller wake next to three no-op wakes seats bought it
# by mirroring the kickoff's own Cc, plus a map sent To: @panel that
# spawned the whole panel before wave one's promised ordering had
# played out. The Addressing the distiller section is the fix, pinned
# the same way as Triage: present and byte-identical across the thirteen
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
for f in "$texts_dir"/*.md; do
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
if (( addressing_count == 13 )); then
    ok "Addressing the distiller section appears in exactly the thirteen non-distiller personas"
else
    no "Addressing the distiller section appears in exactly the thirteen non-distiller personas" "found in $addressing_count"
fi

# The byte-identity comparison above only proves the thirteen copies agree
# with each other -- it would pass just as green if all thirteen were
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
if [[ -n "$(extract_addressing_outbound "$texts_dir/distiller.md")" ]]; then
    ok "distiller.md carries the Addressing your reply section"
else
    no "distiller.md carries the Addressing your reply section" "no '## Addressing your reply' heading"
fi
has "$texts_dir/distiller.md" 'To: @operator' \
    "distiller.md's Addressing your reply section names To: @operator"
has "$texts_dir/distiller.md" "seat's direct question" \
    "distiller.md's Addressing your reply section carries the answer-the-asker-alone exception"
# shellcheck disable=SC2016  # literal backtick in the needle
has "$texts_dir/distiller.md" 'never `To:` or `Cc:` the panel, a list, or any individual seat' \
    "distiller.md's Addressing your reply section forbids panel/list/seat addressing"
has "$texts_dir/distiller.md" 'reply-all' \
    "distiller.md's Addressing your reply section names the reply-all default hazard"

# Wake prompts are moving to trigger-only delivery (the fork-sandbox
# lane's half of this change), so a reply that only makes sense next to
# the rest of the thread is a reply a woken seat cannot act on. Every
# persona's Reply format section must carry the quote-reply instruction,
# worded once and reused verbatim -- pinned the same way as the section
# itself above, so this is redundant with that byte-identical check but
# still asserted directly per persona per the operator's own ask.
for f in "$texts_dir"/*.md; do
    name="$(basename "$f" .md)"
    has "$f" "Quote what you're answering" \
        "$name carries the quote-reply discipline"
done

# The message-per-patch rewrite of author.md's step 5 replaces the old
# single-body-inline instruction; the stable phrase below is the one
# this round introduced, and the old instruction's own wording must be
# gone, not just superseded further down the file.
has "$texts_dir/author.md" 'one message per patch' \
    "author.md instructs one message per patch"
if grep -qF 'paste each patch into the reply' "$texts_dir/author.md"; then
    no "author.md no longer instructs inlining the whole series into one reply"
else
    ok "author.md no longer instructs inlining the whole series into one reply"
fi

# The nine reviewer seats carry one byte-identical section on who hears
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
verdict_baseline=""
for name in $reviewers; do
    f="$texts_dir/$name.md"
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
    if [[ -z "$(extract_verdict_section "$texts_dir/$name.md")" ]]; then
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
        '`@operator`' \
        'FIRST non-empty line' \
        '`X-Lkml-Question-Timeout' \
        'leaves you owing a verdict' \
        'does not carry forward' \
        'against the code at the new version' \
        'every reply you post carries exactly one verdict' \
        'with a rebuttal' \
        'Hold only with a concrete failure scenario' \
        'If you cannot name one, withdraw' \
        'goes to `@core` for a ruling' \
        '`Overrule: <id of your message>`'
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
sec="$texts_dir/secretary.md"
# shellcheck disable=SC2016  # literal backticks in the needle
has_flat "$sec" 'a `Question` on a message that is `To:` or `Cc:` `@operator`, given beside a non-blocking trailer' \
    "secretary.md leaves an operator question beside a verdict to the gate"
has_flat "$texts_dir/tests.md" 'CI not having reported is not' \
    "tests.md does not let pending CI shape its verdict"
# A seat once blocked a one-line permission fix for lacking a test that
# would fail if someone reverted the line: true of every line.
has_flat "$texts_dir/tests.md" '"Someone could revert this line" is not one' \
    "tests.md does not count a deliberate revert as a bug a test must catch"
# The rebuttal sidebar and its tie-break: the author argues a block in a
# reply to the seat (no version), a held block goes to @core, @core's own
# to @operator, and a ruling is a machine-read `Overrule: <id>` line.
# shellcheck disable=SC2016  # literal backticks in the needles
{
pa="$texts_dir/pr-author.md"
has_flat "$pa" '## Arguing a block' "pr-author.md has the Arguing a block section"
has_flat "$pa" 'Arguing is part of the job' "pr-author.md says arguing is expected"
has_flat "$pa" 'Challenge any block that does not name a concrete failure' "pr-author.md challenges a block with no concrete failure"
has_flat "$pa" 'a deliberate revert is not a bug a test must catch' "pr-author.md names the revert-pinning test as arguable"
has_flat "$pa" 'run **Arguing a block** (below) and do not re-roll' "pr-author.md decides a dispute before a re-roll"
has_flat "$pa" 'with no `Version:` key' "pr-author.md's rebuttal is not a version"
has_flat "$pa" 'It is not a version and costs nothing against Version-Limit' "pr-author.md's rebuttal costs no version"
has_flat "$pa" 'there is one exchange per block' "pr-author.md argues each block once"
has_flat "$pa" '`To: @core` alone. `@core` rules as maintainer' "pr-author.md takes a held block to @core"
has_flat "$pa" '`To: @operator` alone, with `Question` as the last non-empty line' "pr-author.md takes @core's own block to @operator as a Question"
has_flat "$pa" 'Never ask the Secretary for a verdict while one is open' "pr-author.md never asks the Secretary while a dispute is open"
has_flat "$pa" 'carries `Overrule: <that verdict'"'"'s message id>` alone on its line at the left margin' "pr-author.md reads an Overrule line as a ruling"
has_flat "$pa" 'only `@operator` can overrule `@core`' "pr-author.md: only the operator overrules @core"
has_flat "$pa" 'upholds the block: comply' "pr-author.md complies with an upheld block"
co="$texts_dir/core.md"
has_flat "$co" '## First pass: hunt the bugs' "core.md has the mandatory bug-hunt first pass"
has_flat "$co" 'at high effort, and finish it before you write anything else' "core.md runs the hunt first, at high effort"
has_flat "$co" 'run it at `high`' "core.md uses the built-in /code-review at high when it has one"
has_flat "$co" 'it must not post anything' "core.md keeps /code-review from posting"
has_flat "$co" '**List every behaviour change**' "core.md enumerates every behaviour change"
has_flat "$co" 'only separators (`,` or `,,`), repeated keys, missing' "core.md pushes blank, separator-only and repeated inputs"
has_flat "$co" 'the rows written, what is billed, logged or sent' "core.md follows inputs to side effects"
has_flat "$co" '**Verify each finding before you report it**' "core.md verifies before reporting"
has_flat "$co" 'A clean hunt is a result' "core.md reports a clean hunt"
has_flat "$co" '## Ruling on a dispute' "core.md has the ruling duty"
has_flat "$co" 'Rule on the merits' "core.md rules on the merits"
has_flat "$co" 'Put `Overrule: <message id>` alone on its line at the left margin' "core.md writes the machine-read Overrule line"
has_flat "$co" 'name the seat'"'"'s newest blocking reply' "core.md names the newest blocking message"
has_flat "$co" 'A dispute about your own block is not yours to rule' "core.md does not rule on its own block"
has_flat "$sec" '**Disputes**' "secretary.md has a Disputes section"
has_flat "$sec" 'A dispute is not a defect' "secretary.md does not list a dispute as a defect"
has_flat "$sec" 'belongs here only once a ruling upheld it' "secretary.md lists a disputed point as a defect only when upheld"
has_flat "$sec" 'A blocking verdict is overruled, and counts as non-blocking' "secretary.md counts an overruled block as non-blocking"
has_flat "$sec" 'or a block that was overruled' "secretary.md leaves an overruled block out of the findings"
}
has_flat "$texts_dir/tests.md" 'wants a comment saying why it has that value, not a test restating it' \
    "tests.md asks for a comment, not a test, on a setting that fails loudly"
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
has "$sec" 'is the `Frozen-Head:` line of the Author'"'"'s cover that' \
    "secretary.md takes the frozen head from the Author's cover for vN"
has "$sec" 'else the one on the' \
    "secretary.md falls back to the thread root's frozen head"
has "$sec" '`SIGNED-OFF` when vN'"'"'s `X-Review-Target` sha equals' \
    "secretary.md signs off only a vN whose target is the frozen head"
has "$sec" '`RESPIN` otherwise' \
    "secretary.md respins a vN whose target is above the frozen head"
has "$sec" '`Suite-Run: <N> passed, 0 failed` with N ≥ 1' \
    "secretary.md counts a suite seat only with a clean Suite-Run on its verdict reply"
has "$sec" 'report the panel `Panel-Status: IN-PROGRESS`, and say in one line which' \
    "secretary.md reports IN-PROGRESS for a suite seat without a clean run"
has "$sec" 'verify it from the thread yourself' \
    "secretary.md verifies verdicts from the thread, not the Author's summary"
has "$sec" 'last in the body' \
    "secretary.md makes the Panel-* lines last in the body"
}

# pr-author: the fleet's in-cluster PR author. Its wake checklist IS the
# round protocol (no orchestrator drives the rounds), so the strings
# that carry the protocol are pinned, not just the frontmatter.
pra="$texts_dir/pr-author.md"
pra_fm="$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f { print }' "$pra")"

# The CI suite source (X-Lkml-Suite-Source: ci): the project's suite is CI's
# to run, so the tests seat and the author stop running it, and the
# secretary reports CI's result on the frozen head in place of Suite-Run.
# shellcheck disable=SC2016  # literal backticks in the needles
ci_source_pins() {
local tst="$texts_dir/tests.md"
has_flat "$tst" '## The suite' "tests.md has the suite section"
has_flat "$tst" '`X-Lkml-Suite-Source: ci`' "tests.md names the opt-in header"
has_flat "$tst" "never run the project's full suite" "tests.md never runs the full suite under ci"
has_flat "$tst" '`X-Lkml-CI-Status`' "tests.md reads the CI status header"
has_flat "$tst" '`X-Lkml-CI-Head`' "tests.md matches the CI head to the frozen head"
has_flat "$tst" 'From `@operator`' "tests.md trusts CI mail only From @operator"
has_flat "$tst" "you do not re-run the project's tests, whole or in part" "tests.md re-runs no project tests under ci"
has_flat "$tst" 'the way the kickoff'"'"'s "Verifying it yourself" says' "tests.md sends the seat to verify by hand"
has_flat "$tst" 'a new test run against the code without the change' "tests.md keeps the fails-without-the-change check"
has_flat "$tst" 'Write no `Suite-Run:` line' "tests.md writes no Suite-Run line under ci"
has_flat "$pra" 'unless the thread root carries `X-Lkml-Suite-Source: ci`' "pr-author.md exempts the re-roll's suite run under ci"
has_flat "$pra" 'do not run the full suite' "pr-author.md does not run the full suite under ci"
has_flat "$pra" 'not CI-tested' "pr-author.md says its own commits are not CI-tested"
has_flat "$pra" 'as in step 6 of the re-roll' "pr-author.md applies the same rule to the integration"
has_flat "$sec" 'If the root carries `X-Lkml-Suite-Source: ci`' "secretary.md has a CI branch"
has_flat "$sec" 'no seat owes a `Suite-Run:` line' "secretary.md requires no Suite-Run line under ci"
has_flat "$sec" 'whose `X-Lkml-CI-Head` sha' "secretary.md matches the CI head sha"
has_flat "$sec" "in place of the seats' Suite-Run lines" "secretary.md reports CI in place of Suite-Run lines"
has_flat "$sec" 'CI'"'"'s status does not change `Panel-Status`' "secretary.md leaves CI blocking to the gate"
}
ci_source_pins

if grep -qE '^description: .+' <<<"$pra_fm"; then
    ok "pr-author.md frontmatter has a description"
else
    no "pr-author.md frontmatter has a description"
fi
if $have_fork_sandbox; then
    pra_resolved="$(fork-sandbox fleet resolve pr-author 2>&1)"
    if [[ "$(sed -n '1p' <<<"$pra_resolved")" == "claude" && "$(sed -n '2p' <<<"$pra_resolved")" == "opus" ]]; then
        ok "pr-author resolves harness=claude model=opus"
    else
        no "pr-author resolves harness=claude model=opus" "$pra_resolved"
    fi
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
# The human author's push: the persona posts it, unchanged, as the next
# version. These strings are the protocol; lkml-panel-state.py's
# per-version frozen head reads the cover line the persona is told to write.
# shellcheck disable=SC2016  # literal backticks in the needles
{
has "$pra" '**frozen head is per version**' \
    "pr-author.md makes the frozen head per version"
has "$pra" 'cover that posted the current version N, else the `Frozen-Head:` line of the' \
    "pr-author.md takes the frozen head from its own cover for N, else the root's"
has "$pra" '3. **Has the human author pushed?**' \
    "pr-author.md has the Has the human author pushed? checklist step, before the every-seat test"
has "$pra" '4. **Has every Panel seat replied on N?**' \
    "pr-author.md keeps the every-seat test right after the push step"
has "$pra" '`X-Upstream-Head: <branch> <sha>` header is UNANSWERED unless a later' \
    "pr-author.md reads the newest X-Upstream-Head as unanswered until a later cover answers it"
has "$pra" 'carries `Frozen-Head: <that sha>`' \
    "pr-author.md ties an answered push to a cover's Frozen-Head line"
has_flat "$pra" 'Only the newest is the head you post; older ones are superseded as heads,' \
    "pr-author.md posts only the newest X-Upstream-Head"
has_flat "$pra" 'but not as obligations' \
    "pr-author.md keeps a superseded push's review obligations"
has_flat "$pra" 'every unanswered non-carry push mail since the last version you posted' \
    "pr-author.md unions the obligations of coalesced pushes"
has_flat "$pra" 'the union of their `X-Lkml-Recheck-Seats`' \
    "pr-author.md sends a coalesced recheck to the union of listed seats"
has_flat "$pra" 'seats those pushes listed, together' \
    "pr-author.md owes the union of recheck seats at step 4"
has_flat "$pra" 'the first 12 hex digits of the Message-ID of the upstream-moved mail that announced it, taken after its hyphens are removed' \
    "pr-author.md derives head-<12 hex> after removing the Message-ID's hyphens"
has "$pra" 'header shows as an `Upstream-Head: <branch> <sha>` line directly after' \
    "pr-author.md names the render's unquoted Upstream-Head line"
# fork-sandbox's --text view renders each X-* header as an unquoted line
# under its real name. The persona once told the author headers were
# readable when the view showed none, and an escalate went unseen.
has_flat "$pra" 'every `X-*` header shows under its real name as its own unquoted line after `Hops:`' \
    "pr-author.md says how the render shows X-* headers"
has_flat "$pra" 'an unquoted `X-Lkml-Push-Mode: <mode>` line among that mail'"'"'s header lines' \
    "pr-author.md names the rendered push-mode line"
has_flat "$pra" 'The mode is absent only when the mail shows no such line' \
    "pr-author.md treats the mode as absent only when no line shows"
if grep -qF 'may spell it `Lkml-Push-Mode`' "$pra"; then
    no "pr-author.md drops the guessed Lkml-Push-Mode spelling" "still present"
else ok "pr-author.md drops the guessed Lkml-Push-Mode spelling"; fi
has_flat "$texts_dir/secretary.md" 'each `X-*` header is its own unquoted line after `Hops:`' \
    "secretary.md says how the render shows X-* headers"
has "$pra" 'A push never aborts a round.' \
    "pr-author.md never lets a push abort a round"
has "$pra" 'the local branch `upstream`' \
    "pr-author.md names the upstream branch as the pushed head"
has "$pra" 'so it existing does not mean the push is unanswered' \
    "pr-author.md decides answered from the thread, not from the upstream branch"
has "$pra" "## Integrating the human author's push" \
    "pr-author.md carries the integration section"
has "$pra" 'git merge-base --is-ancestor <c>' \
    "pr-author.md classifies by ancestry in H first"
has "$pra" 'Do not test the commit'"'"'s own diff against H' \
    "pr-author.md does not test an ancestor's own diff against H, which misreads a stack"
has "$pra" 'git diff --quiet <vN sha> upstream -- P' \
    "pr-author.md calls an ancestor taken when the human left its paths alone"
has "$pra" 'git diff --quiet <c> upstream -- P' \
    "pr-author.md calls an ancestor taken when H holds its paths as the commit left them"
has "$pra" '<vN frozen head> upstream -- P' \
    "pr-author.md calls an ancestor not taken when H holds its paths as before the panel"
has "$pra" 'else: **changed**' \
    "pr-author.md can report an ancestor as changed"
has "$pra" 'copy was reverted: **not' \
    "pr-author.md does not count a reverted patch-id match as taken"
has "$pra" '$(git merge-base <vN frozen head> upstream)..upstream' \
    "pr-author.md takes the patch-id range from the frozen head, not vN's sha"
has "$pra" 'git patch-id --stable' \
    "pr-author.md classifies by patch-id second"
has "$pra" 'apply --check -R' \
    "pr-author.md classifies by reverse-apply third"
has "$pra" 'squashing and rebasing make (a) and (b) miss' \
    "pr-author.md explains why patch-id alone is not enough"
has "$pra" '`git reset --hard upstream`' \
    "pr-author.md resets its branch to the pushed head"
has "$pra" 'reply `To: @operator` only, one short' \
    "pr-author.md replies to the operator alone when upstream is missing or differs"
has "$pra" 'which sha was expected and what was found' \
    "pr-author.md names the expected and found sha in that reply"
has "$pra" 'not taken by the human author; no reason given' \
    "pr-author.md uses the exact no-reason wording"
has "$pra" 'invent a reason, and never ask the human for one' \
    "pr-author.md never invents a reason nor asks for one"
has "$pra" '`--- lkml-integration begin ---`' \
    "pr-author.md reads the human's notes block by its begin line"
has "$pra" 'ends in the first 7 hex characters of the ROOT' \
    "pr-author.md checks the notes block against the root frozen head"
has "$pra" '`Frozen-Head: <H>` alone on its line' \
    "pr-author.md's integration cover carries Frozen-Head: <H>"
has "$pra" 'Every cover you post carries this' \
    "pr-author.md puts a Frozen-Head line on every cover"
has "$pra" '## Integration of v<N>' \
    "pr-author.md's integration cover classifies each commit"
has "$pra" '## Decided' \
    "pr-author.md's integration cover has a Decided section"
has "$pra" 'A suggestion the human author did not take is decided.' \
    "pr-author.md treats a dropped suggestion as decided"
has_flat "$pra" 'A human-integration version counts toward Version-Limit.' \
    "pr-author.md counts human-integration versions against Version-Limit"
has_flat "$pra" 'The version count is N, the highest `X-Version` on the thread' \
    "pr-author.md counts every version, human pushes included, against Version-Limit"
has_flat "$pra" 'plus one for each push mail whose sha is no cover'"'"'s `Frozen-Head:`' \
    "pr-author.md counts carry pushes toward Version-Limit"
has_flat "$pra" 'is owed from the version that answers that escalate' \
    "pr-author.md owes an escalate's added seats only from the answering version"
has_flat "$pra" 'a push superseded by a newer one' \
    "pr-author.md counts superseded pushes toward Version-Limit"
has_flat "$sec" 'a fix only in the panel'"'"'s own commits above the frozen head does not retire it' \
    "secretary.md keeps a finding until the frozen head addresses it"
has_flat "$pra" 'A seat'"'"'s own reply carrying `X-Version: N` always wins' \
    "pr-author.md prefers a seat's own reply on N over a carried verdict"
for stale in 'The version count is 1 plus the number of' 'does not count toward Version-Limit'; do
    if tr '\n' ' ' < "$pra" | sed 's/  */ /g' | grep -qF -- "$stale"; then
        no "pr-author.md dropped the old Version-Limit rule: $stale" "still present"
    else
        ok "pr-author.md dropped the old Version-Limit rule: $stale"
    fi
done
# Push modes (tier effort): one home, in pr-author.
# shellcheck disable=SC2016  # literal backticks in the needles
for needle in \
    '### Push modes' '`X-Lkml-Push-Mode`' '`X-Lkml-Recheck-Seats`' '`X-Lkml-Add-Seats`' \
    '`X-Lkml-Tier-Reason`' 'quick < standard < full' 'treated as absent' \
    'which seats were added and why' "verdicts carry forward" \
    '`git range-diff head-<prev 12 hex>...head-<this 12 hex>`' '`review-v1`' \
    'A blocking verdict carries as blocking.' 'cannot be confirmed' \
    'owes no version' 'seats owed on' 'never shrinks' \
    'A finding the human reimplemented'
do
    has_flat "$pra" "$needle" "pr-author.md pins: $needle"
done
has "$pra" '[PATCH v<N+1> 0/0]' \
    "pr-author.md's integration cover subject is 0/0"
}

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
    has "$prk" "the PR's human author's own integration" \
        "pr-review.md says a version may be the human author's integration"
    has "$prk" 'A suggestion the human author did not take is' \
        "pr-review.md treats a dropped suggestion as decided"
    has "$prk" 'blocking objection saying why the' \
        "pr-review.md lets a decided suggestion be re-raised only as a blocking objection"
    has "$prk" 'The frozen head can move to' \
        "pr-review.md says the frozen head can move to the human's push"
    # shellcheck disable=SC2016  # literal backticks in the needle
    has "$prk" 'If the root above carries `X-Lkml-Suite-Source: ci`, skip this section:' \
        "pr-review.md skips its Running-the-suite section under the CI suite source"
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

# Every author persona, local and fleet, may decline a nit -- but never a
# correctness, security or data-loss point.
for f in skills/lkml-mode/personas/author.md skills/lkml-mode/personas/pr-author.md \
         fleet/personas/author.md fleet/personas/pr-author.md; do
    if grep -qF 'You may decline a nit.' "$repo_dir/$f" \
       && grep -qF 'Never decline a correctness, security or' "$repo_dir/$f"; then
        ok "$f lets the author decline a nit, and bounds it"
    else
        no "$f lets the author decline a nit, and bounds it" "rule or its bound missing"
    fi
done

# Tier focus and recheck scope: the same byte-identical section in the
# nine reviewers, right before the verdict section, and in no one else.
# Needles are matched on the flattened section so they may span a wrap.
extract_tier_scope() {
    awk '/^## Tier focus and recheck scope$/{ f = 1; print; next }
         f && /^## / { exit }
         f { print }' "$1"
}
tier_baseline=""
for name in $reviewers; do
    f="$texts_dir/$name.md"
    section="$(extract_tier_scope "$f")"
    if [[ -z "$section" ]]; then
        no "$name carries the tier focus section" "no '## Tier focus and recheck scope' heading"
        continue
    fi
    if [[ -z "$tier_baseline" ]]; then
        tier_baseline="$section"
        ok "$name carries the tier focus section (comparison baseline)"
    elif [[ "$section" == "$tier_baseline" ]]; then
        ok "$name's tier focus section matches the baseline"
    else
        no "$name's tier focus section matches the baseline" "section text diverges"
    fi
    next_heading="$(awk '/^## Tier focus and recheck scope$/{ f = 1; next }
                         f && /^## / { print; exit }' "$f")"
    if [[ "$next_heading" == "## Who hears your review, and your verdict" ]]; then
        ok "$name's tier focus section sits right before the verdict section"
    else
        no "$name's tier focus section sits right before the verdict section" "next heading: '$next_heading'"
    fi
done
for name in ci author distiller secretary pr-author; do
    if [[ -z "$(extract_tier_scope "$texts_dir/$name.md")" ]]; then
        ok "$name.md does not carry the tier focus section"
    else
        no "$name.md does not carry the tier focus section" "found the heading"
    fi
done
if [[ -n "$tier_baseline" ]]; then
    flat="$(tr '\n' ' ' <<<"$tier_baseline" | sed 's/  */ /g')"
    # shellcheck disable=SC2016  # literal backticks in the needles
    for needle in \
        'tier-focus.md' \
        '## @<your seat>' \
        'still report anything blocking' \
        'A quick-tier panel is a real review' \
        '`git range-diff`' \
        '`head-<12 hex>`' \
        '`review-v<N>`' \
        'falls back to the commit range' \
        'never block on a missing branch'
    do
        if grep -qF -- "$needle" <<<"$flat"; then
            ok "tier focus section pins: $needle"
        else
            no "tier focus section pins: $needle" "not found"
        fi
    done
fi

# The kickoff names the tier, reads exactly as before when it is absent.
if [[ -f "$prk" ]]; then
    prk_tier="$(awk '/^## Review tier$/{ f = 1; print; next } f && /^## / { exit } f { print }' <<<"$prk_body")"
    if [[ -z "$prk_tier" ]]; then
        no "pr-review.md carries a Review tier section" "no heading"
    else
        ok "pr-review.md carries a Review tier section"
        tier_flat="$(tr '\n' ' ' <<<"$prk_tier" | sed 's/  */ /g')"
        for needle in 'X-Lkml-Tier' 'X-Lkml-Tier-Reason' 'tier-focus.md' '## @<seat>' \
                      'a smaller tier is a smaller named roster' \
                      'same bar' 'With no such header'
        do
            if grep -qF -- "$needle" <<<"$tier_flat"; then
                ok "Review tier section pins: $needle"
            else
                no "Review tier section pins: $needle" "not found"
            fi
        done
        # shellcheck disable=SC2016  # literal placeholder text
        if grep -qF '${' <<<"$prk_tier"; then
            no "Review tier section has no placeholder" "found a \${...}"
        else
            ok "Review tier section has no placeholder"
        fi
    fi
    if grep -qF 'is addressed when the code at' <<<"$(tr '\n' ' ' <<<"$prk_body" | sed 's/  */ /g')"; then
        ok "pr-review.md judges a point on the code at the new head, not an explanation"
    else
        no "pr-review.md judges a point on the code at the new head, not an explanation"
    fi
fi

# secretary: the findings block is the first thing in the summary, in one
# fixed line format a renderer can lift. The format has one home, here.
sec_findings="$(awk '/^## The findings block$/{ f = 1; print; next } f && /^## / { exit } f { print }' "$sec")"
if [[ -z "$sec_findings" ]]; then
    no "secretary.md carries The findings block section" "no heading"
else
    ok "secretary.md carries The findings block section"
    if grep -qxF '    Findings:' <<<"$sec_findings" \
       && grep -qxF '    - <severity> | <seat> | <file or area> | <fix in one sentence>' <<<"$sec_findings"; then
        ok "secretary.md shows the findings line format"
    else
        no "secretary.md shows the findings line format" "indented format lines not found"
    fi
    # shellcheck disable=SC2016  # literal backticks in the needles
    for needle in '`blocking`' '`should-fix`' '`nit`' 'first thing in the body' \
                  'one physical line' 'never the deliverable' 'reference' 'first blank line'; do
        if tr '\n' ' ' <<<"$sec_findings" | sed 's/  */ /g' | grep -qF -- "$needle"; then
            ok "findings block section pins: $needle"
        else
            no "findings block section pins: $needle" "not found"
        fi
    done
    if grep -qE '^Panel-(Version|Status|Verdict)' <<<"$sec_findings"; then
        no "findings block section does not write Panel-* keys" "found one"
    else
        ok "findings block section does not write Panel-* keys"
    fi
fi
first_bullet="$(awk '/^## Your one reply, in this order$/{ f = 1; next } f && /^- / { print; exit }' "$sec")"
if [[ "$first_bullet" == '- **Findings**'* ]]; then
    ok "secretary.md's first reply item is the findings block"
else
    no "secretary.md's first reply item is the findings block" "got: $first_bullet"
fi
# shellcheck disable=SC2016  # literal backticks in the needles
for needle in '`X-Lkml-Add-Seats`' '`X-Lkml-Recheck-Seats`' 'A blocking verdict carries as blocking' \
              'earlier version, carried forward' 'its own reply on vN when it has one' \
              'or the one carried forward under step 2' 'or its carried one under step 2'; do
    has_flat "$sec" "$needle" "secretary.md pins: $needle"
done

# docs/cluster-panel.md documents the CI-source and operator-question
# contract once: the new subsection, one table row per header, and the
# no-timer limit.
cluster_doc="$repo_dir/docs/cluster-panel.md"
has "$cluster_doc" '#### Suite source, CI results and operator questions' "docs: the CI source subsection exists"
for hdr in X-Lkml-Suite-Source X-Lkml-Question-Timeout X-Lkml-CI-Status X-Lkml-CI-Head X-Lkml-CI-Url; do
    check_n="$(grep -cF -- "| \`$hdr\` |" "$cluster_doc")"
    if [[ "$check_n" == 1 ]]; then ok "docs: $hdr has exactly one table row"
    else no "docs: $hdr has exactly one table row" "found $check_n"; fi
done
has "$cluster_doc" 'Nothing wakes a thread when an operator question times out' "docs: the no-timer limit is named"

# fork-sandbox skips a malformed reply and flags the thread; it does not
# respawn the seat. A persona that promises a retry tells the seat its
# broken stanza is recoverable when it is not.
if respawn_files="$(grep -rlE 'respawns? the seat' "$texts_dir")"; then
    no "no persona promises a respawn after a malformed reply" "$respawn_files"
else
    ok "no persona promises a respawn after a malformed reply"
fi
stanza_count="$(grep -rlF 'nothing retries. A complete review in a broken stanza' "$texts_dir" | wc -l)"
check_count="$(grep -rlF 'A complete review in a broken stanza' "$texts_dir" | wc -l)"
if (( stanza_count == check_count && check_count > 0 )); then
    ok "every persona with the stanza warning says nothing retries"
else
    no "every persona with the stanza warning says nothing retries" "$stanza_count of $check_count"
fi

# Contract header names: exactly nine X-Lkml-* names appear in fleet/, so
# a typo'd header never ships, and push modes / tier focus live only in
# the files that own them (fleet/ includes fleet/prompts).
lkml_headers="$(grep -rhoE 'X-Lkml-[A-Za-z-]+' "$repo_dir/fleet" | sed 's/-$//' | sort -u | tr '\n' ' ')"
expected_headers='X-Lkml-Add-Seats X-Lkml-CI-Head X-Lkml-CI-Status X-Lkml-Push-Mode X-Lkml-Question-Timeout X-Lkml-Recheck-Seats X-Lkml-Suite-Source X-Lkml-Tier X-Lkml-Tier-Reason '
if [[ "$lkml_headers" == "$expected_headers" ]]; then
    ok "fleet/ spells only the nine contract X-Lkml-* headers"
else
    no "fleet/ spells only the nine contract X-Lkml-* headers" "got: $lkml_headers"
fi
push_files="$(grep -rlF 'X-Lkml-Push-Mode' "$repo_dir/fleet" | xargs -n1 basename | sort | tr '\n' ' ')"
if [[ "$push_files" == 'pr-author.md secretary.md ' ]]; then
    ok "push modes appear only in pr-author.md and secretary.md"
else
    no "push modes appear only in pr-author.md and secretary.md" "got: $push_files"
fi
focus_files="$(grep -rlF 'tier-focus.md' "$repo_dir/fleet" | xargs -n1 basename | LC_ALL=C sort | tr '\n' ' ')"
if [[ "$focus_files" == 'pr-review.md protocol-reviewer.md ' ]]; then
    ok "tier-focus.md appears only in the reviewer protocol and the pr-review kickoff"
else
    no "tier-focus.md appears only in the reviewer protocol and the pr-review kickoff" "got: $focus_files"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
