#!/usr/bin/env bash
# lkml-fleet-status-test.sh — Exercise lkml-fleet-status.sh against a
# fixture agent-mail store built by writing .msg files directly. The
# fleet message format is plain text (a header block, a blank line, the
# body verbatim), so no part of this suite needs fork-sandbox present;
# a stub on PATH stands in for the one allowed external call,
# `fork-sandbox fleet expand`, the same "stub the external command on
# PATH" pattern tests/lkml-fleet-kickoff-test.sh uses.
#
# Fixture fleet: @author posts; @ci and (via the @panel list)
# @review-one and @review-three reply; @review-two sits on the panel and
# never speaks; @maintainer is Cc'd on the kickoff and never speaks.
#
# Usage: tests/lkml-fleet-status-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
status="${LKML_FLEET_STATUS:-$repo_dir/scripts/lkml-fleet-status.sh}"

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}
not_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) no "$label" "'$needle' found in: $haystack" ;;
        *) ok "$label" ;;
    esac
}
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}

work="$(mktemp -d)"; tmpdirs+=("$work")

t1="11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
t2="11111111-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
t3="33333333-cccc-4ccc-8ccc-cccccccccccc"

root="$work/store1"
mkdir -p -- "$root/threads/$t1" "$root/threads/$t2" "$root/threads/.stray"
root2="$work/store2"
mkdir -p -- "$root2/threads/$t3"

# write_msg <store> <thread> <nnn> <id> <date> <from> <to> <cc> <subject>
#            <hops> <in-reply-to> <body>
write_msg() {
    local store="$1" t="$2" nnn="$3" id="$4" date="$5" from="$6" to="$7" cc="$8" subj="$9" hops="${10}" irt="${11}" body="${12}"
    local f="$store/threads/$t/$nnn-$id.msg"
    {
        printf 'Message-ID: %s\n' "$id"
        printf 'Thread-ID: %s\n' "$t"
        printf 'Date: %s\n' "$date"
        printf 'From: %s\n' "$from"
        printf 'To: %s\n' "$to"
        [[ -n "$cc" ]] && printf 'Cc: %s\n' "$cc"
        printf 'Subject: %s\n' "$subj"
        [[ -n "$irt" ]] && printf 'In-Reply-To: %s\n' "$irt"
        printf 'X-Hops: %s\n' "$hops"
        printf '\n'
        printf '%s\n' "$body"
    } > "$f"
}

D() { printf 'Mon, 02 Mar 2026 10:%02d:00 +0000' "$1"; }

# thread t1: a two-version patch review with one unanswered NAK
write_msg "$root" "$t1" 001 b0010000-0000-4000-8000-000000000001 "$(D 0)" \
    '@author' '@ci,@panel' '@maintainer' '[PATCH v1 0/2] Improve the thing' 8 '' \
    'Cover letter for v1.'
write_msg "$root" "$t1" 002 b0020000-0000-4000-8000-000000000002 "$(D 1)" \
    '@author' '@ci,@panel' '' '[PATCH v1 1/2] Add the feature' 8 b0010000-0000-4000-8000-000000000001 \
    'The v1 diff.'
write_msg "$root" "$t1" 003 b0030000-0000-4000-8000-000000000003 "$(D 2)" \
    '@ci' '@author' '' 'Re: [PATCH v1 0/2] Improve the thing' 7 b0010000-0000-4000-8000-000000000001 \
    'Suite green on both patches.

Tested-by: CI'
write_msg "$root" "$t1" 004 b0040000-0000-4000-8000-000000000004 "$(D 3)" \
    '@review-one' '@author' '' 'Re: [PATCH v1 1/2] Add the feature' 7 b0020000-0000-4000-8000-000000000002 \
    'The error path is untested.

Changes-requested'
write_msg "$root" "$t1" 005 b0050000-0000-4000-8000-000000000005 "$(D 4)" \
    '@author' '@review-one' '' 'Re: [PATCH v1 1/2] Add the feature' 6 b0040000-0000-4000-8000-000000000004 \
    'Fair -- reworked, see v2.'
write_msg "$root" "$t1" 006 b0060000-0000-4000-8000-000000000006 "$(D 5)" \
    '@author' '@ci,@panel' '' '[PATCH v2 0/2] Improve the thing' 6 b0050000-0000-4000-8000-000000000005 \
    'Version two.'
write_msg "$root" "$t1" 007 b0070000-0000-4000-8000-000000000007 "$(D 6)" \
    '@review-one' '@author' '' 'Re: [PATCH v2 0/2] Improve the thing' 5 b0060000-0000-4000-8000-000000000006 \
    'Looks good now.

Reviewed-by: Review One'
write_msg "$root" "$t1" 008 b0080000-0000-4000-8000-000000000008 "$(D 7)" \
    '@author' '@ci,@panel' '' '[PATCH v2 1/2] Add the feature' 5 b0060000-0000-4000-8000-000000000006 \
    'The improved diff.'
write_msg "$root" "$t1" 009 b0090000-0000-4000-8000-000000000009 "$(D 8)" \
    '@review-one' '@author' '' 'Re: [PATCH v2 1/2] Add the feature' 4 b0080000-0000-4000-8000-000000000008 \
    'Question: is the lock order documented?

Question'
# 010 replies to the Question from a DIFFERENT sender -> answered
write_msg "$root" "$t1" 010 b0100000-0000-4000-8000-000000000010 "$(D 9)" \
    '@author' '@review-one' '' 'Re: [PATCH v2 1/2] Add the feature' 3 b0090000-0000-4000-8000-000000000009 \
    'Yes, section 4 of the doc.'
write_msg "$root" "$t1" 011 b0110000-0000-4000-8000-000000000011 "$(D 10)" \
    '@review-one' '@author' '' 'Re: [PATCH v2 1/2] Add the feature' 2 b0100000-0000-4000-8000-000000000010 \
    'NAK: still missing the race test.

NAK'
# 012 replies to the NAK but from the SAME sender -> still unanswered
write_msg "$root" "$t1" 012 b0120000-0000-4000-8000-000000000012 "$(D 11)" \
    '@review-one' '@author' '' 'Re: [PATCH v2 1/2] Add the feature' 1 b0110000-0000-4000-8000-000000000011 \
    'I will add that test.'
write_msg "$root" "$t1" 013 b0130000-0000-4000-8000-000000000013 "$(D 12)" \
    '@review-three' '@author' '' 'Re: [PATCH v2 0/2] Improve the thing' 5 b0060000-0000-4000-8000-000000000006 \
    'The naming is inconsistent.

Changes-requested'
write_msg "$root" "$t1" 014 b0140000-0000-4000-8000-000000000014 "$(D 13)" \
    '@author' '@review-three' '' 'Re: [PATCH v2 0/2] Improve the thing' 4 b0130000-0000-4000-8000-000000000013 \
    'Renamed as asked.'
write_msg "$root" "$t1" 015 b0150000-0000-4000-8000-000000000015 "$(D 14)" \
    '@review-three' '@author' '' 'Re: [PATCH v2 0/2] Improve the thing' 4 b0140000-0000-4000-8000-000000000014 \
    'Good.

Reviewed-by: Review Three'

# a second thread sharing t1's 8-hex prefix (ambiguity fixture)
write_msg "$root" "$t2" 001 c0010000-0000-4000-8000-000000000001 'Tue, 03 Mar 2026 09:00:00 +0000' \
    '@author' '@panel' '' 'Unrelated thread' 8 '' 'Something else entirely.'

# a stray dot-directory under threads/ with a plausible-looking message:
# must not be rendered as a thread
write_msg "$root" '.stray' 001 d0010000-0000-4000-8000-000000000001 "$(D 0)" \
    '@author' '@panel' '' 'Should not appear' 8 '' 'scratch state, not mail.'

# store2: a single-message, version-less thread, NO .postmaster at all
write_msg "$root2" "$t3" 001 e0010000-0000-4000-8000-000000000001 "$(D 0)" \
    '@author' '@panel' '' 'Discussion: where to keep the state' 8 '' 'No patches here.'

# a fourth thread used only to exercise summary.json parser semantics
# (string cost, boolean cost, two real costs summed) in isolation, so
# it never perturbs t1's hand-counted totals.
t4="44444444-dddd-4ddd-8ddd-dddddddddddd"
mkdir -p -- "$root/threads/$t4"
write_msg "$root" "$t4" 001 f0010000-0000-4000-8000-000000000001 "$(D 0)" \
    '@author' '@panel' '' 'Parser semantics fixture' 8 '' 'No patches here either.'

# .postmaster router state for the t1/t2 threads. t1: an operator
# mail zeroed spawns/ from 5 down to 3 (seq/ is never reset). t2:
# spawns/ zeroed to 0 and the thread flagged needs-operator. store2
# (t3) deliberately has NO .postmaster at all: the normal case for a
# thread nobody has routed yet.
pm="$root/.postmaster"
mkdir -p -- "$pm/spawns" "$pm/seq" "$pm/needs-operator" "$pm/runs"
printf 'run-a1\nrun-a2\nrun-a3\n' > "$pm/spawns/$t1"
printf 'run-a1\nrun-a2\nrun-a3\nrun-a4\nrun-a5\n' > "$pm/seq/$t1"
: > "$pm/spawns/$t2"
printf 'run-b1\n' > "$pm/seq/$t2"
printf 'hops exhausted at c0010000-0000-4000-8000-000000000001\n' > "$pm/needs-operator/$t2"

# Run ledger fixture: two completed t1 runs have different agents, while a
# third t1 run is still in flight. A completed t2 run must not leak into
# t1's cost report.
run_one="$work/run-one"; mkdir -p -- "$run_one"
run_two="$work/run-two"; mkdir -p -- "$run_two"
run_three="$work/run-three"; mkdir -p -- "$run_three"
run_null="$work/run-null"; mkdir -p -- "$run_null"
run_garbage="$work/run-garbage"; mkdir -p -- "$run_garbage"
run_only_null="$work/run-only-null"; mkdir -p -- "$run_only_null"
run_other="$work/run-other"; mkdir -p -- "$run_other"
# Continuation summaries include a total that accounts for earlier context.
printf '{"cost_usd": 1.25, "total_cost_usd": 4.75}\n' > "$run_one/summary.json"
printf '{"cost_usd": 2.50}\n' > "$run_two/summary.json"
printf '{"cost_usd": null, "total_cost_usd": null}\n' > "$run_null/summary.json"
printf 'not json at all\n' > "$run_garbage/summary.json"
printf '{"cost_usd": null, "total_cost_usd": null}\n' > "$run_only_null/summary.json"
printf '{"cost_usd": 99.00}\n' > "$run_other/summary.json"
printf 'agent=review-one\nthread=%s\nrun_dir=%s\n' "$t1" "$run_one" > "$pm/runs/run-a.env"
printf 'agent=review-two\nthread=%s\nrun_dir=%s\n' "$t1" "$run_two" > "$pm/runs/run-b.env"
printf 'agent=review-one\nthread=%s\nrun_dir=%s\n' "$t1" "$run_three" > "$pm/runs/run-c.env"
printf 'agent=review-two\nthread=%s\nrun_dir=%s\n' "$t1" "$run_null" > "$pm/runs/run-e.env"
printf 'agent=review-one\nthread=%s\nrun_dir=%s\n' "$t1" "$run_garbage" > "$pm/runs/run-f.env"
printf 'agent=review-null\nthread=%s\nrun_dir=%s\n' "$t1" "$run_only_null" > "$pm/runs/run-g.env"
printf 'agent=other-agent\nthread=%s\nrun_dir=%s\n' "$t2" "$run_other" > "$pm/runs/run-d.env"

# Parser-semantics fixture (thread t4): a string cost, a boolean cost
# (the isinstance(bool, int) trap), two real costs for one agent that
# must sum, and a magnitude far beyond any real invoice, as a JSON
# integer -- repr() of a Python int never uses exponent notation
# regardless of size, so this is a real, if absurd-looking, cost and
# must be summed rather than filtered out by size.
run_parser_string="$work/run-parser-string"; mkdir -p -- "$run_parser_string"
run_parser_bool="$work/run-parser-bool"; mkdir -p -- "$run_parser_bool"
run_parser_sum_a="$work/run-parser-sum-a"; mkdir -p -- "$run_parser_sum_a"
run_parser_sum_b="$work/run-parser-sum-b"; mkdir -p -- "$run_parser_sum_b"
run_parser_huge="$work/run-parser-huge"; mkdir -p -- "$run_parser_huge"
run_parser_overflow="$work/run-parser-overflow"; mkdir -p -- "$run_parser_overflow"
printf '{"total_cost_usd": "1.23"}\n' > "$run_parser_string/summary.json"
printf '{"total_cost_usd": true}\n' > "$run_parser_bool/summary.json"
printf '{"total_cost_usd": 1.5}\n' > "$run_parser_sum_a/summary.json"
printf '{"cost_usd": 2.25}\n' > "$run_parser_sum_b/summary.json"
# The expected digits pinned at the assertion below are not 10^30 --
# they are its float64 round-trip. json.load() gives this literal as a
# Python int, but format(value, ".10f") converts it to float first, the
# same way format(2**60+1, ".10f") prints ...846976 where str() of the
# same int gives the exact ...846977. Do not "correct" those digits to
# the exact value; the display path cannot produce it. The rounding is
# on that display path, inside the parser, so it survives unchanged
# even if per-agent summation later moves into the single Python
# invocation -- only a deliberate switch away from float formatting
# would change it, and nobody has proposed that.
printf '{"total_cost_usd": 1000000000000000000000000000000}\n' > "$run_parser_huge/summary.json"
# A magnitude beyond a double's range (~1.8e308): math.isfinite() and
# format(value, ".10f") both raise OverflowError converting it to float, so
# it must classify as invalid rather than silently falling back to
# "no cost" (see scripts/lkml-fleet-status.sh's OverflowError handling).
printf '{"total_cost_usd": %s}\n' "$(printf '1%.0s' $(seq 1 400))" > "$run_parser_overflow/summary.json"
# A real cost below 1e-4. repr() renders this as "1.2e-05", which the
# plain-digit gate rejects, so a known, tiny, real cost would report as
# unknown and the agent's total would be understated -- the inverse of
# the doctrine the rest of the cost column is built on. format(value,
# ".10f") is what keeps it fixed-point; this fixture is what stops a
# future change from quietly going back to repr().
run_parser_tiny="$work/run-parser-tiny"; mkdir -p -- "$run_parser_tiny"
printf '{"total_cost_usd": 0.000012}\n' > "$run_parser_tiny/summary.json"
printf 'agent=parser-tiny\nthread=%s\nrun_dir=%s\n' "$t4" "$run_parser_tiny" > "$pm/runs/run-tiny.env"
printf 'agent=parser-string\nthread=%s\nrun_dir=%s\n' "$t4" "$run_parser_string" > "$pm/runs/run-h.env"
printf 'agent=parser-bool\nthread=%s\nrun_dir=%s\n' "$t4" "$run_parser_bool" > "$pm/runs/run-i.env"
printf 'agent=parser-sum\nthread=%s\nrun_dir=%s\n' "$t4" "$run_parser_sum_a" > "$pm/runs/run-j.env"
printf 'agent=parser-sum\nthread=%s\nrun_dir=%s\n' "$t4" "$run_parser_sum_b" > "$pm/runs/run-k.env"
printf 'agent=parser-huge\nthread=%s\nrun_dir=%s\n' "$t4" "$run_parser_huge" > "$pm/runs/run-l.env"
printf 'agent=parser-overflow\nthread=%s\nrun_dir=%s\n' "$t4" "$run_parser_overflow" > "$pm/runs/run-y.env"

# thread t5: dedicated fixture for the tag-colon defect (a reviewer
# discussing a verdict in prose must not be parsed as casting it). Kept
# in its own thread, isolated from t1's hand-counted seat/tag counts.
t5="55555555-eeee-4eee-8eee-eeeeeeeeeeee"
mkdir -p -- "$root/threads/$t5"
write_msg "$root" "$t5" 001 g0010000-0000-4000-8000-000000000001 "$(D 15)" \
    '@author' '@reviewer-prose,@reviewer-colon,@reviewer-bare,@reviewer-mixed,@reviewer-quoted,@reviewer-nak,@reviewer-chreq,@reviewer-question,@reviewer-progress' '' \
    'Tag colon parsing fixture' 8 '' \
    'Cover message for the tag-colon fixture.'
# A real reviewer's wrapped prose *about* verdicts, verbatim -- no tag
# trailers anywhere in this body.
write_msg "$root" "$t5" 002 g0020000-0000-4000-8000-000000000002 "$(D 16)" \
    '@reviewer-prose' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    'Tested-by from ci, security and me, Acked-by from docs, Acked-by from'
write_msg "$root" "$t5" 003 g0030000-0000-4000-8000-000000000003 "$(D 17)" \
    '@reviewer-colon' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    'Reviewed-by: The Core Reviewer'
write_msg "$root" "$t5" 004 g0040000-0000-4000-8000-000000000004 "$(D 18)" \
    '@reviewer-bare' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    'Reviewed-by'
write_msg "$root" "$t5" 005 g0050000-0000-4000-8000-000000000005 "$(D 19)" \
    '@reviewer-mixed' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    'Reviewed-by: Mixed Signal
Tested-by looks solid too'
write_msg "$root" "$t5" 006 g0060000-0000-4000-8000-000000000006 "$(D 20)" \
    '@reviewer-quoted' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    '> Reviewed-by: Quoted Person'
write_msg "$root" "$t5" 007 g0070000-0000-4000-8000-000000000007 "$(D 21)" \
    '@reviewer-nak' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    'NAK
Explanation of the NAK follows.'
write_msg "$root" "$t5" 008 g0080000-0000-4000-8000-000000000008 "$(D 22)" \
    '@reviewer-chreq' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    'Changes-requested
because of X.'
write_msg "$root" "$t5" 009 g0090000-0000-4000-8000-000000000009 "$(D 23)" \
    '@reviewer-question' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    'Is the lock order documented here as well?
Question'
write_msg "$root" "$t5" 010 g0100000-0000-4000-8000-000000000010 "$(D 24)" \
    '@reviewer-progress' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    'Reviewed-by: Progress Reviewer'
write_msg "$root" "$t5" 011 g0110000-0000-4000-8000-000000000011 "$(D 25)" \
    '@reviewer-progress' '@author' '' 'Re: Tag colon parsing fixture' 8 '' \
    'Changes-requested'

# thread t6: dedicated fixture for the invalid-cost defect. A JSON number
# that is negative, NaN, or infinite parses fine but is not a usable
# cost, and must report as "invalid" -- distinct from "no cost" (a
# positive finding: genuinely no cost) and "unreadable" (could not be
# parsed at all). Isolated from every other thread's hand-counted totals.
t6="66666666-ffff-4fff-8fff-ffffffffffff"
mkdir -p -- "$root/threads/$t6"
write_msg "$root" "$t6" 001 h0010000-0000-4000-8000-000000000001 "$(D 26)" \
    '@author' '@panel' '' 'Invalid-cost parsing fixture' 8 '' \
    'No patches here either.'

run_invalid_neg="$work/run-invalid-neg"; mkdir -p -- "$run_invalid_neg"
run_invalid_nan="$work/run-invalid-nan"; mkdir -p -- "$run_invalid_nan"
run_invalid_inf="$work/run-invalid-inf"; mkdir -p -- "$run_invalid_inf"
run_invalid_neginf="$work/run-invalid-neginf"; mkdir -p -- "$run_invalid_neginf"
run_mixed_nocost="$work/run-mixed-nocost"; mkdir -p -- "$run_mixed_nocost"
run_mixed_invalid="$work/run-mixed-invalid"; mkdir -p -- "$run_mixed_invalid"
run_mixed_garbage="$work/run-mixed-garbage"; mkdir -p -- "$run_mixed_garbage"
run_mixed_missing="$work/run-mixed-missing"; mkdir -p -- "$run_mixed_missing"
run_zero="$work/run-zero"; mkdir -p -- "$run_zero"
run_negzero="$work/run-negzero"; mkdir -p -- "$run_negzero"
run_positive="$work/run-positive"; mkdir -p -- "$run_positive"
run_poisoned_real="$work/run-poisoned-real"; mkdir -p -- "$run_poisoned_real"
run_poisoned_invalid="$work/run-poisoned-invalid"; mkdir -p -- "$run_poisoned_invalid"
printf '{"total_cost_usd": -1.5}\n' > "$run_invalid_neg/summary.json"
printf '{"total_cost_usd": NaN}\n' > "$run_invalid_nan/summary.json"
printf '{"total_cost_usd": Infinity}\n' > "$run_invalid_inf/summary.json"
printf '{"total_cost_usd": -Infinity}\n' > "$run_invalid_neginf/summary.json"
printf '{"total_cost_usd": null}\n' > "$run_mixed_nocost/summary.json"
printf '{"total_cost_usd": -2.0}\n' > "$run_mixed_invalid/summary.json"
printf 'not json at all\n' > "$run_mixed_garbage/summary.json"
printf '{"total_cost_usd": 0.0}\n' > "$run_zero/summary.json"
printf '{"total_cost_usd": -0.0}\n' > "$run_negzero/summary.json"
printf '{"total_cost_usd": 2.5}\n' > "$run_positive/summary.json"
printf '{"total_cost_usd": 2.5}\n' > "$run_poisoned_real/summary.json"
printf '{"total_cost_usd": NaN}\n' > "$run_poisoned_invalid/summary.json"
printf 'agent=invalid-neg\nthread=%s\nrun_dir=%s\n' "$t6" "$run_invalid_neg" > "$pm/runs/run-m.env"
printf 'agent=invalid-nan\nthread=%s\nrun_dir=%s\n' "$t6" "$run_invalid_nan" > "$pm/runs/run-n.env"
printf 'agent=invalid-inf\nthread=%s\nrun_dir=%s\n' "$t6" "$run_invalid_inf" > "$pm/runs/run-o.env"
printf 'agent=invalid-neginf\nthread=%s\nrun_dir=%s\n' "$t6" "$run_invalid_neginf" > "$pm/runs/run-p.env"
printf 'agent=mixed-four\nthread=%s\nrun_dir=%s\n' "$t6" "$run_mixed_missing" > "$pm/runs/run-q.env"
printf 'agent=mixed-four\nthread=%s\nrun_dir=%s\n' "$t6" "$run_mixed_nocost" > "$pm/runs/run-r.env"
printf 'agent=mixed-four\nthread=%s\nrun_dir=%s\n' "$t6" "$run_mixed_invalid" > "$pm/runs/run-s.env"
printf 'agent=mixed-four\nthread=%s\nrun_dir=%s\n' "$t6" "$run_mixed_garbage" > "$pm/runs/run-t.env"
printf 'agent=zero-real\nthread=%s\nrun_dir=%s\n' "$t6" "$run_zero" > "$pm/runs/run-u.env"
printf 'agent=negzero\nthread=%s\nrun_dir=%s\n' "$t6" "$run_negzero" > "$pm/runs/run-z.env"
printf 'agent=positive-sum\nthread=%s\nrun_dir=%s\n' "$t6" "$run_positive" > "$pm/runs/run-v.env"
printf 'agent=poisoned-mix\nthread=%s\nrun_dir=%s\n' "$t6" "$run_poisoned_real" > "$pm/runs/run-w.env"
printf 'agent=poisoned-mix\nthread=%s\nrun_dir=%s\n' "$t6" "$run_poisoned_invalid" > "$pm/runs/run-x.env"
# run-q's run_dir deliberately has no summary.json: the "no summary" state.
# poisoned-mix pairs a real cost with an invalid one on the SAME agent: if
# an INVALID result ever reached the awk accumulator, 2.5 + nan would
# poison this agent's total instead of just incrementing its invalid count.

# thread t7: dedicated fixture for a run record with no agent= key at
# all -- the router writing a line it could not attribute. Isolated so a
# crash here can never be masked by t1..t6 having already printed.
t7="77777777-0000-4000-8000-000000000000"
mkdir -p -- "$root/threads/$t7"
write_msg "$root" "$t7" 001 i0010000-0000-4000-8000-000000000001 "$(D 27)" \
    '@author' '@panel' '' 'Missing agent key fixture' 8 '' \
    'No patches here either.'
run_no_agent="$work/run-no-agent"; mkdir -p -- "$run_no_agent"
printf '{"total_cost_usd": 6.0}\n' > "$run_no_agent/summary.json"
printf 'thread=%s\nrun_dir=%s\n' "$t7" "$run_no_agent" > "$pm/runs/run-noagent.env"

# thread t8: dedicated fixture for the sub-5e-7 aggregate test far below,
# also reused by the floor-pin fixture further down for its own 2500-run
# aggregate. Created here, alongside t1..t7, rather than at its point of
# use, so the --list count check right after this block counts every
# fixture thread the store will ever hold, not just the ones created
# before it happened to run.
t8="88888888-0000-4000-8000-000000000000"
mkdir -p -- "$root/threads/$t8"
write_msg "$root" "$t8" 001 j0010000-0000-4000-8000-000000000001 "$(D 28)" \
    '@author' '@panel' '' 'Sub-5e-7 aggregate fixture' 8 '' \
    'No patches here either.'

# Stub fork-sandbox: only the one call the script is allowed to make.
stub_bin="$work/stub"; mkdir -p -- "$stub_bin"
cat > "$stub_bin/fork-sandbox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == "fleet" && "${2-}" == "expand" ]]; then
    case "${3-}" in
        @panel) printf '%s\n' '@review-one' '@review-three' '@review-two' ;;
        @author|@ci|@review-one|@review-three|@review-two) printf '%s\n' "${3-}" ;;
        *) echo "Error: expand: unknown address '${3}'." >&2; exit 1 ;;
    esac
    exit 0
fi
echo "Error: unexpected fork-sandbox invocation: $*" >&2
exit 1
STUB
chmod +x -- "$stub_bin/fork-sandbox"
STUB_PATH="$stub_bin:$PATH"

# Snapshot the whole store: every path, and every file's content.
snapshot_store() {
    {
        (cd "$1" && find . | sort)
        (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null)
    }
}

printf '\n== --help and usage errors ==\n'
OUT="$(PATH="$STUB_PATH" "$status" --help 2>&1)"; RC=$?
check "--help exits 0" "0" "$RC"
contains "--help prints the usage line" "$OUT" "Usage: lkml-fleet-status.sh"

PATH="$STUB_PATH" "$status" >/dev/null 2>&1
check "no arguments exits non-zero" "1" "$?"

OUT="$(PATH="$STUB_PATH" "$status" 99999999 --mail-root "$root" 2>&1)"; RC=$?
if (( RC != 0 )); then ok "unknown thread-id exits non-zero"; else no "unknown thread-id exits non-zero" "exit 0"; fi
contains "unknown thread-id names the root it looked in" "$OUT" "$root"

OUT="$(PATH="$STUB_PATH" "$status" 11111111 --mail-root "$root" 2>&1)"; RC=$?
if (( RC != 0 )); then ok "ambiguous prefix exits non-zero"; else no "ambiguous prefix exits non-zero" "exit 0"; fi
contains "ambiguous prefix names candidate t1" "$OUT" "$t1"
contains "ambiguous prefix names candidate t2" "$OUT" "$t2"

OUT="$(PATH="$STUB_PATH" "$status" --mail-root "$work/no-such-root" --list 2>&1)"; RC=$?
if (( RC != 0 )); then ok "missing mail root exits non-zero"; else no "missing mail root exits non-zero" "exit 0"; fi
contains "missing mail root names the path it wanted" "$OUT" "$work/no-such-root"

printf '\n== --list: one line per thread ==\n'
OUT="$(PATH="$STUB_PATH" "$status" --list --mail-root "$root" 2>&1)"; RC=$?
check "--list exits 0" "0" "$RC"
check "--list prints one line per thread" "7" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
contains "--list shows t1's short id" "$OUT" "1111111"
contains "--list shows t2's root Subject" "$OUT" "Unrelated thread"
contains "--list shows t1's root Subject" "$OUT" "[PATCH v1 0/2] Improve the thing"
contains "--list shows t1's newest date" "$OUT" "$(D 14)"
not_contains "--list does not render the dot-directory as a thread" "$OUT" ".stray"

printf '\n== the screen: header, versions, seats, unanswered ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "$t1" --mail-root "$root" 2>&1)"; RC=$?
check "thread screen exits 0" "0" "$RC"
contains "header: short id and root Subject" "$OUT" "Thread: 1111111  [PATCH v1 0/2] Improve the thing"
contains "header: total message count" "$OUT" "Messages: 15"
contains "header: date span oldest..newest" "$OUT" "$(D 0) .. $(D 14)"
contains "versions: v1 first seen and count" "$OUT" "v1  first seen $(D 0)  5 messages"
contains "versions: v2 first seen and count" "$OUT" "v2  first seen $(D 5)  10 messages"
not_contains "versions: the token is not doubled" "$OUT" "vv"

contains "seats: @author sent count" "$OUT" '@author  sent 7'
contains "seats: @ci latest tag" "$OUT" '@ci  sent 1  last '"$(D 2)"'  tags: Tested-by'
LINE="$(grep -F '@review-one ' <<<"$OUT" | head -n1)"
contains "seats: @review-one latest tag is the NAK" "$LINE" "tags: NAK"
LINE="$(grep -F '@review-three ' <<<"$OUT" | head -n1)"
contains "seats: superseding Reviewed-by reported" "$LINE" "tags: Reviewed-by"
not_contains "seats: superseded Changes-requested not reported" "$LINE" "Changes-requested"

contains "never-replied: panel member reached only via the list" "$OUT" '@review-two (via @panel)'
contains "never-replied: direct Cc address that never sent" "$OUT" '@maintainer (unexpanded)'
not_contains "never-replied: a sending seat is not listed" "$OUT" '@review-one (via'
not_contains "never-replied: a sending list member is not listed" "$OUT" '@review-three (via'

contains "unanswered: the unanswered NAK is listed" "$OUT" 'b011000  @review-one  NAK  Re: [PATCH v2 1/2] Add the feature'
not_contains "unanswered: Question answered by a different sender is not listed" "$OUT" "b009000"
not_contains "unanswered: Changes-requested answered by a different sender is not listed" "$OUT" "b004000"
not_contains "unanswered: no convergence verdict is printed" "$OUT" "converged"

printf '\n== hop and spawns: the router budget ==\n'
contains "section is present" "$OUT" "== Hop and Spawns =="
contains "hops: lowest and newest across the thread" "$OUT" "hops: lowest 1, newest 4"
contains "spawns count labelled as the budget" "$OUT" "spawns (budget): 3"
contains "seq count labelled as never reset" "$OUT" "seq (never reset): 5"
contains "spawns/seq difference labelled" "$OUT" "seq - spawns = 2"
contains "difference explained as the operator reset" "$OUT" "zeroed by an operator mail"
not_contains "unflagged thread carries no needs-operator line" "$OUT" "NEEDS OPERATOR"

OUT="$(PATH="$STUB_PATH" "$status" "$t2" --mail-root "$root" 2>&1)"; RC=$?
check "flagged thread screen exits 0" "0" "$RC"
contains "needs-operator flag is printed loudly" "$OUT" "NEEDS OPERATOR: hops exhausted at c0010000"
contains "flagged thread's consequence is stated" "$OUT" "will not restart until someone mails into it"
contains "operator-reset spawns count is 0" "$OUT" "spawns (budget): 0"
contains "seq survives the operator reset" "$OUT" "seq (never reset): 1"
contains "difference of 1 labelled too" "$OUT" "seq - spawns = 1"

printf '\n== failed first wake: flag without budget files ==\n'
rm -- "$pm/spawns/$t2" "$pm/seq/$t2"
printf 'failed to launch first wake\n' > "$pm/needs-operator/$t2"
OUT="$(PATH="$STUB_PATH" "$status" "$t2" --mail-root "$root" 2>&1)"; RC=$?
check "failed-first-wake screen exits 0" "0" "$RC"
contains "failed-first-wake reports the required warning" "$OUT" "NEEDS OPERATOR: failed to launch first wake"
contains "failed-first-wake states the restart consequence" "$OUT" "will not restart until someone mails into it"
contains "failed-first-wake still identifies missing budget state" "$OUT" "router state unknown -- missing or unreadable budget files"

printf '\n== a thread that is not a patch series ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "$t3" --mail-root "$root2" 2>&1)"; RC=$?
check "version-less thread screen exits 0" "0" "$RC"
contains "version-less thread says so" "$OUT" "(no version in any Subject"
not_contains "version-less thread is not given an invented v1" "$OUT" "v1  first seen"
contains "no router state is stated plainly" "$OUT" "(no router state for this thread -- not routed yet)"
not_contains "no budget zero that reads like exhausted" "$OUT" "spawns (budget): 0"
not_contains "no seq zero that reads like exhausted" "$OUT" "seq (never reset): 0"
not_contains "no flag on an unrouted thread" "$OUT" "NEEDS OPERATOR"
contains "hops still reported from the messages" "$OUT" "hops: lowest 8, newest 8"

printf '\n== cost per agent: the router run ledger ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "$t1" --mail-root "$root" 2>&1)"; RC=$?
check "cost screen exits 0" "0" "$RC"
contains "cost prefers a completed run's total cost" "$OUT" "review-one  3 runs  \$4.750000 (1 no summary, 1 unreadable)"
contains "cost sums a completed run for the second agent" "$OUT" "review-two  2 runs  \$2.500000 (1 no cost)"
contains "missing summary is counted in the run total" "$OUT" 'runs: 6 (1 no summary, 2 no cost, 1 unreadable)'
not_contains "a different thread run is not counted" "$OUT" 'other-agent'
contains "null cost is counted and annotated" "$OUT" "review-two  2 runs  \$2.500000 (1 no cost)"
contains "null cost does not add zero to an agent's sum" "$OUT" "review-two  2 runs  \$2.500000 (1 no cost)"
contains "only-null-cost agent is annotated" "$OUT" "review-null  1 run  \$0.000000 (1 no cost)"
contains "missing summary and unreadable cost co-occur per agent" "$OUT" "review-one  3 runs  \$4.750000 (1 no summary, 1 unreadable)"
contains "all runs including null and unparseable costs are counted" "$OUT" 'runs: 6 (1 no summary, 2 no cost, 1 unreadable)'
contains "missing summary and no cost co-occur in the total" "$OUT" '(1 no summary, 2 no cost, 1 unreadable)'
contains "garbage summary is annotated as unreadable, not no cost" "$OUT" "review-one  3 runs  \$4.750000 (1 no summary, 1 unreadable)"

printf '\n== cost per agent: parser semantics (string, bool, sum) ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "$t4" --mail-root "$root" 2>&1)"; RC=$?
check "parser semantics screen exits 0" "0" "$RC"
contains "a JSON string cost is not summed" "$OUT" "parser-string  1 run  \$0.000000 (1 no cost)"
contains "a JSON true cost is not summed (the isinstance(bool, int) trap)" "$OUT" "parser-bool  1 run  \$0.000000 (1 no cost)"
contains "two real-number runs by one agent sum correctly" "$OUT" "parser-sum  2 runs  \$3.750000"
# These digits are the float64 round-trip of the 10^30 fixture above,
# not 10^30 itself -- see the comment there before touching them.
contains "a huge magnitude is a real cost and is summed, not filtered by size" "$OUT" "parser-huge  1 run  \$1000000000000000019884624838656.000000"
contains "a magnitude beyond float range is invalid, not silently no cost" "$OUT" "parser-overflow  1 run  \$0.000000 (1 invalid)"
contains "a real cost below 1e-4 is summed, not lost to exponent notation" "$OUT" "parser-tiny  1 run  \$0.000012"
contains "totals count the string/bool runs as no cost and the overflow run as invalid" "$OUT" 'runs: 7 (2 no cost, 1 invalid)'

printf '\n== cost parser unavailable: the inventory must survive ==\n'
not_contains "unreadable never appears when python3 is available" "$OUT" 'unreadable)'

no_python_bin="$work/no-python-bin"; mkdir -p -- "$no_python_bin"
for command in bash awk date head sed sort; do
    ln -s "$(command -v "$command")" "$no_python_bin/$command"
done
ln -s "$stub_bin/fork-sandbox" "$no_python_bin/fork-sandbox"
OUT="$(PATH="$no_python_bin" "$status" "$t1" --mail-root "$root" 2>&1)"; RC=$?
check "missing python3 does not fail the screen" "0" "$RC"
contains "missing python3 is reported explicitly, naming python3" "$OUT" "python3"
contains "missing python3 explains runs as unreadable" "$OUT" "unreadable"
contains "missing python3 still prints the run inventory" "$OUT" 'runs: 6 (1 no summary, 5 unreadable)'
not_contains "missing python3 is not reported as no-cost runs" "$OUT" 'runs: 6 (1 no summary, 3 no cost)'
not_contains "unreadable never collapses into no cost" "$OUT" 'no cost'
contains "missing python3 still prints per-agent rows" "$OUT" "review-one  3 runs  \$0.000000 (1 no summary, 2 unreadable)"
contains "a run with a summary.json is unreadable, not no-cost, without python3" "$OUT" "review-two  2 runs  \$0.000000 (2 unreadable)"
contains "an absent summary.json is still no summary, not unreadable, without python3" "$OUT" "review-one  3 runs  \$0.000000 (1 no summary, 2 unreadable)"
contains "a lone unreadable run is annotated too" "$OUT" "review-null  1 run  \$0.000000 (1 unreadable)"

printf '\n== cost per agent: python3 present but failing must not read as no cost ==\n'
bad_python_bin="$work/bad-python-bin"; mkdir -p -- "$bad_python_bin"
for command in bash awk date head sed sort; do
    ln -s "$(command -v "$command")" "$bad_python_bin/$command"
done
ln -s "$stub_bin/fork-sandbox" "$bad_python_bin/fork-sandbox"
cat > "$bad_python_bin/python3" <<'STUB'
#!/usr/bin/env bash
# On PATH, but writes nothing and fails: the shape of a stale
# pyenv/conda shim, an exec failure, or an OOM kill.
exit 127
STUB
chmod +x -- "$bad_python_bin/python3"
OUT="$(PATH="$bad_python_bin" "$status" "$t1" --mail-root "$root" 2>&1)"; RC=$?
check "python3 present but failing does not fail the screen" "0" "$RC"
contains "a failing python3 explains runs as unreadable" "$OUT" "unreadable"
contains "a failing python3 reports the generic parse-failure message" "$OUT" '(some summary.json files could not be parsed and are counted as unreadable)'
not_contains "a failing python3 is not reported as python3 missing" "$OUT" "python3 not found"
contains "a failing python3 still prints the run inventory" "$OUT" 'runs: 6 (1 no summary, 5 unreadable)'
not_contains "a failing python3 never launders a costed run into no cost" "$OUT" 'no cost'
contains "a costed run is unreadable, not a bare zero with no annotation" "$OUT" "review-one  3 runs  \$0.000000 (1 no summary, 2 unreadable)"
contains "a second agent's costed run is unreadable too, not dropped" "$OUT" "review-two  2 runs  \$0.000000 (2 unreadable)"
contains "a lone run is unreadable, not silently free" "$OUT" "review-null  1 run  \$0.000000 (1 unreadable)"

# The exit-127 stub above fails AND writes nothing, so it trips both
# halves of the trust gate's disjunct at once and cannot tell them
# apart. A reviewer proved that gap by mutation: changing the gate's
# `||` to `&&` still passed the whole suite, because nothing here forces
# python3 to exit 0 while still under-producing lines. This stub is that
# fixture's sibling -- it exits 0 but prints fewer lines than the paths
# it was given, the shape of a batch that died partway through -- so the
# "wrong line count" half of the gate has a fixture that only it catches.
partial_python_bin="$work/partial-python-bin"; mkdir -p -- "$partial_python_bin"
for command in bash awk date head sed sort; do
    ln -s "$(command -v "$command")" "$partial_python_bin/$command"
done
ln -s "$stub_bin/fork-sandbox" "$partial_python_bin/fork-sandbox"
cat > "$partial_python_bin/python3" <<'STUB'
#!/usr/bin/env bash
# Exits 0, ignores its arguments, and prints fewer result lines than
# it was given paths -- but more than zero, since a zero-line reply
# would also mismatch and prove nothing about the partial case this
# stub exists for.
printf '0.500000\n0.500000\n0.500000\n'
STUB
chmod +x -- "$partial_python_bin/python3"
OUT="$(PATH="$partial_python_bin" "$status" "$t1" --mail-root "$root" 2>&1)"; RC=$?
check "python3 present but under-producing does not fail the screen" "0" "$RC"
contains "an under-producing python3 explains runs as unreadable" "$OUT" "unreadable"
contains "an under-producing python3 reports the generic parse-failure message" "$OUT" '(some summary.json files could not be parsed and are counted as unreadable)'
contains "an under-producing python3 still prints the run inventory" "$OUT" 'runs: 6 (1 no summary, 5 unreadable)'
not_contains "an under-producing python3 never launders a costed run into no cost" "$OUT" 'no cost'
not_contains "an under-producing python3's partial output is never zipped onto an agent" "$OUT" '0.500000'
contains "a costed run is unreadable under a partial batch, not a bare zero" "$OUT" "review-one  3 runs  \$0.000000 (1 no summary, 2 unreadable)"
contains "a second agent's costed run is unreadable under a partial batch too" "$OUT" "review-two  2 runs  \$0.000000 (2 unreadable)"
contains "a lone run is unreadable under a partial batch, not silently free" "$OUT" "review-null  1 run  \$0.000000 (1 unreadable)"

printf '\n== cost per agent: a malformed totals line must poison the batch, not partially sum ==\n'
real_python3="$(command -v python3)"
corrupt_python_bin="$work/corrupt-python-bin"; mkdir -p -- "$corrupt_python_bin"
for command in bash awk date head sed sort; do
    ln -s "$(command -v "$command")" "$corrupt_python_bin/$command"
done
ln -s "$stub_bin/fork-sandbox" "$corrupt_python_bin/fork-sandbox"
cat > "$corrupt_python_bin/python3" <<STUB
#!/usr/bin/env bash
# Runs the real classifier untouched, then overwrites the last line of
# its output -- ordinarily a TOTAL line -- with garbage that matches
# neither the TOTAL nor the sentinel shape. This pins one disjunct of
# the gate: a present-but-malformed TOTAL line trips batch_ok=0 (missing
# sentinel and wrong line count are covered by the stubs above; this
# screen has no GRAND line to malform -- that's lkml-status.sh's alone).
# It does NOT prove the gate catches every corrupt-block shape: an
# entirely dropped TOTAL line for one agent leaves every remaining line
# well-formed, so batch_ok stays 1 and that agent's cost silently
# displays as a bare, unannotated 0 -- reproduced outside this suite,
# not fixed here, since the fix would touch the positional gate the
# handoff fenced out of scope for this round. That gap is left for the
# operator to weigh, not papered over by this stub or its assertions.
mapfile -t lines < <("$real_python3" "\$@")
lines[-1]='not a totals line'
printf '%s\n' "\${lines[@]}"
STUB
chmod +x -- "$corrupt_python_bin/python3"
OUT="$(PATH="$corrupt_python_bin" "$status" "$t1" --mail-root "$root" 2>&1)"; RC=$?
check "a corrupt totals block does not fail the screen" "0" "$RC"
contains "a corrupt totals block explains runs as unreadable" "$OUT" "unreadable"
contains "a corrupt totals block still prints the run inventory" "$OUT" 'runs: 6 (1 no summary, 5 unreadable)'
not_contains "a corrupt totals block never launders a costed run into no cost" "$OUT" 'no cost'
contains "a costed run is unreadable under a corrupt totals block, not a bare zero" "$OUT" "review-one  3 runs  \$0.000000 (1 no summary, 2 unreadable)"
contains "a second agent's costed run is unreadable under a corrupt totals block too" "$OUT" "review-two  2 runs  \$0.000000 (2 unreadable)"
contains "a lone run is unreadable under a corrupt totals block, not silently free" "$OUT" "review-null  1 run  \$0.000000 (1 unreadable)"

# python3 is only needed for summaries belonging to the requested thread.
# An otherwise populated ledger must still report observable no-run and
# no-summary states when that parser is absent.
rm -- "$pm/runs/run-d.env"
OUT="$(PATH="$no_python_bin" "$status" "$t2" --mail-root "$root" 2>&1)"; RC=$?
check "missing python3 with only other-thread runs does not fail" "0" "$RC"
contains "other-thread runs still report no runs" "$OUT" '(no runs recorded)'
not_contains "an empty ledger does not mention python3" "$OUT" 'python3'

mkdir -p -- "$root2/.postmaster/runs"
printf 'agent=review-pending\nthread=%s\nrun_dir=%s\n' "$t3" "$work/no-summary" > "$root2/.postmaster/runs/run-pending.env"
OUT="$(PATH="$no_python_bin" "$status" "$t3" --mail-root "$root2" 2>&1)"; RC=$?
check "missing python3 with missing summary does not fail" "0" "$RC"
contains "missing summaries remain countable without python3" "$OUT" 'runs: 1 (1 no summary)'
not_contains "a run classified purely as no summary does not mention python3" "$OUT" 'python3'
not_contains "an absent summary.json is never counted as unreadable" "$OUT" 'unreadable)'

printf '\n== tag colon requirement: prose is not a cast verdict ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "$t5" --mail-root "$root" 2>&1)"; RC=$?
check "tag colon fixture screen exits 0" "0" "$RC"

LINE="$(grep -F '@reviewer-prose ' <<<"$OUT" | head -n1)"
contains "real reviewer prose about verdicts yields no tags" "$LINE" "tags: -"

LINE="$(grep -F '@reviewer-colon ' <<<"$OUT" | head -n1)"
contains "a genuine colon trailer still counts" "$LINE" "tags: Reviewed-by"

LINE="$(grep -F '@reviewer-bare ' <<<"$OUT" | head -n1)"
contains "a bare trailer with no colon no longer counts" "$LINE" "tags: -"

LINE="$(grep -F '@reviewer-mixed ' <<<"$OUT" | head -n1)"
contains "a genuine trailer plus bare prose reports only the trailer" "$LINE" "tags: Reviewed-by"
not_contains "the bare prose word is not also reported" "$LINE" "Tested-by"

LINE="$(grep -F '@reviewer-quoted ' <<<"$OUT" | head -n1)"
contains "a quoted trailer still yields nothing" "$LINE" "tags: -"

LINE="$(grep -F '@reviewer-nak ' <<<"$OUT" | head -n1)"
contains "a bare NAK on the first line still counts" "$LINE" "tags: NAK"

LINE="$(grep -F '@reviewer-chreq ' <<<"$OUT" | head -n1)"
contains "a bare Changes-requested on the first line still counts" "$LINE" "tags: Changes-requested"

LINE="$(grep -F '@reviewer-question ' <<<"$OUT" | head -n1)"
contains "a bare Question on the last line still counts" "$LINE" "tags: Question"

LINE="$(grep -F '@reviewer-progress ' <<<"$OUT" | head -n1)"
contains "latest-message-wins: a later bare verdict supersedes an earlier colon trailer" "$LINE" "tags: Changes-requested"
not_contains "the superseded trailer is not also reported" "$LINE" "Reviewed-by"

printf '\n== cost per agent: invalid cost is its own state ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "$t6" --mail-root "$root" 2>&1)"; RC=$?
check "invalid-cost fixture screen exits 0" "0" "$RC"
contains "a negative cost is invalid, not summed" "$OUT" "invalid-neg  1 run  \$0.000000 (1 invalid)"
contains "a NaN cost is invalid" "$OUT" "invalid-nan  1 run  \$0.000000 (1 invalid)"
contains "an Infinity cost is invalid" "$OUT" "invalid-inf  1 run  \$0.000000 (1 invalid)"
contains "a -Infinity cost is invalid" "$OUT" "invalid-neginf  1 run  \$0.000000 (1 invalid)"
not_contains "a negative cost is not reported as no cost" "$OUT" "invalid-neg  1 run  \$0.000000 (1 no cost)"
not_contains "a NaN cost is not reported as unreadable" "$OUT" "invalid-nan  1 run  \$0.000000 (1 unreadable)"
contains "no summary, no cost, invalid and unreadable all appear for one agent, distinctly" "$OUT" \
    "mixed-four  4 runs  \$0.000000 (1 no summary, 1 no cost, 1 invalid, 1 unreadable)"
contains "invalid is counted in the totals line too" "$OUT" \
    "runs: 13 (1 no summary, 1 no cost, 6 invalid, 1 unreadable)"
LINE="$(grep -F 'zero-real ' <<<"$OUT" | head -n1)"
check "a real zero cost still sums as zero, with no annotation at all" "zero-real  1 run  \$0.000000" "$LINE"
LINE="$(grep -F 'negzero ' <<<"$OUT" | head -n1)"
check "a real negative-zero cost sums as zero, not as no cost" "negzero  1 run  \$0.000000" "$LINE"
LINE="$(grep -F 'positive-sum ' <<<"$OUT" | head -n1)"
check "a normal positive cost still sums, with no annotation" "positive-sum  1 run  \$2.500000" "$LINE"
LINE="$(grep -F 'poisoned-mix ' <<<"$OUT" | head -n1)"
check "a same-agent invalid cost does not poison the real cost's sum" "poisoned-mix  2 runs  \$2.500000 (1 invalid)" "$LINE"

printf '\n== cost per agent: a run record with no agent= key does not abort the screen ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "$t7" --mail-root "$root" 2>&1)"; RC=$?
# The per-agent listing is `for agent in $(...)`, so "unknown agent" (the
# sentinel, itself containing a space) word-splits into "unknown" and
# "agent" unless the loop reads whole lines -- and under set -u,
# ${RUN_COUNT[unknown]} is a reference to a key that was never set,
# which is fatal, not merely wrong. Confirmed this reproduces before the
# fix: the screen printed "runs: 1" and then aborted with "RUN_COUNT[$agent]:
# unbound variable", never reaching the per-agent rows or exiting 0.
check "missing agent key screen exits 0, does not abort" "0" "$RC"
contains "missing agent key is still counted in the run total" "$OUT" "runs: 1"
contains "missing agent key falls back to the sentinel, on one whole row" "$OUT" \
    "unknown agent  1 run  \$6.000000"
not_contains "the sentinel is never split into two bogus rows" "$OUT" $'unknown  1 run'

printf '\n== cost per agent: a sub-5e-7 aggregate is not silently zeroed ==\n'
# t8 itself is created earlier, alongside t1..t7, so the --list count
# check counts it too -- see the comment there.

# tiny-aggregate: 10000 runs at 1e-7 each, true sum 1e-3. Each addend
# alone rounds to 0.000000 at the screen's 6-decimal convention, so
# only the aggregate crossing that threshold tells a sum carried at
# full precision apart from one that gets re-rounded away after every
# addition. 10000 runs is the exposure bound this fixture always
# intended -- one per costed run below the display floor -- and is
# cheap now that accumulation no longer forks a process per run. The
# mirror fixture in tests/lkml-status-test.sh pins the same chain at a
# cheaper 100-run, display-threshold form instead: that screen is slated
# for retirement, so it doesn't carry this suite's exposure-bound
# rationale. The counts are intentionally asymmetric, not a drift bug.
for i in $(seq -w 1 10000); do
    run_dir="$work/run-tiny-agg-$i"; mkdir -p -- "$run_dir"
    printf '{"total_cost_usd": 1e-7}\n' > "$run_dir/summary.json"
    printf 'agent=tiny-aggregate\nthread=%s\nrun_dir=%s\n' "$t8" "$run_dir" > "$pm/runs/run-tiny-agg-$i.env"
done

# A single run at 1e-7 stays under the screen's 6-decimal display cap --
# accepted, documented behavior, not a bug: telling it apart from a real
# zero would need a 7th displayed digit nobody has asked the screen for.
run_tiny_lone="$work/run-tiny-lone"; mkdir -p -- "$run_tiny_lone"
printf '{"total_cost_usd": 1e-7}\n' > "$run_tiny_lone/summary.json"
printf 'agent=tiny-lone\nthread=%s\nrun_dir=%s\n' "$t8" "$run_tiny_lone" > "$pm/runs/run-tiny-lone.env"

OUT="$(PATH="$STUB_PATH" "$status" "$t8" --mail-root "$root" 2>&1)"; RC=$?
check "sub-5e-7 aggregate fixture screen exits 0" "0" "$RC"
LINE="$(grep -F 'tiny-aggregate ' <<<"$OUT" | head -n1)"
check "10000 runs of 1e-7 sum to a visible cost, not a silent zero" "tiny-aggregate  10000 runs  \$0.001000" "$LINE"
not_contains "the aggregate is not annotated as no cost" "$LINE" "no cost"
not_contains "the aggregate does not display as a bare zero" "$OUT" "tiny-aggregate  10000 runs  \$0.000000"
LINE="$(grep -F 'tiny-lone ' <<<"$OUT" | head -n1)"
check "a single sub-5e-7 run stays under the display cap, unannotated" "tiny-lone  1 run  \$0.000000" "$LINE"

printf '\n== cost per agent: the 5e-11 display floor, at the bottom of its window ==\n'
# floor-pin: 2500 runs at 4e-10 each, reusing t8 above. 4e-10 sits in
# [5e-11, 5e-10): at the classifier's %.10f format its only nonzero
# digit is the 10th decimal place (0.0000000004), so ANY drift to fewer
# displayed digits anywhere between parse and display -- classifier,
# summation, or final rounding -- zeroes every single addend before
# summation, collapsing the true sum from $0.000001 to $0.000000. That
# is the end-to-end precision of the whole chain, pinned directly --
# distinct from the sub-5e-7 aggregate above, which pins the DISPLAY
# threshold and cannot catch this: its 1e-7 addends still round nonzero
# at .9f or .8f, so a precision drift there reads fully green. 2500
# runs of 4e-10 sum to exactly 1e-6 (well past the 1251-run minimum
# that clears the 5e-7 display threshold), which displays as
# $0.000001.
for i in $(seq -w 1 2500); do
    run_dir="$work/run-floor-pin-$i"; mkdir -p -- "$run_dir"
    printf '{"total_cost_usd": 4e-10}\n' > "$run_dir/summary.json"
    printf 'agent=floor-pin\nthread=%s\nrun_dir=%s\n' "$t8" "$run_dir" > "$pm/runs/run-floor-pin-$i.env"
done

OUT="$(PATH="$STUB_PATH" "$status" "$t8" --mail-root "$root" 2>&1)"; RC=$?
check "floor-pin fixture screen exits 0" "0" "$RC"
LINE="$(grep -F 'floor-pin ' <<<"$OUT" | head -n1)"
check "2500 runs of 4e-10 sum to exactly the display floor, not a silent zero" \
    "floor-pin  2500 runs  \$0.000001" "$LINE"
not_contains "the floor-pin aggregate does not display as a bare zero" "$OUT" "floor-pin  2500 runs  \$0.000000"
not_contains "the floor-pin aggregate is not annotated as no cost" "$LINE" "no cost"

# floor-gone: 13000 runs at 4e-11 each, below the old 5e-11 floor this
# fold removed. Its .10f text is 0.0000000000 -- all zeros -- so the
# retired awk chain, which round-tripped each addend through that text
# before summing, added 13000 exact zeros and reported $0.000000. The
# fold sums the float itself (4e-11 never touches text until the
# total), so its true sum, 5.2e-7, survives and displays as $0.000001.
# This is the fixture a reviewer flagged as untestable before the fold
# -- a deleted follow-up doc warned that adding it pre-fold would be
# meaningless, since nothing then could tell a real sub-floor sum from
# a floored one -- and is exactly the fixture that tells them apart
# now. Fleet-suite only: the status screen runs the identical chain
# and is already pinned by its own mirror fixtures (cost-floor-pin
# etc in tests/lkml-status-test.sh); that suite's own per-fixture cost
# is the subject of a separate commit, not this fixture.
for i in $(seq -w 1 13000); do
    run_dir="$work/run-floor-gone-$i"; mkdir -p -- "$run_dir"
    printf '{"total_cost_usd": 4e-11}\n' > "$run_dir/summary.json"
    printf 'agent=floor-gone\nthread=%s\nrun_dir=%s\n' "$t8" "$run_dir" > "$pm/runs/run-floor-gone-$i.env"
done

OUT="$(PATH="$STUB_PATH" "$status" "$t8" --mail-root "$root" 2>&1)"; RC=$?
check "floor-gone fixture screen exits 0" "0" "$RC"
LINE="$(grep -F 'floor-gone ' <<<"$OUT" | head -n1)"
check "13000 runs of 4e-11 sum past the old floor only under float-carried summation" \
    "floor-gone  13000 runs  \$0.000001" "$LINE"
not_contains "the floor-gone aggregate does not display as a bare zero" "$OUT" "floor-gone  13000 runs  \$0.000000"
not_contains "the floor-gone aggregate is not annotated as no cost" "$LINE" "no cost"

printf '\n== prefix resolution ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "${t1:0:12}" --mail-root "$root" 2>&1)"; RC=$?
check "unambiguous prefix resolves" "0" "$RC"
contains "unambiguous prefix shows the resolved screen" "$OUT" "Thread: 1111111"

printf '\n== the script writes nothing ==\n'
BEFORE="$(snapshot_store "$root")"
PATH="$STUB_PATH" "$status" "$t1" --mail-root "$root" >/dev/null 2>&1
PATH="$STUB_PATH" "$status" --list --mail-root "$root" >/dev/null 2>&1
AFTER="$(snapshot_store "$root")"
check "store is byte-identical after runs" "$BEFORE" "$AFTER"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
