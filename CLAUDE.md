# Working in this repository

## What this is, and what it depends on

`lkml-review` runs a patch series through a mailing-list-style review: a
cover letter and patches posted to a shared mailbox, a panel of AI-persona
reviewers replying in threads from sandboxed runs, and the author posting
v2, v3... with a changelog answering review.

It is a **consumer of `fork-sandbox`**, not a part of it. Every sandboxed
run it launches goes through `fork-sandbox.sh`'s public interface. That
dependency is one-directional and is meant to stay narrow: if something
here needs a capability `fork-sandbox` does not expose, the fix is to ask
`fork-sandbox` for it, **not** to reach into its internals.

That rule is the reason this repo exists separately. lkml grew up inside
`fork-sandbox` and had become 23% of it while nominally being an example.
With a repo boundary in the way, a gap surfaces as a feature request
instead of being quietly solved by editing a sibling script.

One known violation, inherited: `lkml-round.sh` calls `fork-sandbox-k8s.sh`
directly — `submit`, `wait --probe`, `collect` — rather than going through
the front door, with its own timeout accounting and per-seat outbox
handling. It does that because `fork-sandbox.sh --k8s` blocks while the
local path does not, so a fan-out over the front door would serialize.
The fix belongs upstream. Do not paper over it here, and do not add a
second one.

## This repo is public and general-purpose

Nothing environment-specific goes in the repo — not in code, docs, tests,
fixtures, or commit messages. No private hostnames or internal DNS names,
no real internal IP addresses, no cluster or kubectl context names, no
employer, product, or internal project names, and no personal filesystem
paths beyond generic `$HOME`-style examples. Commit messages are published
too; write them like the code.

Machine- and site-specific values live OUTSIDE the repo, in
`~/.config/lkml/`, and are read at run time. Persona files that encode a
particular reviewer's taste can also live outside the repo and be pinned
per seat.

Test fixtures use invented names and documentation ranges — `example.com`,
RFC 5737 addresses like `192.0.2.0/24`, and invented
`svc-a.example-ns.svc.cluster.local` style names. Never a real address,
even a private one, and never a real hostname.

## Configuration

Read from `~/.config/lkml/`:

| File | What it holds |
|---|---|
| `seats.yaml` | the reviewer panel: which personas sit, on which harness and model |
| `summarize.env` | tuning for the summarize leg, including its input-size cap |
| `fleet.yaml` (optional) | fleet lists, triage settings, and site-specific fleet overrides |

Overridable per invocation with `LKML_SEATS_FILE` and
`LKML_SUMMARIZE_ENV_FILE`; the optional fleet file is overridable with
`LKML_FLEET_FILE`.

**There is deliberately no fallback to any other location.** A missing
file fails at launch, naming the path it wanted. It never silently reads
a stale copy from somewhere else. If you are tempted to add a
compatibility path, re-read this paragraph: the loud failure is the
feature.

## Conventions

- bash, `set -euo pipefail` unless a script documents why not; run
  `shellcheck` on every changed `.sh` and fix what it reports.
- Python scripts pass a syntax check.
- Every behavior change lands WITH its tests in the same commit.
- Scripts are self-documenting: usage and rationale live in the header
  comment, and `--help` prints it.
- Only porcelain goes on PATH. `install.sh` carries the porcelain and
  plumbing lists, and fails closed when a script in `scripts/` appears in
  neither — that check is what stops a new script from silently never
  being installed.

## Testing

Every suite in `tests/` is standalone: `bash tests/<name>-test.sh`, and it
prints `N passed, M failed`.

**The host is the arbiter.** A suite that passes inside a sandbox proves
only the stubbed contract. Re-run on the host before believing a result —
operator git config alone has broken suites that passed in a clone.

## A hazard worth knowing before you trust a panel

The failure mode this tooling keeps producing is not a crash, it is a
**false green**: a report of success over work that never ran, or ran
degraded. Seats that exit 0 having written nothing. A renderer that
declares a series converged while reviewers hold unaddressed objections.
A suite that passes because its fixtures encode the same misunderstanding
the code does.

Two things follow, and both are load-bearing:

- **Convergence requires a positive signal per seat.** Every seated
  reviewer must hold an actual non-blocking verdict. A check that only
  counts blocking verdicts reads "four seats went quiet" identically to
  "four seats agreed" — and those are opposite states.
- **A test suite written by whoever wrote the code cannot catch a misread
  of an external format.** Convergence logic wants a corpus of real
  mailbox states with hand-checked expected verdicts, not
  self-consistent fixtures.
