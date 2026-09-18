# Fold cost accumulation into the batched Python classifier

Answers the `TODO(cost-accum)` in `tests/lkml-fleet-status-test.sh`.

## The gap

`lkml-fleet-status.sh` and `lkml-status.sh` classify each run's
`summary.json` with one batched `python3` invocation per screen (the v2
batching: one interpreter for the whole ledger — parsing the cost,
formatting it to `.10f`, and deciding which of the four states it falls
into), then shell back out to a **separate** `awk` invocation to add
each formatted value into the running total — one `awk` fork per costed
run record in `lkml-fleet-status.sh`, two in `lkml-status.sh` (the
per-persona and grand-total accumulators).

That split is why the accumulator's floor sits at 5e-11 per addend: the
value crosses a text boundary (`python3`'s `.10f` output, re-parsed by
`awk`) between being read and being summed, and anything the `.10f`
formatting rounds to `0.0000000000` is a real zero by the time `awk` ever
sees it. Folding accumulation into the same Python invocation that
already reads and classifies each run would sum at whatever precision
Python's own floats hold, not at a 10-decimal text round-trip, and would
remove the per-run-record `awk` forks entirely.

## Why it is not done yet

It is a bigger change than a display fix: the per-run classifier would
have to also carry state across runs (an accumulator per persona/agent
plus a grand total) instead of returning one independent verdict per
call, which changes its contract with both call sites. That is real
surgery on the hot path both screens share, not a follow-up to make
alongside a display-precision correction.

## What it would buy

- Removes the per-run-record `awk` forks — one in
  `lkml-fleet-status.sh`, two in `lkml-status.sh` (the per-persona and
  grand-total accumulators).
- Removes the 5e-11-per-addend floor documented in both scripts' `--help`
  text, letting `tests/lkml-fleet-status-test.sh`'s tiny-aggregate fixture
  use its originally-intended 10000-run form cheaply instead of the
  100-run stand-in it uses today.

The sites that go stale together when this lands, so the landing commit
takes them in one pass: this doc, the `TODO(cost-accum)` in
`tests/lkml-fleet-status-test.sh`, the accumulator legs in both scripts,
the floor sentences in both `--help` headers, and the cost-floor-pin
fixture comment in both `tests/lkml-status-test.sh` and
`tests/lkml-fleet-status-test.sh` (it describes the same awk-fork cost
class and 5e-11 floor as live facts, so it needs updating, not
deleting — the fixture still tests display precision after the fold).
Do not add a fixture asserting a cost below the 5e-11 floor: that floor
(a real sub-5e-11 cost never reaching the accumulator) is exactly what
this fold removes, so such a fixture's behavior would become
meaningless rather than merely stale.
