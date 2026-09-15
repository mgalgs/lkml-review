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
| `lkml-round.sh` (fan-out one sandboxed run per persona + harvest) | folded into `fork-sandbox postmaster`'s spawn-on-delivery routing — no separate "launch a round" script exists or is needed; a kickoff mail's `To:`/`Cc:` IS the fan-out. This also drops the old CI-first ordering guarantee (run CI before any reviewer reasons about the code, so the numbers are already on the thread) — see `fleet/personas/ci.md`'s `TODO(fleet)` comment for the open gap, and `docs/ci-first-ordering.md` for the design that closes it without re-growing a scheduler (designed, not yet built) |
| `lkml-revise.sh` (launch author to answer review + post next version) | partially folded into postmaster wake routing (the author is just another fleet seat that wakes on delivery like any reviewer); "posting the next version" as a first-class action has no fleet equivalent yet — see `fleet/personas/author.md`'s `TODO(fleet)` comment |
| `lkml-cover.sh` (author writes + posts a cover letter for existing patches) | folded into `scripts/lkml-fleet-kickoff.sh` + `fleet/kickoffs/*.md` templates |
| `lkml-series.sh` (reconstruct a merged range into thematic reviewable commits) | no replacement; local git reconstruction logic, unrelated to transport, out of this round's scope entirely |
| `lkml-status.sh` (one-screen version/tally/open-threads/cost summary) | **no fleet equivalent** — it reports the state/result of a single sandboxed run (harness, model, branch, exit code, cost for one `fork-sandbox run` invocation), not mail-thread state. `fleet roster`/`fleet check` are about the seat roster, not thread/version state either. There is genuinely no fork-sandbox verb today that reproduces "where does this series stand across all its versions and threads" — this is a real gap, not an oversight. |
| `lkml-summarize.sh` (two-tier extraction/synthesis results doc, written to a file outside the thread) | no replacement; the `secretary` persona is the closest analogue but it posts in-thread, this script's file-writing role has no fleet equivalent yet |
| `lkml-render.py` (HTML archive + `--text` agent view) | `fork-sandbox-mail-render.py` — full replacement. It has both a default HTML-archive mode (single self-contained file, inline CSS, light+dark, html-escaped) matching the old script's default output, and `--text`, the agent view the postmaster's own wake handoff uses. No gap here. |
| `lkml-forklift.sh` (fold a reviewed version onto a real branch) | no replacement; local git operation, unrelated to transport, not in scope |
| `lkml-seats-parse.py` + `lkml-seats-resolve` (old seats.yaml plumbing) | `fork-sandbox fleet` (fleet.yaml + `fleet resolve`/`fleet check`/`fleet expand`) — direct conceptual replacement |

`scripts/lkml-fleet-kickoff.sh` is new, not a replacement for a single
old script — it doesn't appear on the left above. It's closest in
spirit to folding `lkml-cover.sh`'s "compose a kickoff" role onto the
new transport, already captured in that row. This table is about
old→new mappings for scripts being retired; the new dogfood harness
itself is described in `README.md`, not here.
