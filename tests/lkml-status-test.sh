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
# Today (commit 1), an absent field is silently treated as a real $0 cost
# via jq's `// 0`, not annotated as "no cost". Commit 2 changes this.
contains "cost-basic: absent field sums as 0, today, unannotated" "$OUT" "absent         \$0.000000"
contains "cost-basic: null field sums as 0, today, unannotated" "$OUT" "isnull         \$0.000000"
# jq's `//` treats `false` as absent too, so this also falls through to 0.
contains "cost-basic: false field sums as 0, today, unannotated" "$OUT" "isfalse        \$0.000000"
# `//` passes `true` through; `jq -r` prints the literal "true"; awk adds
# "true" as 0. Silently free, today.
contains "cost-basic: true field sums as 0, today, unannotated" "$OUT" "istrue         \$0.000000"
# A corrupt summary.json makes jq fail; `cost` is empty; awk adds "" as 0.
# No -e in this script, so nothing aborts.
contains "cost-basic: corrupt file sums as 0, today, unannotated" "$OUT" "corrupt        \$0.000000"
# A JSON string cost is accepted and summed as a real number, today.
contains "cost-basic: string cost is accepted and summed, today" "$OUT" "isstring       \$1.230000"
# A negative cost is summed as negative, unannotated, today.
contains "cost-basic: negative cost is summed as negative, today" "$OUT" "negative       \$-5.500000"
contains "cost-basic: fallback cost_usd is used and summed" "$OUT" "fallback       \$2.500000"
# Aggregate: -5.5 (negative) + 1.23 (isstring) + 2.5 (fallback) = -1.77.
contains "cost-basic: aggregate sums the unusable shapes in, today" "$OUT" "Total cost so far: \$-1.770000"

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

printf '\n== cost-huge: a magnitude no float can hold ==\n'
init_series cost-huge
mkdir -p "$work/ch-huge"
huge_digits="$(printf '1%.0s' $(seq 1 400))"
printf '{"total_cost_usd": %s}' "$huge_digits" > "$work/ch-huge/summary.json"
write_run cost-huge "$work/ch-huge" huge

OUT="$("$status" cost-huge 2>/dev/null)"
contains "cost-huge: runs launched is 1" "$OUT" "Runs launched: 1"
# Today, jq/awk overflow to +inf with no annotation and no abort -- this
# is the "silently free" case the brief calls out most sharply. Commit 2
# reclassifies this as invalid.
contains "cost-huge: an unrepresentable magnitude becomes +inf, today" "$OUT" "huge           \$+inf"
contains "cost-huge: the +inf poisons the aggregate, today" "$OUT" "Total cost so far: \$+inf"

printf '\n== cost-malformed: a ledger line that cannot be read ==\n'
init_series cost-malformed
mkdir -p "$work/cm-clean"
printf '{"total_cost_usd": 4.0}' > "$work/cm-clean/summary.json"
write_run cost-malformed "$work/cm-clean" clean
printf 'not a json line at all\n' >> "$LKML_MAILBOX_ROOT/cost-malformed/runs.jsonl"
printf '{"kind":"implement"}\n' >> "$LKML_MAILBOX_ROOT/cost-malformed/runs.jsonl"

OUT="$("$status" cost-malformed 2>/dev/null)"
contains "cost-malformed: runs launched is 3" "$OUT" "Runs launched: 3"
# Today, both malformed lines fall through jq's parse/lookup failure into
# empty run_dir/persona, which the missing-summary.json check silently
# treats the same as a run whose file was cleaned up -- not annotated as
# unreadable. Commit 2 gives a malformed ledger line its own state.
contains "cost-malformed: both malformed lines count as missing summary, today" "$OUT" \
    "Runs launched: 3 (2 with no summary.json yet -- in flight, or cleaned up)"
contains "cost-malformed: the readable run's cost is unaffected" "$OUT" "clean          \$4.000000"
contains "cost-malformed: aggregate only includes the readable run" "$OUT" "Total cost so far: \$4.000000"

printf '\n== cost-pyabsent: python3 is not required until commit 2 ==\n'
init_series cost-pyabsent
mkdir -p "$work/cp-withcost"
printf '{"total_cost_usd": 3.0}' > "$work/cp-withcost/summary.json"
write_run cost-pyabsent "$work/cp-withcost" withcost
write_run cost-pyabsent "$work/cp-nosummary" nosummary

no_python="$work/no-python-bin"
build_stub_path "$no_python"
OUT="$(PATH="$no_python" "$status" cost-pyabsent 2>/dev/null)"; RC=$?
check "cost-pyabsent: exits 0 without python3 on PATH" "0" "$RC"
# Today, the script never invokes python3 at all, so its absence changes
# nothing -- byte-identical to a run with a normal PATH. Commit 2 makes
# python3 load-bearing for classification (but not a hard requirement).
contains "cost-pyabsent: withcost is unaffected by a missing python3, today" "$OUT" "withcost       \$3.000000"
contains "cost-pyabsent: runs launched is 2 with one missing summary" "$OUT" \
    "Runs launched: 2 (1 with no summary.json yet -- in flight, or cleaned up)"
not_contains "cost-pyabsent: python3 is not named on screen, today" "$OUT" "python3"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
