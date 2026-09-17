# Fold cost accumulation into the per-run Python classifier

Answers the `TODO(cost-accum)` in `tests/lkml-fleet-status-test.sh`.

## The gap

`lkml-fleet-status.sh` and `lkml-status.sh` classify each run's
`summary.json` with a per-run `python3` invocation (parsing the cost,
formatting it to `.10f`, and deciding which of the four states it falls
into), then shell back out to a **separate** `awk` invocation to add that
formatted value into the running total — one `awk` fork per run record,
on top of the one `python3` fork already spent classifying it.

That split is why the accumulator's floor sits at 5e-11 per addend: the
value crosses a text boundary (`python3`'s `.10f` output, re-parsed by
`awk`) between being read and being summed, and anything the `.10f`
formatting rounds to `0.0000000000` is a real zero by the time `awk` ever
sees it. Folding accumulation into the same Python invocation that
already reads and classifies each run would sum at whatever precision
Python's own floats hold, not at a 10-decimal text round-trip, and would
remove the per-run `awk` fork entirely.

## Why it is not done yet

It is a bigger change than a display fix: the per-run classifier would
have to also carry state across runs (an accumulator per persona/agent
plus a grand total) instead of returning one independent verdict per
call, which changes its contract with both call sites. That is real
surgery on the hot path both screens share, not a follow-up to make
alongside a display-precision correction.

## What it would buy

- Removes one `awk` fork per run record in both screens' cost tally.
- Removes the 5e-11-per-addend floor documented in both scripts' `--help`
  text, letting `tests/lkml-fleet-status-test.sh`'s tiny-aggregate fixture
  use its originally-intended 10000-run form cheaply instead of the
  100-run stand-in it uses today.
