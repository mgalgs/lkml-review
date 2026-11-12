# Replay one panel seat

`scripts/lkml-replay.sh` asks the local fork-sandbox postmaster to replay one
seat on a mail thread frozen at a chosen message. It uses the postmaster's
handoff writer and renderer, so the seat sees the same prompt construction as
a live wake. The script substitutes only the persona and prompt files from an
lkml-review commit. It does not compare or score replies.

Export a thread with `fork-sandbox mail export <thread-id> --json`, then run:

```sh
scripts/lkml-replay.sh --export thread.json --cut 3 --seat core \
    --personas-ref <lkml-review-commit> --project <local-project-path> \
    --fork-sandbox <deployed-fork-sandbox-checkout> \
    --model <live-model> --thinking <live-thinking>
```

`--cut` is the arrival sequence of the message that should wake the seat.
Only messages through that sequence are seeded. The cut must address the seat
directly in To or Cc. The last stdout line is the harvested `.msg` reply path;
exit 0 means exactly one reply from that seat was harvested. The work directory
is retained and contains the local mail store, postmaster handoff and thread
snapshot, run directory, postmaster log, and `replay.json`. Use `--work-dir`
to choose it, or let the script make a fresh directory under
`/var/tmp/claude-scratch`. An explicit work directory must be empty and under
that scratch root, outside `forks/`, because fork-sandbox validates handoff
paths there. `--timeout` defaults to 3600 seconds, the wake's own default.

`--model` and `--thinking` are required. Pass the values the live fleet used;
fleet configuration can override persona frontmatter. The record stores those
values, the full persona commit, and the
fork-sandbox commit. A staged fork-sandbox copy without `.git` cannot reveal
its commit; set `FORK_SANDBOX_COMMIT` to the deployed full SHA in that case.
If it is unavailable, the record says `unknown`.

`--personas-overlay <dir>` copies that directory's `*.md` persona files over
the extracted ref files before the run. A same-name site file wins, and a
site-only name is added.
`replay.json` records the overlay directory, copied names, and SHA-256 hashes
of every persona and prompt file presented to the postmaster.

Exports contain attachment names and sizes, not bytes. Pass
`--attachments-dir` to supply them. Missing attachments stop the replay with
exit 2 and a name list. `--allow-missing-attachments` permits the run, prints
a warning, and records the missing names. Supplied files must match the
exported sizes.

The replay gives the postmaster only the selected persona as a runnable seat.
Other names on the cut resolve through fleet lists to that seat, so the
postmaster deduplicates them into one wake without rewriting the message or
flagging an unknown name. This also works for operator and external mail.
The last message through the cut with `X-Review-Target-Set` sets the frozen
review commit and its `X-Version`, as it does live; a seat's reply carries
`X-Review-Target` only to say what it reviewed, and never moves the target.
`replay.json` records the setting message's sequence as `review_target_seq`. If none carries a target, replay refuses unless
`--no-review-target` is passed. That flag reviews `--project` HEAD and records
`review_target: null` and `review_target_seq: null`.
The postmaster may put only the triggering
message in the handoff and put earlier messages in the mounted thread snapshot;
both are its live behavior.

`replay.json` also records `launcher`, `stopped_runs`, and `stop_failures`.
It records `handoff_path` and `handoff_sha256`, plus `thread_snapshot_path`
and `thread_snapshot_sha256`, for the files the postmaster wrote. A nonstandard
launcher produces a warning. On failure, replay stops every unfinished wake;
stop failures appear on stderr and in `stop_failures`.

## Differences from a live wake

- No grants are seeded, so preview and other granted environments are absent.
- The replay uses a local bwrap sandbox, not a pod.
- Live persona and prompt text depend on what was deployed when the wake spawned; pass the ref and overlay live at that time.
- A model alias such as `opus` resolves through the CLI version in the live image; pass a full model ID when known.
- Postmaster refreezes that move a target after a force push without a header cannot be reproduced.
- A live claude or codex seat resumes its own conversation from its earlier wakes on the thread; a replay starts the seat fresh, so read a result as what a fresh seat does at the cut.

The replay sets both `FORK_SANDBOX_MAIL_ROOT` and `FORK_SANDBOX_CONFIG_DIR`
under its work directory and never calls `--remote`. The local postmaster and
mail commands use those paths. The remote mail client runs only with the
explicit `--remote` verb; a caller's remote mail environment is cleared.

Run the synthetic integration suite with a fork-sandbox checkout:

```sh
tests/lkml-replay-test.sh /path/to/fork-sandbox
```

Without a checkout argument, the suite runs the refusal cases and prints a
SKIP line for postmaster-dependent checks. It replaces the model launcher
with a stub, while using the real postmaster, fleet resolver, mail store and
renderer.
