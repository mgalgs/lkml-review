# The gap monitor

`lkml-gap-monitor.py` watches pull requests the review panel has signed
off on and judges the feedback they draw afterwards.

## What it is for

A panel signs off on a pull request. Afterwards humans and other review
agents still leave feedback on it. Every real defect found after the
sign-off is a gap in the panel, and the gaps should surface by
themselves. A comment proves nothing, though: the commenter may be
wrong, and a short polite comment may be the most serious one. So each
piece of feedback is judged by a strong model in a checkout of the exact
tree the panel signed off on, and only the verdict counts.

The tool is incremental. A daily timer runs it; it finds sign-offs,
pulls the later feedback, judges what is new, appends the verdicts to a
ledger, regenerates a summary and sends one notification when a new real
defect lands.

```
lkml-gap-monitor.py scan    [--json] [--no-fetch] [--now T]
lkml-gap-monitor.py run     [--no-fetch] [--max-judges N] [--now T]
lkml-gap-monitor.py summary [--now T]
```

`scan` prints one line per sign-off window in the lookback and launches
nothing. `run` is `scan`, then judging, ledger, summary, publish and
notify. `summary` rebuilds the summary from the ledger alone.

It is a consumer of `fork-sandbox`: every judge goes through
`fork-sandbox run`, and the mailbox is read through `mail_cmd`.

## Configuration

`~/.config/lkml/gap-monitor.yaml`, or the file named by
`LKML_GAP_MONITOR_FILE`. There is deliberately no fallback location: a
missing file fails and names the path. An unknown key is an error.
Commands are argv lists or strings split with `shlex`; none is run
through a shell.

| Key | Meaning |
|---|---|
| `repo` | forge slug, `owner/name` (required) |
| `checkout` | path of a local clone of the reviewed repository; judges run from it (required by `run`) |
| `state_dir` | default `${XDG_STATE_HOME:-~/.local/state}/lkml/gap-monitor` |
| `mail_cmd` | default `fork-sandbox mail --remote`; run with `list --json` and `export <thread> --json` |
| `forge_cmd` | default `gh api`; run with `<path>` or `--paginate --slurp <path>`, nothing else, so only GET requests are ever made. A replacement must accept those two shapes |
| `judge.model` | the judge's model (required by `run`; never guessed) |
| `judge.harness` | default `claude` |
| `judge.concurrency` | default 2 |
| `judge.wait_timeout` | seconds, default 7200 |
| `judge.max_attempts` | default 2 |
| `judge.run_args` | list of extra `fork-sandbox run` arguments, default empty; the place for `--no-services`. Judges are local runs: `--k8s` here makes every launch fail, because `--wait` and `--attach-dir` are local-only |
| `sha_fetch_cmd` | optional; run as `<cmd> <pr> <sha> <SIGNED-OFF\|RESPIN>` in the checkout when the reviewed sha is still missing after `git fetch origin <sha>` |
| `bot_markers` | extra substrings that mark a body as automation |
| `exclude_tier_reason` | regex; a pull request with a thread whose tier reason matches is skipped whole |
| `xref_pattern` | regex overriding the default fix / bug-report pattern for cross-references |
| `quiet_hours` | default 6 |
| `lookback_days` | default 14 |
| `notify_cmd` | optional; run once with the message on stdin |
| `publish_cmd` | optional; run with the summary path appended |

Scratch space: evidence and handoffs are staged under
`${LKML_GAP_MONITOR_SCRATCH_DIR:-/var/tmp/claude-scratch/lkml-gap-monitor}`,
not under `state_dir`, because `fork-sandbox run` only binds an
attachment directory that lives under its scratch root. The tool never
deletes what it stages.

## The selection rule

A **sign-off** is a message from the thread's secretary whose trailing
`Panel-*` lines say `Panel-Status: CONVERGED` and `Panel-Verdict:
SIGNED-OFF` or `RESPIN`. The reviewed sha is the last token of that
message's `X-Review-Target` header. A `Panel-*` block that is not the
last lines of the body does not count, and a warning names the message.
Threads that are sub-panel children of another thread never sign off.

A **window** runs from one sign-off to the pull request's next sign-off
in any of its threads, or to now. A feedback item belongs to the latest
sign-off before it; items before the first belong to none. Timestamps in
mail and forge forms compare as instants. Only sign-offs newer than
`lookback_days` are looked at, so feedback that arrives later than that
after a pull request's last sign-off is never fetched or judged.

**Automation** is a user of type `Bot`, a login ending `[bot]`, a body
starting `Mailing list review of `, or a body containing anywhere one of
`<!-- lkml-state`, `<!-- lkml-panel`, `<!-- lkml-notice` or a configured
`bot_markers` string. A review agent that posts as a forge app is
therefore automation here and never triggers a run; one that posts from
an ordinary account is judged like any other commenter. Integration notes
(`<!-- lkml-integration: <series> v<N> -->`) are not automation: they
are tallied, not judged. Force-pushes, merges, closes and reopens are
shown to the judge as context and are never feedback.

A **trigger** is either a review body, inline comment or issue comment
from someone other than the pull request's author that is not
automation, not an integration note and not trivial (`LGTM`, thanks,
`+1`, a bare emoji or slash command; review bodies and issue comments
also need 40 characters), or a cross-reference from a later issue or pull
request (created after the sign-off) that reads as a fix or bug report:
a label containing `bug`, or the title, or the paragraph of its body
that cites this pull request, matches `xref_pattern`. The author's own
comments never trigger.

A window is **due** when it holds a trigger the ledger does not record
as judged and its newest non-automation item is older than
`quiet_hours`: feedback arrives in bursts, so there is one run per
burst. `scan` names one of eight classes per window:

| Class | Meaning |
|---|---|
| `due` | an unjudged trigger, quiet period over |
| `waiting` | an unjudged trigger, quiet period not over |
| `judged` | nothing new since the last judging |
| `author-only` | only the pull request author's own comments |
| `xref-only` | cross-references, none passing the rule |
| `empty` | nothing that could trigger |
| `blocked` | the reviewed sha is not available (see below) |
| `failed` | `judge.max_attempts` judge attempts used up |

The reviewed sha must exist in the checkout before a judge launches. If
it is missing the tool tries `git fetch origin <sha>`, then
`sha_fetch_cmd`. A sha it had to fetch is kept under
`refs/lkml-gap/<pr>-<12 hex>`; it creates no branch. A window still
missing its sha is `blocked`, recorded once, shown in the summary and
tried again on the next run.

## The ledger

`<state_dir>/ledger.jsonl` is the only state: append-only, one JSON
object per line, `"schema": 1`, and a `kind`. A truncated last line (a
crash mid-append) is skipped with a warning.

- `finding`, one per verdict: `judged_at`, `window` (`<pr>:<sign-off
  message id>`), `pr`, `thread`, `signoff_msg`, `signoff_at`,
  `signoff_verdict`, `version`, `tier`, `reviewed_sha`, `finding_id`,
  `item` (`{kind, id, url, user}` of the comment, null when the id maps
  to nothing), the judge's own fields copied through (`claim`,
  `verdict`, `severity`, `true_at_head`, `how_checked`, `evidence`,
  `failure_scenario`, `panel_coverage`, `panel_refs`, `code_owner`,
  `blame`, `gap`, `seat`, `seat_on_roster`, `confidence`,
  `duplicate_of`), `run_dir`, `judge_model`.
- `window`, one per judging attempt or block: `window`, `pr`, `status`,
  `attempt`, `items` (the forge ids put before the judge, as
  `kind:id`), `run_dir`, `at`, `head_matches`, `notes`, and `signoff_at`
  (so the summary can bucket a window with no findings by week).
  Status is `judged`, `judge-failed` or `sha-unavailable`.
- `integration`: `pr`, `series`, `version`, `comment_id`, `updated_at`,
  `url`, `take`, `take_with_changes`, `drop`, `changes` and `drops`
  (lists of `{sha, subject, reason}`). Appended when a (pr, series,
  version) is first seen or its comment changed; the newest record per
  key wins.

An item is judged when a `judged` window record lists it. Deleting lines
is how an operator forces a re-judge, or clears a `failed` window (delete
its `judge-failed` lines). A finding counts only while a `judged` window
record with the same `run_dir` exists.

A judge that leaves no parseable `verdicts.json` with a `findings` list
has failed, whatever its exit status; a valid file counts as judged even
when the launcher exited non-zero. A judged window in which some
numbered item received no verdict says so in its `notes`.

## The summary

`<state_dir>/summary.md`: plain markdown tables. Windows judged and
findings per verdict by ISO week of sign-off; real defects by severity,
code owner, panel coverage and seat; the real defects judged in the last
30 days with the comment URL; the integration tally per week; blocked and
failed windows. `publish_cmd` runs with the summary path appended; a
publish failure is reported, does not fail the work already done, and
makes the exit status 1. A notification lost to a kill between the ledger
append and `notify_cmd` still shows in the 30-day table.

## Turning the timer on

Copy the two units, then enable the timer:

```
mkdir -p ~/.config/systemd/user
cp contrib/systemd/lkml-gap-monitor.service contrib/systemd/lkml-gap-monitor.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now lkml-gap-monitor.timer
```

Nothing installs or enables them for you. The service runs
`~/.claude/scripts/lkml-gap-monitor.py run`, which `install.sh` links.
Exit status: 0 when the run did everything it set out to; 1 when a
fetch, judge, publish or notification failed or a window is blocked (the
rest is still done and recorded); 2 for a usage or configuration error.

## Cost

One judge run per burst of feedback per window, not per comment. It is
bounded by `--max-judges` per run and by `judge.max_attempts` per window;
a window that keeps failing stops costing anything and stays in the
summary until an operator acts. Integration notes need no model.
`scan` and `summary` cost nothing.

## What the tests do not prove

The suite's fixtures are invented, in the shapes the live systems print.
A test written by whoever wrote the code cannot catch a misread of an
external format, so the first runs against a real mailbox and forge
deserve a look at `scan` output before trusting a timer.
