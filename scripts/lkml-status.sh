#!/usr/bin/env bash
# lkml-status.sh — One screen: where an lkml-mode series stands
#
# Usage: lkml-status.sh <series>
#
# Prints: the current (highest) version and how many patches it has, the
# tally for that version, every open thread, the deepest thread in the
# whole series, and the running cost -- summed from summary.json of every
# run lkml-round.sh and lkml-revise.sh have launched for this series,
# recorded in a small ledger beside the mailbox
# ($LKML_MAILBOX_ROOT/<series>/runs.jsonl, default
# /var/tmp/claude-scratch/lkml/<series>/runs.jsonl) rather than as an
# 8th lkml-mailbox.sh verb. A run's cost is classified as one of four
# states rather than folded into a bare $0: "no summary" (the file does
# not exist yet -- in flight, or cleaned up), "no cost" (the file exists
# but has no usable numeric cost field), "invalid" (the field is a
# number but cannot be a cost: negative, NaN, infinite, or unrepresentably
# large), or "unreadable" (the file, or its ledger line, could not be
# read at all). None of the three unusable states is ever summed as if
# it were a real zero.
#
# Each cost is parsed to 10 decimal places before it is summed, and the
# running total carries that same precision through every addition;
# only the screen display rounds to 6 places, at the print site. A
# real, nonzero cost below 5e-11 still formats as an exact zero before
# it ever reaches the accumulator, and is summed as one -- no number of
# such runs can ever add up to a visible total. Above that floor,
# though, the accumulator's extra digits mean an aggregate that clears
# 5e-7 is shown in full even when every individual addend, alone, would
# round to a displayed $0.000000. See scripts/lkml-fleet-status.sh's
# --help for the identical wording; the two must not drift.

set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
mailbox="$script_dir/lkml-mailbox.sh"
LKML_ROOT="${LKML_MAILBOX_ROOT:-/var/tmp/claude-scratch/lkml}"

usage() {
    sed -n '2,/^set -uo/{ /^#/s/^# \?//p }' "$0"
}

case "${1-}" in
    -h|--help) usage; exit 0 ;;
esac

series="${1:?Usage: lkml-status.sh <series>}"
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found on PATH." >&2; exit 1; }

tree_out="$("$mailbox" tree "$series" 2>&1)" || {
    echo "Error: series '$series' does not exist." >&2
    echo "$tree_out" >&2
    exit 1
}

version="$(printf '%s\n' "$tree_out" | sed -n 's/^=== v\([0-9]\+\) ===$/\1/p' | sort -n | tail -n1)"

tally_out="$("$mailbox" tally "$series" --version "$version" 2>/dev/null)"
# tally prints one "Patch N: ..." line per patch, N starting at 0 for the
# cover -- counting them (and subtracting the cover) beats grepping the
# tree's subjects, which a reply's default "Re: [PATCH ...]" Subject would
# double-count.
n_patches="$(printf '%s\n' "$tally_out" | grep -c '^Patch [0-9]\+:')"
(( n_patches > 0 )) && n_patches=$(( n_patches - 1 ))

# Indentation in `tree` is exactly 2 spaces per depth level (lkml_tree_print
# in lkml-mailbox.sh), so the deepest indent, halved, is the deepest depth.
deepest="$(printf '%s\n' "$tree_out" | sed -n 's/^\( *\)[0-9a-f]\{7\} .*/\1/p' | awk '{print length($0)/2}' | sort -n | tail -n1)"
[[ -n "$deepest" ]] || deepest=0

printf 'Series: %s\n' "$series"
printf 'Current version: v%s (%s patches)\n' "$version" "$n_patches"
printf 'Deepest thread: depth %s (of 30 max)\n' "$deepest"

printf '\n== Tally, v%s ==\n' "$version"
printf '%s\n' "$tally_out"

printf '\n== Open threads, v%s ==\n' "$version"
"$mailbox" open "$series" --version "$version"

# Prints " (X no summary, Y no cost, Z invalid, W unreadable)" for
# whichever counts are non-zero, or nothing if all four are zero.
# Mirrors scripts/lkml-fleet-status.sh's fs_cost_annotation() exactly --
# duplicated rather than shared, see the classifier comment below for why.
cost_annotation() {
    local missing="$1" no_cost="$2" invalid="$3" unreadable="$4" joined
    local parts=()
    (( missing > 0 )) && parts+=("$missing no summary")
    (( no_cost > 0 )) && parts+=("$no_cost no cost")
    (( invalid > 0 )) && parts+=("$invalid invalid")
    (( unreadable > 0 )) && parts+=("$unreadable unreadable")
    (( ${#parts[@]} == 0 )) && return 0
    printf -v joined '%s, ' "${parts[@]}"
    printf ' (%s)' "${joined%, }"
}

printf '\n== Cost ==\n'
ledger="$LKML_ROOT/$series/runs.jsonl"
if [[ ! -f "$ledger" ]]; then
    echo "(no runs recorded)"
    exit 0
fi

have_python=1
command -v python3 >/dev/null 2>&1 || have_python=0

total_runs=0
missing_summary=0
no_cost=0
invalid=0
unreadable=0
unreadable_ledger=0
total_cost="0"
declare -A RUN_COUNT=() MISSING_COUNT=() NO_COST_COUNT=() INVALID_COUNT=() UNREADABLE_COUNT=() COST_BY_PERSONA=()
parse_personas=()
parse_paths=()

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    total_runs=$(( total_runs + 1 ))
    # A line that is not even valid JSON cannot be attributed to
    # anything -- not a persona, not a run_dir -- so it is "unreadable"
    # before either field is ever looked at. That is different from a
    # line that parses fine but simply omits the persona field: such a
    # line still has a run_dir to classify by, matching how
    # scripts/lkml-fleet-status.sh's print_cost_per_agent() treats an
    # empty agent -- fall back to a sentinel name and keep going, rather
    # than discarding real attribution and desyncing the two screens'
    # answers for the same run. See the classifier comment below for why
    # that parity matters.
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
        persona='unknown persona'
        RUN_COUNT[$persona]=$(( ${RUN_COUNT[$persona]:-0} + 1 ))
        unreadable=$(( unreadable + 1 ))
        unreadable_ledger=$(( unreadable_ledger + 1 ))
        UNREADABLE_COUNT[$persona]=$(( ${UNREADABLE_COUNT[$persona]:-0} + 1 ))
        continue
    fi
    run_dir="$(printf '%s' "$line" | jq -r '.run_dir // empty' 2>/dev/null)"
    persona="$(printf '%s' "$line" | jq -r '.persona // empty' 2>/dev/null)"
    [[ -n "$persona" ]] || persona='unknown persona'
    RUN_COUNT[$persona]=$(( ${RUN_COUNT[$persona]:-0} + 1 ))
    if [[ -z "$run_dir" || ! -f "$run_dir/summary.json" ]]; then
        missing_summary=$(( missing_summary + 1 ))
        MISSING_COUNT[$persona]=$(( ${MISSING_COUNT[$persona]:-0} + 1 ))
        continue
    fi
    if (( ! have_python )); then
        unreadable=$(( unreadable + 1 ))
        UNREADABLE_COUNT[$persona]=$(( ${UNREADABLE_COUNT[$persona]:-0} + 1 ))
        continue
    fi
    parse_personas+=("$persona")
    parse_paths+=("$run_dir/summary.json")
done < "$ledger"

# One interpreter for the whole ledger, not one per summary file -- see
# scripts/lkml-fleet-status.sh's print_cost_per_agent() for why (a
# per-file fork that's invisible at ten runs comes to dominate at
# hundreds). This classifier -- and the trust gate right below it --
# must classify identically to that script's: during the transport
# migration an operator reads both screens against the same runs, and
# two different answers for one run is the failure this duplication
# exists to prevent. Duplicated rather than shared: this script is on
# the retirement map in docs/RETIRED.md with that one named as its
# replacement, and a shared library would have to be unpicked at
# retirement. Keep any change to the taxonomy in both places.
if (( ${#parse_paths[@]} > 0 )); then
    results="$(python3 -c '
import json, math, sys

for path in sys.argv[1:]:
    try:
        data = json.load(open(path))
    except Exception:
        print("UNREADABLE")
        continue
    result = "NOCOST"
    try:
        for key in ("total_cost_usd", "cost_usd"):
            value = data.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                continue
            try:
                finite = math.isfinite(value)
            except OverflowError:
                finite = False
            if not finite or value < 0:
                result = "INVALID"
            else:
                # .10f, not the bare "f" (== .6f): see the identical
                # parser in lkml-fleet-status.sh for why -- this
                # classifier must match it exactly, per the comment
                # above.
                if value == 0:
                    value = 0.0
                result = format(value, ".10f")
            break
    except Exception:
        pass
    print(result)
' "${parse_paths[@]}" 2>/dev/null)" && py_rc=0 || py_rc=$?
    result_lines=()
    if [[ -n "$results" ]]; then
        while IFS= read -r res; do
            result_lines+=("$res")
        done <<< "$results"
    fi
    if (( py_rc != 0 )) || (( ${#result_lines[@]} != ${#parse_paths[@]} )); then
        for persona in "${parse_personas[@]}"; do
            unreadable=$(( unreadable + 1 ))
            UNREADABLE_COUNT[$persona]=$(( ${UNREADABLE_COUNT[$persona]:-0} + 1 ))
        done
    else
        for i in "${!result_lines[@]}"; do
            res="${result_lines[$i]}"
            persona="${parse_personas[$i]}"
            if [[ "$res" == "UNREADABLE" ]]; then
                unreadable=$(( unreadable + 1 ))
                UNREADABLE_COUNT[$persona]=$(( ${UNREADABLE_COUNT[$persona]:-0} + 1 ))
            elif [[ "$res" == "INVALID" ]]; then
                invalid=$(( invalid + 1 ))
                INVALID_COUNT[$persona]=$(( ${INVALID_COUNT[$persona]:-0} + 1 ))
            elif [[ "$res" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                prev="${COST_BY_PERSONA[$persona]:-0}"
                # .10f here too, carrying the parser's precision across
                # every addition -- re-rounding to 6 places per addition
                # would erase a sub-5e-7 addend on arrival, the same bug
                # lkml-fleet-status.sh was fixed for. The 6-decimal
                # convention is applied once, at the print site below,
                # not here.
                COST_BY_PERSONA[$persona]="$(awk -v a="$prev" -v b="$res" 'BEGIN { printf "%.10f", a + b }')"
                total_cost="$(awk -v a="$total_cost" -v b="$res" 'BEGIN { printf "%.10f", a + b }')"
            else
                no_cost=$(( no_cost + 1 ))
                NO_COST_COUNT[$persona]=$(( ${NO_COST_COUNT[$persona]:-0} + 1 ))
            fi
        done
    fi
fi

# The header at line 18 names two distinct sources of "unreadable": the
# ledger line itself (couldn't be attributed to a persona) and a
# summary.json a persona's line pointed at (couldn't be parsed as cost).
# Blaming summary.json for both would send an operator to look for a
# file that, in the ledger-line case, was never named in the first place.
if (( unreadable_ledger > 0 )); then
    echo '(some runs.jsonl lines could not be parsed and are counted as unreadable)'
fi
if (( unreadable - unreadable_ledger > 0 )); then
    if (( ! have_python )); then
        echo '(python3 not found: those summaries could not be parsed and are counted as unreadable)'
    else
        echo '(some summary.json files could not be parsed and are counted as unreadable)'
    fi
fi
printf 'Runs launched: %s%s\n' "$total_runs" "$(cost_annotation "$missing_summary" "$no_cost" "$invalid" "$unreadable")"
# The accumulator carries .10f precision; round to the screen's 6-decimal
# convention here, at the print site, so a real sub-5e-7 sum is visible
# without changing the format every existing fixture pins.
printf 'Total cost so far: $%s\n' "$(awk -v c="$total_cost" 'BEGIN { printf "%.6f", c }')"
# A `for persona in $(...)` here would word-split "unknown persona" (the
# sentinel for a malformed ledger line, itself containing a space) into
# two bogus rows -- read whole lines instead.
while IFS= read -r persona; do
    [[ -n "$persona" ]] || continue
    display_cost="$(awk -v c="${COST_BY_PERSONA[$persona]:-0}" 'BEGIN { printf "%.6f", c }')"
    printf '  %-14s $%s%s\n' "$persona" "$display_cost" \
        "$(cost_annotation "${MISSING_COUNT[$persona]:-0}" "${NO_COST_COUNT[$persona]:-0}" "${INVALID_COUNT[$persona]:-0}" "${UNREADABLE_COUNT[$persona]:-0}")"
done < <(printf '%s\n' "${!RUN_COUNT[@]}" | sort)
