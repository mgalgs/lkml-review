# lkml-review

Review a patch series the way the Linux kernel mailing list does.

A cover letter and a `git format-patch` set are posted to a shared mailbox
as v1. A panel of AI-persona reviewers — always including a core reviewer
holding the highest bar — read it and reply in threads, each from its own
sandboxed run. An author persona posts v2 with a changelog answering the
review. Repeat until the right reviewers have signed off and no NAK
stands.

The point is not "more review." It is **independent, adversarial review
with an iterated record**: several voices that did not talk to each other,
and a durable trail of what each asked for, whether the author addressed
it or pushed back, and why the code changed.

Use it for a change substantial enough to want that. For a small diff you
can read yourself in one pass, this is a great deal of machinery to get an
opinion you already have.

## Relationship to fork-sandbox

Every reviewer and every revision is a sandboxed run launched through
[fork-sandbox](https://github.com/mgalgs/fork-sandbox). **fork-sandbox is
a required dependency** — install it first; this repo is built entirely
out of its primitives and calls it by its public interface.

lkml-review used to live inside fork-sandbox as a worked example of
higher-order tooling built on it, and grew to about a quarter of that
repo while nominally being an illustration. It was moved out so the
boundary is real: when lkml needs a capability fork-sandbox does not
expose, that now surfaces as a feature request rather than being quietly
solved by editing a sibling script.

**Pre-split history lives in fork-sandbox**, which remains public. This
repo starts from a fresh initial commit rather than a filtered history —
rewriting would have had to split commits that bundled lkml with non-lkml
work, producing messages describing changes no longer in the tree, and a
misleading history is worse than an honest seam. `git log` in
fork-sandbox is the record before the split.

### Fleet transport

fork-sandbox has since grown a
generic agent-mail subsystem — `fork-sandbox mail` / `fleet` /
`postmaster` — covering the mailbox store, seat resolution, fan-out,
spawn-on-delivery wakes, and rendering that this repo's own
`scripts/lkml-*` transport (described below, still the shipping path)
used to carry alone. The plan is for that transport to move onto
agent-mail, at which point this repo becomes personas, kickoff-email
templates, and a thin kickoff harness — not a transport of its own.

That shape exists today, not yet wired into the shipping path:
fleet-form personas under `fleet/personas/`,
kickoff-mail templates under `fleet/kickoffs/`, and a dogfood harness,
`scripts/lkml-fleet-kickoff.sh`, that formats a patch series and
composes a kickoff mail for `fork-sandbox mail send`. See
`docs/RETIRED.md` for how each old script below maps onto the new
transport, and where a gap still has no replacement.

## Install

```bash
git clone https://github.com/mgalgs/lkml-review ~/src/lkml-review
cd ~/src/lkml-review
./install.sh
./install.sh --check      # names anything still missing; never gates
```

`install.sh` symlinks the porcelain onto `~/.claude/scripts` and the
`lkml-mode` skill into each agent's skill directory. Both repos install
onto the same PATH, and invocation names are unchanged from when lkml
lived in fork-sandbox — `lkml-round.sh` is still `lkml-round.sh`.

## Configure

Two files, in `~/.config/lkml/`:

| File | What it holds |
|---|---|
| `seats.yaml` | the reviewer panel — which personas sit, on which harness and model |
| `summarize.env` | tuning for the summarize leg, including its input-size cap |

Override either per invocation with `LKML_SEATS_FILE` or
`LKML_SUMMARIZE_ENV_FILE`.

There is **no fallback to any other location, deliberately.** A missing
file fails at launch and names the path it wanted, rather than silently
reading a stale copy from somewhere else. If you are upgrading from the
in-fork-sandbox version, move your two files — the old paths are not
consulted.

## Use

Typically through the skill, from an orchestrating agent session:

```
/lkml-mode <series-slug> <branch>
```

`<series-slug>` is a short kebab-case name for the mailbox; `<branch>` is
the branch posted as v1, formatted against its merge-base.

The orchestrating session schedules; it does not read. It sees the cover
letter and the thread tree and decides who replies to what next. Reading
every message body defeats the arrangement — the mailbox exists so that
scheduling and reading are different jobs held by different sessions.

## The scripts

| Script | Role |
|---|---|
| `lkml-mailbox.sh` | the message store: `init`, `post`, `tree`, `cover`, `show`, `open`, `tally` |
| `lkml-round.sh` | runs one round of the panel — a sandboxed run per seat |
| `lkml-revise.sh` | the author leg: produces the next version answering review |
| `lkml-cover.sh` | drafts the cover letter |
| `lkml-series.sh` | series-level operations across versions |
| `lkml-status.sh` | the one-screen summary |
| `lkml-summarize.sh` | per-version results summary |
| `lkml-render.py` | single-file HTML archive; `--text` for the agent/grep view |
| `lkml-forklift.sh` | moves a series between repos |
| `lkml-seats-parse.py`, `lkml-seats-resolve` | plumbing: read and resolve `seats.yaml` |
| `lkml-fleet-kickoff.sh` | Dogfood harness: formats a series and composes a kickoff mail for the fleet transport above; prints the `fork-sandbox mail send` command, or runs it with `--send` |

## Converging

A series is converged when **every seated reviewer holds a positive
non-blocking verdict** and no NAK stands.

That rule is stricter than it first looks, and the strictness is the
point. A check that only counts blocking verdicts cannot tell "four seats
went quiet" from "four seats agreed" — and those are opposite states. A
reviewer that fell over, ran out of context, or never ingested the thread
produces silence, and silence must never read as assent. Demand a
positive signal per seat.

## Tests

```bash
bash tests/lkml-round-test.sh      # each suite is standalone
```

Every suite prints `N passed, M failed`. Run them on the host: a suite
that passes inside a sandbox proves only the stubbed contract.
