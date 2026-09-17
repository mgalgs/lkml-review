# Retirement map: old transport → fleet transport

This is a mapping, not an announcement. **None of the old `scripts/lkml-*`
scripts are being deleted this round** — they are still the shipping
transport, described in `README.md`'s "The scripts" table. This table
exists so a later, operator-attended round has a single place to check
"what replaces this?" before removing anything, and so the gaps that
still have no fleet equivalent are written down instead of discovered
by surprise.

| Old script | Fleet replacement |
|---|---|
| `lkml-mailbox.sh` (message store: init/post/tree/cover/show/open/tally) | `fork-sandbox mail` (send/reply/show/tree/list/inbox) — the store itself |
| `lkml-round.sh` (fan-out one sandboxed run per persona + harvest) | folded into `fork-sandbox postmaster`'s spawn-on-delivery routing — no separate "launch a round" script exists or is needed; a kickoff mail's `To:`/`Cc:` IS the fan-out. The old CI-first ordering guarantee (run CI before any reviewer reasons about the code, so the numbers are already on the thread) is kept, as an address graph rather than a scheduler: `lkml-fleet-kickoff.sh --ci-first <ci-addr>` addresses the kickoff to the `ci` seat alone, and that seat's reply addresses the panel. See `docs/ci-first-ordering.md` for why, and note two things it insists on — the extra hop is compensated on the kickoff (`--hops` defaults to 9 in that mode, because hops cannot be raised after a thread starts), and the shape is gated on the `ci` seat actually existing, since a kickoff addressed to a dropped seat wakes nobody and the panel silently never starts |
| `lkml-revise.sh` (launch author to answer review + post next version) | partially folded into postmaster wake routing (the author is just another fleet seat that wakes on delivery like any reviewer); "posting the next version" as a first-class action has no fleet equivalent yet — see `fleet/personas/author.md`'s `TODO(fleet)` comment |
| `lkml-cover.sh` (author writes + posts a cover letter for existing patches) | folded into `scripts/lkml-fleet-kickoff.sh` + `fleet/kickoffs/*.md` templates |
| `lkml-series.sh` (reconstruct a merged range into thematic reviewable commits) | no replacement; local git reconstruction logic, unrelated to transport, out of this round's scope entirely |
| `lkml-status.sh` (one-screen version/tally/open-threads/cost summary) | `scripts/lkml-fleet-status.sh` — full replacement, and like `lkml-fleet-kickoff.sh` it lives in this repo rather than upstream. No *fork-sandbox* verb answers "where does this series stand": `fork-sandbox status` reports one sandboxed run (harness, model, branch, exit code, cost for a single `fork-sandbox run`), and `fleet roster`/`fleet check` report the seat roster. That gap is real and is why the screen is here. It takes a thread id, which on this transport is what a series is — a kickoff starts one thread and every version replies into it, so the old model's several-threads-per-series does not arise; `--list` is the across-threads view. It reports seats with their latest verdicts, versions, the hop and spawn budgets, cost per agent under a four-state taxonomy, and who was addressed but never replied. It deliberately reports state and never judges convergence: on this transport every seat reasons from a stale snapshot of the thread, so only a reader of the store at read time has the whole picture. |
| `lkml-summarize.sh` (two-tier extraction/synthesis results doc, written to a file outside the thread) | no replacement; the `secretary` persona is the closest analogue but it posts in-thread, this script's file-writing role has no fleet equivalent yet |
| `lkml-render.py` (HTML archive + `--text` agent view) | `fork-sandbox-mail-render.py` reaches the same two output modes (a self-contained HTML archive and a `--text` agent view) for a generic thread, but it is a thread archive, not a series renderer: it has no version-boundary handling, verdict tally, reviewer matrix, NAK banner, results-card model, or convergence chip. `lkml-render.py` gained fleet-store support (parsing `threads/<tid>/`, version-boundary detection, and the rest of that machinery) precisely to fill that gap, the same way `lkml-fleet-status.sh` fills the gap in the `lkml-status.sh` row above. That gap is real; this row is not a full replacement until it closes. |
| `lkml-forklift.sh` (fold a reviewed version onto a real branch) | no replacement; local git operation, unrelated to transport, not in scope |
| `lkml-seats-parse.py` + `lkml-seats-resolve` (old seats.yaml plumbing) | `lkml-fleet.sh fleet` reaches `fork-sandbox fleet` against lkml's own persona registry. The panel resolves from persona frontmatter and `fleet expand @all` needs no `fleet.yaml`; an optional `~/.config/lkml/fleet.yaml` (or `LKML_FLEET_FILE`) can add `@panel`, `triage:`, and site-specific harness/model overrides, while `fleet roster` and `fleet check` require it. |

`scripts/lkml-fleet-kickoff.sh` is new, not a replacement for a single
old script — it doesn't appear on the left above. It's closest in
spirit to folding `lkml-cover.sh`'s "compose a kickoff" role onto the
new transport, already captured in that row. This table is about
old→new mappings for scripts being retired; the new dogfood harness
itself is described in `README.md`, not here.
