#!/usr/bin/env bash
# lkml-status-test.sh — Exercise lkml-status.sh's cost column against
# hand-written runs.jsonl ledgers and summary.json fixtures, one series
# per fixture group so a poisoned aggregate (e.g. a huge-magnitude cost
# going to +inf) in one series can never contaminate another series'
# assertions.
#
# Usage: tests/lkml-status-test.sh

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
status="${LKML_STATUS:-$repo_dir/scripts/lkml-status.sh}"
mailbox="$repo_dir/scripts/lkml-mailbox.sh"

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
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")

# lkml-status.sh shells out to lkml-mailbox.sh for tree/tally/open, so a
# stub PATH for these tests must carry everything BOTH scripts need, not
# just lkml-status.sh's own direct calls (jq, tail, grep, readlink,
# dirname) -- confirmed by actually running the script under a trimmed
# stub and hitting "tail: command not found" before reaching the cost
# section at all.
build_stub_path() {
    local dir="$1" c
    mkdir -p -- "$dir"
    for c in bash jq git sed awk sort grep head tail find wc cut tr stat uuidgen date readlink dirname; do
        ln -sf "$(command -v "$c")" "$dir/$c"
    done
}

fixture_cover() {
    printf 'Add the frobnicator\n\nThis series adds a frobnicator to the widget subsystem.\n' > "$1"
}

fixture_patches() {
    local dir="$1"
    mkdir -p "$dir"
    printf 'Subject: [PATCH 1/1] frob: add core\n\ndiff --git a/frob.c b/frob.c\n+int frob(void) { return 0; }\n' \
        > "$dir/0001-add-core.patch"
}

init_series() {
    local series="$1"
    fixture_cover "$work/$series-cover.txt"
    fixture_patches "$work/$series-patches"
    "$mailbox" init "$series" --cover "$work/$series-cover.txt" --patches "$work/$series-patches" \
        --from author --no-checkout >/dev/null
}

# write_run <series> <run_dir> <persona>
# Appends one runs.jsonl line for <series>. Caller writes <run_dir>'s
# summary.json (or leaves it absent) separately.
write_run() {
    local series="$1" run_dir="$2" persona="$3"
    printf '{"run_dir":"%s","persona":"%s"}\n' "$run_dir" "$persona" \
        >> "$LKML_MAILBOX_ROOT/$series/runs.jsonl"
}

printf '\n== --help and usage errors ==\n'
OUT="$("$status" --help 2>&1)"; RC=$?
check "--help exits 0" "0" "$RC"
contains "--help prints the usage line" "$OUT" "Usage: lkml-status.sh"

OUT="$("$status" no-such-series 2>&1)"; RC=$?
if (( RC != 0 )); then ok "unknown series exits non-zero"; else no "unknown series exits non-zero" "exit 0"; fi
contains "unknown series names the series" "$OUT" "no-such-series"

printf '\n== no runs recorded ==\n'
init_series cost-empty
OUT="$("$status" cost-empty 2>&1)"; RC=$?
check "no ledger exits 0" "0" "$RC"
contains "no ledger prints (no runs recorded)" "$OUT" "(no runs recorded)"

printf '\n== cost-basic: every unusable-cost shape, one persona each ==\n'
init_series cost-basic

mkdir -p "$work/cb-absent" "$work/cb-isnull" "$work/cb-isfalse" "$work/cb-istrue" \
    "$work/cb-corrupt" "$work/cb-isstring" "$work/cb-negative" "$work/cb-fallback"
printf '{}' > "$work/cb-absent/summary.json"
printf '{"total_cost_usd": null, "cost_usd": null}' > "$work/cb-isnull/summary.json"
printf '{"total_cost_usd": false}' > "$work/cb-isfalse/summary.json"
printf '{"total_cost_usd": true}' > "$work/cb-istrue/summary.json"
printf 'not json at all' > "$work/cb-corrupt/summary.json"
printf '{"total_cost_usd": "1.23"}' > "$work/cb-isstring/summary.json"
printf '{"total_cost_usd": -5.5}' > "$work/cb-negative/summary.json"
printf '{"cost_usd": 2.5}' > "$work/cb-fallback/summary.json"

write_run cost-basic "$work/cb-absent" absent
write_run cost-basic "$work/cb-isnull" isnull
write_run cost-basic "$work/cb-isfalse" isfalse
write_run cost-basic "$work/cb-istrue" istrue
write_run cost-basic "$work/cb-corrupt" corrupt
write_run cost-basic "$work/cb-isstring" isstring
write_run cost-basic "$work/cb-negative" negative
write_run cost-basic "$work/cb-fallback" fallback

OUT="$("$status" cost-basic 2>/dev/null)"
contains "cost-basic: runs launched is 8" "$OUT" "Runs launched: 8"
contains "cost-basic: runs launched names the four states" "$OUT" \
    "Runs launched: 8 (5 no cost, 1 invalid, 1 unreadable)"
# An absent field is classified "no cost", not summed as a real $0.
contains "cost-basic: absent field is no cost" "$OUT" "absent         \$0.000000 (1 no cost)"
not_contains "cost-basic: absent field is never claimed free" "$OUT" $'absent         $0.000000\n'
contains "cost-basic: null field is no cost" "$OUT" "isnull         \$0.000000 (1 no cost)"
# jq's `//` treated `false` as absent too; the classifier does the same,
# but now says so instead of leaving it silently free.
contains "cost-basic: false field is no cost" "$OUT" "isfalse        \$0.000000 (1 no cost)"
# `true` is a bool, explicitly excluded from the numeric check -- no cost.
contains "cost-basic: true field is no cost" "$OUT" "istrue         \$0.000000 (1 no cost)"
# A corrupt summary.json fails json.load() in the python3 classifier and
# is unreadable, not silently summed as 0.
contains "cost-basic: corrupt file is unreadable" "$OUT" "corrupt        \$0.000000 (1 unreadable)"
not_contains "cost-basic: corrupt file is never claimed free" "$OUT" $'corrupt        $0.000000\n'
# A JSON string cost is excluded by the numeric-type check -- no cost,
# no longer silently accepted and summed as a real number.
contains "cost-basic: string cost is no cost, not summed" "$OUT" "isstring       \$0.000000 (1 no cost)"
not_contains "cost-basic: string cost is never claimed to be \$1.23" "$OUT" "isstring       \$1.230000"
# A negative cost is invalid, no longer summed as negative unannotated.
# (No separate not_contains here: `negative` is the last row printed --
# sorted after absent, corrupt, fallback, isfalse, isnull, isstring,
# istrue -- so a $'...\n'-anchored needle would have nothing after it to
# match against once $(...) strips OUT's trailing newline, making such an
# assertion pass unconditionally. The `contains` above already demands
# the annotated form, which is the real regression guard.)
contains "cost-basic: fallback cost_usd is used and summed" "$OUT" "fallback       \$2.500000"
not_contains "cost-basic: fallback is not annotated" "$OUT" "fallback       \$2.500000 ("
# Aggregate: only fallback's 2.5 is a usable cost now.
contains "cost-basic: aggregate sums only the usable cost" "$OUT" "Total cost so far: \$2.500000"

printf '\n== cost-sum: valid costs summed, including a below-1e-4 cost and -0.0 ==\n'
init_series cost-sum
mkdir -p "$work/cs-summed-a" "$work/cs-summed-b" "$work/cs-tiny" "$work/cs-negzero"
printf '{"total_cost_usd": 1.5}' > "$work/cs-summed-a/summary.json"
printf '{"cost_usd": 2.25}' > "$work/cs-summed-b/summary.json"
printf '{"total_cost_usd": 0.000012}' > "$work/cs-tiny/summary.json"
printf '{"total_cost_usd": -0.0}' > "$work/cs-negzero/summary.json"
write_run cost-sum "$work/cs-summed-a" summed
write_run cost-sum "$work/cs-summed-b" summed
write_run cost-sum "$work/cs-tiny" tiny
write_run cost-sum "$work/cs-negzero" negzero

OUT="$("$status" cost-sum 2>/dev/null)"
contains "cost-sum: runs launched is 4" "$OUT" "Runs launched: 4"
contains "cost-sum: two runs by one persona are summed together" "$OUT" "summed         \$3.750000"
contains "cost-sum: a real cost below 1e-4 is summed, not lost" "$OUT" "tiny           \$0.000012"
not_contains "cost-sum: the below-1e-4 cost is not annotated as no cost" "$OUT" "tiny           \$0.000012 ("
contains "cost-sum: negative zero sums as a real zero" "$OUT" "negzero        \$0.000000"
not_contains "cost-sum: negative zero is not reported as no cost" "$OUT" "negzero        \$0.000000 ("
contains "cost-sum: aggregate is the sum of all four" "$OUT" "Total cost so far: \$3.750012"

printf '\n== cost-tiny-aggregate: a sub-5e-7 aggregate is not silently zeroed ==\n'
# Mirrors tests/lkml-fleet-status-test.sh's fixture, sized differently on
# purpose: this script's classifier and accumulator must match that
# one's exactly (see the "One interpreter for the whole ledger" comment
# in lkml-status.sh), so the same sub-5e-7 blind spot the fleet screen
# was fixed for must be fixed here too, or the two screens would print
# different costs for the same runs. This screen is slated for
# retirement, so it pins the same chain at the cheap 100-run
# display-threshold form rather than the fleet suite's 10000-run
# exposure-bound form -- the same per-suite sizing asymmetry the
# cost-floor-pin fixtures below already use (2500 runs in the fleet
# suite, 1300 here). The counts are intentionally asymmetric, not a
# drift bug.
init_series cost-tiny-aggregate
for i in $(seq -w 1 100); do
    run_dir="$work/cta-agg-$i"; mkdir -p -- "$run_dir"
    printf '{"total_cost_usd": 1e-7}\n' > "$run_dir/summary.json"
    write_run cost-tiny-aggregate "$run_dir" tiny-aggregate
done
mkdir -p -- "$work/cta-lone"
printf '{"total_cost_usd": 1e-7}\n' > "$work/cta-lone/summary.json"
write_run cost-tiny-aggregate "$work/cta-lone" tiny-lone

OUT="$("$status" cost-tiny-aggregate 2>/dev/null)"
contains "cost-tiny-aggregate: 100 runs of 1e-7 sum to a visible cost, not a silent zero" "$OUT" \
    "tiny-aggregate \$0.000010"
not_contains "cost-tiny-aggregate: the aggregate does not display as a bare zero" "$OUT" \
    "tiny-aggregate \$0.000000"
contains "cost-tiny-aggregate: a single sub-5e-7 run stays under the display cap, unannotated" "$OUT" \
    "tiny-lone      \$0.000000"
not_contains "cost-tiny-aggregate: the single sub-5e-7 run is not annotated as no cost" "$OUT" \
    "tiny-lone      \$0.000000 ("
contains "cost-tiny-aggregate: the total reflects the full-precision sum, not a re-rounded one" "$OUT" \
    "Total cost so far: \$0.000010"

printf '\n== cost-floor-pin: the 5e-11 display floor, at the bottom of its window ==\n'
# Mirrors tests/lkml-fleet-status-test.sh's floor-pin fixture: this
# script's classifier and accumulator must match that one's exactly
# (see the "One interpreter for the whole ledger" comment in
# lkml-status.sh), so the same floor blind spot pinned there must be
# pinned here too. 4e-10 sits in [5e-11, 5e-10): its only nonzero digit
# at .10f is the 10th decimal place, so ANY drift to fewer displayed
# digits anywhere between parse and display zeroes every addend --
# unlike the cost-tiny-aggregate fixture above, whose 1e-7 addends
# survive a drift to .9f or .8f and would read fully green. This screen
# emits both a per-persona total and a grand total, so both are
# asserted below. 1300 runs, not the 2500 that would exactly round-trip
# to 1e-6: this screen still forks three jq processes per ledger line,
# well above the fleet screen's fork-free env parse, so 1300 (just past
# the 1251-run minimum that clears the 5e-7 display threshold) is the
# cheaper fixture with the same distinguishing power.
init_series cost-floor-pin
for i in $(seq -w 1 1300); do
    run_dir="$work/cfp-$i"; mkdir -p -- "$run_dir"
    printf '{"total_cost_usd": 4e-10}\n' > "$run_dir/summary.json"
    write_run cost-floor-pin "$run_dir" floor-pin
done

OUT="$("$status" cost-floor-pin 2>/dev/null)"
contains "cost-floor-pin: 1300 runs of 4e-10 clear the display floor" "$OUT" \
    "floor-pin      \$0.000001"
not_contains "cost-floor-pin: the per-persona row does not display as a bare zero" "$OUT" \
    "floor-pin      \$0.000000"
contains "cost-floor-pin: the total reflects the floor sum, not a re-rounded zero" "$OUT" \
    "Total cost so far: \$0.000001"

printf '\n== cost-huge: a magnitude no float can hold ==\n'
init_series cost-huge
mkdir -p "$work/ch-huge"
huge_digits="$(printf '1%.0s' $(seq 1 400))"
printf '{"total_cost_usd": %s}' "$huge_digits" > "$work/ch-huge/summary.json"
write_run cost-huge "$work/ch-huge" huge

OUT="$("$status" cost-huge 2>/dev/null)"
contains "cost-huge: runs launched is 1" "$OUT" "Runs launched: 1 (1 invalid)"
# A magnitude no float can hold overflows math.isfinite() (OverflowError)
# in the python3 classifier and is invalid, not summed into +inf.
contains "cost-huge: an unrepresentable magnitude is invalid" "$OUT" "huge           \$0.000000 (1 invalid)"
not_contains "cost-huge: the aggregate is never +inf" "$OUT" "+inf"
contains "cost-huge: the aggregate stays a real zero" "$OUT" "Total cost so far: \$0.000000"

printf '\n== cost-malformed: a ledger line that is not valid JSON at all ==\n'
init_series cost-malformed
mkdir -p "$work/cm-clean"
printf '{"total_cost_usd": 4.0}' > "$work/cm-clean/summary.json"
write_run cost-malformed "$work/cm-clean" clean
printf 'not a json line at all\n' >> "$LKML_MAILBOX_ROOT/cost-malformed/runs.jsonl"
# Valid JSON that simply omits persona still names a run_dir -- it is
# classified by that run_dir like any other line under the "unknown
# persona" sentinel, not folded into the ledger-unreadable bucket that is
# reserved for JSON that failed to parse at all.
printf '{"kind":"implement"}\n' >> "$LKML_MAILBOX_ROOT/cost-malformed/runs.jsonl"

OUT="$("$status" cost-malformed 2>/dev/null)"
contains "cost-malformed: runs launched is 3" "$OUT" "Runs launched: 3"
# Only the non-JSON line is unreadable; the persona-less-but-valid line
# has no run_dir either, so it lands in "no summary" instead.
contains "cost-malformed: only the unparseable line is unreadable" "$OUT" \
    "Runs launched: 3 (1 no summary, 1 unreadable)"
not_contains "cost-malformed: no longer described as missing summaries" "$OUT" \
    "with no summary.json yet"
contains "cost-malformed: the readable run's cost is unaffected" "$OUT" "clean          \$4.000000"
contains "cost-malformed: aggregate only includes the readable run" "$OUT" "Total cost so far: \$4.000000"
# The two lines share the "unknown persona" sentinel and must collapse
# into ONE row, not word-split into two by a persona name that itself
# contains a space.
contains "cost-malformed: both lines collapse into one row" "$OUT" \
    "unknown persona \$0.000000 (1 no summary, 1 unreadable)"
# The unreadable source here is the ledger line itself, not any
# summary.json (there is none to blame -- neither line names a readable
# run_dir), so the banner must say so instead of pointing at summary.json.
contains "cost-malformed: banner blames the ledger line, not summary.json" "$OUT" \
    "(some runs.jsonl lines could not be parsed and are counted as unreadable)"
not_contains "cost-malformed: banner does not blame summary.json" "$OUT" \
    "some summary.json files could not be parsed"

printf '\n== cost-personaless: valid JSON missing only persona, with a readable run_dir ==\n'
init_series cost-personaless
mkdir -p "$work/cpl-run"
printf '{"total_cost_usd": 6.0}' > "$work/cpl-run/summary.json"
printf '{"run_dir":"%s","kind":"review"}\n' "$work/cpl-run" \
    >> "$LKML_MAILBOX_ROOT/cost-personaless/runs.jsonl"

OUT="$("$status" cost-personaless 2>/dev/null)"
contains "cost-personaless: runs launched is 1" "$OUT" "Runs launched: 1"
not_contains "cost-personaless: not counted as unreadable" "$OUT" "unreadable"
# A missing persona must not shadow a readable run_dir: the cost sitting
# on disk is real and must be attributed and summed, matching
# scripts/lkml-fleet-status.sh's print_cost_per_agent() on the identical
# shape (an empty agent falls back to a sentinel and keeps reading).
contains "cost-personaless: the cost is read under the sentinel persona" "$OUT" \
    "unknown persona \$6.000000"
contains "cost-personaless: the cost is summed into the total" "$OUT" \
    "Total cost so far: \$6.000000"

printf '\n== cost-cluster: a cluster seat line has a persona but no run_dir ==\n'
init_series cost-cluster
mkdir -p "$work/ccl-local"
printf '{"total_cost_usd": 1.0}\n' > "$work/ccl-local/summary.json"
write_run cost-cluster "$work/ccl-local" local
# scripts/lkml-round.sh writes exactly this shape for every --k8s seat:
# {persona, branch, kind, cluster:true} -- deliberately no run_dir, since
# a cluster run's cost is currently unknown, not free. It must be
# attributed to its real persona as "no summary" (pending/unknown, like
# a local in-flight run), never thrown away as an unreadable ledger line.
printf '{"persona":"cluster-seat","branch":"b","kind":"review","cluster":true}\n' \
    >> "$LKML_MAILBOX_ROOT/cost-cluster/runs.jsonl"

OUT="$("$status" cost-cluster 2>/dev/null)"
contains "cost-cluster: runs launched is 2" "$OUT" "Runs launched: 2"
contains "cost-cluster: the cluster line counts as no summary, not unreadable" "$OUT" \
    "Runs launched: 2 (1 no summary)"
not_contains "cost-cluster: the cluster seat is never folded into unknown persona" "$OUT" "unknown persona"
contains "cost-cluster: the cluster seat keeps its real persona name" "$OUT" \
    "cluster-seat   \$0.000000 (1 no summary)"
contains "cost-cluster: the local run's cost is unaffected" "$OUT" "local          \$1.000000"

printf '\n== cost-pyabsent: a missing python3 degrades to a named state ==\n'
init_series cost-pyabsent
mkdir -p "$work/cp-withcost"
printf '{"total_cost_usd": 3.0}' > "$work/cp-withcost/summary.json"
write_run cost-pyabsent "$work/cp-withcost" withcost
write_run cost-pyabsent "$work/cp-nosummary" nosummary

no_python="$work/no-python-bin"
build_stub_path "$no_python"
OUT="$(PATH="$no_python" "$status" cost-pyabsent 2>/dev/null)"; RC=$?
check "cost-pyabsent: exits 0 without python3 on PATH" "0" "$RC"
# Without python3, a run that HAS a summary.json can no longer be
# classified at all -- it is unreadable, not a real cost. python3 is
# degraded into a named state here, never a hard requirement (the
# script does not abort, unlike its jq check).
contains "cost-pyabsent: withcost is unreadable without python3" "$OUT" \
    "withcost       \$0.000000 (1 unreadable)"
not_contains "cost-pyabsent: withcost is never claimed to be \$3" "$OUT" "\$3.000000"
# A missing summary.json is decided before python3 is ever consulted, so
# this state is unaffected by python3's absence, in both commits.
contains "cost-pyabsent: runs launched names both states" "$OUT" \
    "Runs launched: 2 (1 no summary, 1 unreadable)"
contains "cost-pyabsent: the missing summary is unaffected by python3, still" "$OUT" \
    "nosummary      \$0.000000 (1 no summary)"
contains "cost-pyabsent: python3 is named on screen" "$OUT" "python3 not found"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
