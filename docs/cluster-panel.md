# Running a PR panel in a cluster

This page describes a review panel that runs with nobody driving it. A
kickoff mail opens a thread for an open pull request. Reviewer seats run as
Kubernetes Jobs, and an author seat decides after every round whether to post
a new version or close the panel. A secretary seat writes the final summary.
Between the kickoff and that summary, no orchestrator is involved: the round
protocol lives in the personas, and fork-sandbox's postmaster does the
routing.

The laptop flow in the [README](../README.md) is different. There, an
orchestrating session schedules each round. The cluster flow uses the same
personas and the same verdict tags, but the scheduling moves into the mail
itself.

Three pieces in this repo make it work:

| Piece | Role |
|---|---|
| `lkml-fleet-kickoff.sh --template pr-review` | opens the thread: roster, review target, grant |
| `fleet/personas/pr-author.md`, `fleet/personas/secretary.md` | run the round loop and close the panel |
| `lkml-panel-state.py` | reads the thread and says where the panel stands, as JSON; the gate |

Everything else comes from fork-sandbox's agent-mail subsystem: the store,
the postmaster, the `backend: k8s` seats, grants, and the review target. Its
`docs/agent-mail.md` is the authoritative reference for all of that. This
page covers only what lkml-review builds on top of it.

## The protocol

### The kickoff

The kickoff mail is the thread root. Its body opens with the roster, one key
per line:

    Author: @pr-author
    Panel: @architecture, @core, @devils-advocate, @docs, @newcomer, @operability, @second-opinion, @security, @tests
    Secretary: @secretary
    Version-Limit: 4
    Frozen-Head: <40-hex sha of the PR's head>

Every seat reads the roster from the root and never from the message that
woke it. A later message cannot change who is on the panel.

The kickoff also sets the thread's **review target** to the PR head as
version 1 (`--review-target <branch>:<sha>`). Each reviewer is spawned with
its checkout already at the current target. So nobody fetches a branch, and
nobody posts per-patch mail. The code under review is simply the reviewer's
working tree.

`Frozen-Head` marks where the human author's commits end. The author seat
never rewrites anything at or below it. Its own work is a series of commits
on top. The root's value is where the review starts; each later version has
a frozen head of its own (see "The human author pushes").

A typical kickoff from CI:

```bash
lkml-fleet-kickoff.sh "$WORKSPACE" "$BASE_SHA..$HEAD_SHA" \
  --from @ci-example --template pr-review \
  --subject "<PR title> (#<n>)" --summary "<one paragraph>" \
  --review-target "<head branch>:$HEAD_SHA" \
  --context-secret "example-ns-context" \
  --allow-namespace "example-ns" \
  --reach-probe "svc-a.example-ns.svc.cluster.local:8080" \
  --header "X-Preview-PR: <n>" \
  --remote --send --unless-exists
```

`--unless-exists` makes a re-run of the same CI job safe. Before sending,
the kickoff looks for a thread whose root carries every `--header` given
and the same review target. If one exists, open or closed, nothing is sent:
the existing thread's id is printed on stdout, where a fresh send prints
its new id, and the kickoff exits 0. A new head sha is a new review target,
so a push to the PR still opens a new panel.

The lookup needs a `fork-sandbox` whose `mail list` honours `--header`
filters. An older one ignores them and returns every thread; the kickoff
notices that and refuses, rather than reading it as "no panel yet".

`--template pr-review` takes its roster from `fleet/kickoffs/pr-review.roster`.
`--author`, `--panel`, `--secretary` and `--version-limit` override it one
key at a time. The panel becomes the cover's `To:` and its `X-Seats` header,
so the recipients and the roster cannot drift apart. `--remote` sends through
the mail API; the client reads `FORK_SANDBOX_MAIL_API_URL` and
`FORK_SANDBOX_MAIL_API_TOKEN_FILE` from the environment. The grant flags
(`--allow-namespace`, `--reach-probe`, `--host-alias`, `--seat-resources`,
`--context-secret`) attach to the new
thread, as do `--no-grant` (open the thread with no environment; refused with
any grant flag), `--grant-pending` (the grant follows later through
`fork-sandbox mail grant`; refused with `--no-grant` and with any grant flag)
and `--budget <n>` (the thread's own cap on seat spawns).
`--services-env KEY=VALUE` stores a services-hook setting on the thread for
its local seats (refused with `--remote`).
`--header` adds headers of the caller's own; the headers the mail
layer or this script owns are refused. `lkml-fleet-kickoff.sh --help` has
the full rules.

`--suite "<command>"` and `--suite-seats "@a,@b"` add `Suite:` and
`Suite-Seats:` lines to the root (the roster file defaults the seats to
`@tests`; the command is never defaulted). A suite seat must run the command
and put `Suite-Run: <N> passed, <M> failed` (or `could-not-run <error>`) on
its verdict reply. They exist because a seat whose environment cannot run the
suite must not converge: one once signed off on a stub harness. A suite seat
that is positive without a clean run (N of at least 1, M of 0) makes
`lkml-panel-state.py` refuse `CONVERGED`, and `STALLED` once the thread is
quiet, so an operator fixes the environment. The seat's `state` stays
`positive`, since it has answered. The command comes from the repository under
review, never from this repo, so the caller passes it on each kickoff.
A root that says `X-Lkml-Suite-Source: ci` takes the suite's result from CI
instead; see "Suite source, CI results and operator questions".

### Sizing the panel

Not every PR needs nine reviewers. Sizing is the caller's job: whatever kicks
off the panel picks a **tier** (`quick`, `standard` or `full`) and the
roster that goes with it, and passes them to `lkml-fleet-kickoff.sh` as the
roster flags, `--header "X-Lkml-Tier: <tier>"`, `--header
"X-Lkml-Tier-Reason: <why>"` and `--attach-file tier-focus.md`. On a push to
a PR that already has a panel, it also decides the push mode. This repo only
reads the result; what the headers mean, and how the gate reads them, is
under "Tiers and push modes" below.

### One round

1. **Reviewers reply to the author.** Each panel seat replies once per
   version, `To:` the author, and ends its reply with exactly one verdict on
   the last non-empty line: `Reviewed-by:`, `Acked-by:` or `Tested-by:`
   (non-blocking), or `Changes-requested`, `Question` or `NAK` (blocking).
   The postmaster stamps each reply with `X-Review-Target` and `X-Version`
   for the target the seat was spawned at, so a reply always says which
   version it is about.
2. **The author waits for a full set.** The author seat wakes on each
   review. It does nothing until every panel seat has replied on the current
   version N. A missing reply is never read as agreement.
3. **The author decides.** With every reply in:
   - if every panel seat's verdict on vN is non-blocking, it asks the
     secretary for the panel verdict (`To: @secretary` only);
   - if it disputes a block, it argues the block first and does not re-roll
     (see "Arguing a block" below);
   - if some seat still blocks and the version count has reached
     `Version-Limit`, it asks the secretary to close the panel as it stands,
     naming what still blocks. The count is the version number: every
     version counts, and so does every human push, whatever its push mode
     (below);
   - otherwise it re-rolls. It posts version N+1 as one cover reply, `To:`
     the panel, with a `Version: N+1` key in its reply stanza. The body holds
     a `Frozen-Head:` line, a changelog answering each review point, a
     `## Testing` section, and a `## Since vN` range-diff.
4. **The target moves.** The postmaster stamps the re-roll cover with the
   branch and sha the author committed, and moves the thread's review target
   to them. The panel wakes on the cover, each seat checked out at the new
   sha, and the round repeats. A verdict on an old version does not carry
   forward, except as a human push's push mode says (below).

### Arguing a block

The author is expected to argue a block that names no concrete failure,
rather than comply to reach convergence. The argument happens in a
**sidebar** on the current version, not in a new version:

1. The author replies to the seat's blocking message, `To:` that seat
   alone, with no `Version:` key. A rebuttal costs nothing against
   `Version-Limit`.
2. The seat answers. It either withdraws, with a non-blocking verdict, or
   holds with a concrete failure scenario and its blocking verdict again.
3. A held block goes to `@core`, which rules as maintainer. A block that is
   `@core`'s own goes to the operator as a `Question` `To: @operator` from
   the author, which shows as `AWAITING-OPERATOR`.
4. A ruling that overturns a block is a line `Overrule: <message-id>`,
   alone and unquoted at the left margin, naming the seat's blocking
   message. Only `@core` (while on the panel) and `@operator` can rule,
   and `@core` never rules on its own block. A ruling without that line
   upholds the block, and the author fixes it.

The gate reads the ruling: the overruled seat's state is `overruled`, and
it counts toward `CONVERGED` as a positive one does. A ruling binds to one
message, so a seat that blocks again afterwards is blocking again. The
secretary reports each dispute under "Disputes", with both sides, and
never as a defect unless a ruling upheld it.

### The human author pushes

The panel never pushes to the PR, but its human author may integrate part of
what the panel produced and push a new head H. When that happens, an
upstream-moved mail arrives on the existing thread, `To: @pr-author`, carrying
the header `X-Upstream-Head: <branch> <sha>`. Only the postmaster stamps that
header, so a sender cannot forge it. A thread run in tiers (below) may also
say how the push is handled; a mail that says `carry` is addressed
`To: @operator`, which resolves to no seat, so it wakes nobody. The sender and the mechanism that
notices the push live outside this repo; this repo only reads the result.
The mail may also carry a `Base: <sha>` line (the commit the PR now sits on)
and the human's own integration notes, between the lines
`--- lkml-integration begin ---` and `--- lkml-integration end ---`. In the
author's clone, H is the local branch `upstream`; the wake branch is still
vN's tip. The postmaster accepts a new target that is not a descendant of the
previous one.

The author seat treats the newest `X-Upstream-Head` as unanswered until a
later cover of its own carries `Frozen-Head: <that sha>`. Once every panel
seat has replied on vN, or the secretary has already been asked for vN, it
does not ask for or wait on a verdict: it posts H, unchanged, as version N+1.
That reopens a converged thread. A push never aborts a round in progress; it
is integrated after the seats have replied.

A version like this is a **human-integration version**. Its cover says that a
human author sits above the author persona and made the calls, gives
`Frozen-Head: <H>`, and classifies every panel commit of vN as taken,
changed or not taken, with the method that decided it (ancestry in H, a
patch-id match, a reverse-apply, a forward-apply, or none of those) and the
human's reason where the notes give one. A commit that is an ancestor of H
is classified by comparing H's tree with the panel's over the paths the
commit touched, not by ancestry alone and not by applying the commit's own
diff, which misreads a stack: a commit the human pulled and then reverted is
not taken, and one they pulled and then edited is changed. A patch-id match
counts as taken only while the copy's change is still in H's tree. Where
they give no reason, the
reason is exactly `not taken
by the human author; no reason given`; the persona never invents one and never
asks. Notes are used only when their marker line names this version and a
series name ending in the first 7 hex characters of the root's `Frozen-Head`.
Nothing the human did not take is rebased forward: it counts as rejected, and
the version's target is exactly H. Human-integration versions count toward
`Version-Limit` like every other version.

With no push mode on the mail, the panel reviews it like any version, and
every seat reviews it afresh; verdicts do not carry forward. A suggestion the human author did not take is
**decided**: a seat may raise it again only as a blocking objection that says
why the decision is wrong. Otherwise the author answers it as decided and
changes nothing.

#### Per-version `Frozen-Head`

The frozen head of a version is the `Frozen-Head:` line of the author's cover
that set it, else the root's. Every cover the author posts carries one. The
author is a model, so the line alone is not trusted. `lkml-panel-state.py`
accepts a value other than the root's only when a message earlier on the
thread carries an `X-Upstream-Head` with that same sha. Otherwise it reports
the mismatch as a reason and falls back to the root's frozen head: the author
cannot declare its own commits frozen and so earn a `SIGNED-OFF`.

#### Tiers and push modes

A thread may say how big a panel it needs and how a push is to be handled.
Both are headers; the CI side that kicks off the thread and notices the push
sets them (`lkml-fleet-kickoff.sh --header` and `--attach-file`), and this
repo only reads them.

On the root (kickoff) message:

| Header | Value | Meaning |
|---|---|---|
| `X-Lkml-Tier` | `quick`, `standard` or `full` | the tier the tier step chose |
| `X-Lkml-Tier-Reason` | one line, at most 200 characters | why, for the dashboard |

The roster is still the root's `Panel:` line (stamped as `X-Seats` too). A
smaller tier is a smaller *named* roster, never "fewer seats happened to
answer": convergence needs a positive verdict from every seat in the roster.
Per-seat focus text travels as an attached file `tier-focus.md`, one
`## @<seat>` section per seat; the gate never reads it.

On an upstream-moved mail, `X-Lkml-Push-Mode` says how the push is handled:

| `X-Lkml-Push-Mode` | Extra headers | Who is woken | Verdicts on the new version |
|---|---|---|---|
| `carry` | none | nobody (`To: @operator`) | every seat's latest verdict carries forward unchanged |
| `recheck` | `X-Lkml-Recheck-Seats: core, tests` | `@pr-author`, who posts the version to those seats only, scoped to the new commits | seats not listed carry forward; listed seats need a fresh verdict |
| `escalate` | `X-Lkml-Add-Seats: security` (may be empty) and `X-Lkml-Tier: <new tier>` | `@pr-author`, who posts the version to the whole new roster | the roster becomes the root's `Panel:` plus every `X-Lkml-Add-Seats` so far; every seat needs a fresh verdict |
| absent | none | as above | every seat needs a fresh verdict |

A carry mail is identified by its header, never by who it is addressed to. It
is `To: @operator` so that it wakes no one, and is not a question for the
operator and never flags the thread. Seat names in the two seat headers may be
bare or `@`-prefixed.

Rules that hold in every mode:

- The tier only ratchets up within a thread. An `escalate` may name the
  current tier (to add seats) or a higher one; one that names a lower tier,
  or none, is ignored as malformed and treated as absent.
- A carried verdict is only ever a verdict that seat actually gave on an
  earlier version of the same thread. A seat with nothing to carry still owes
  one.
- A blocking verdict carries forward as blocking. Carry never turns a
  blocker into a pass.
- `carry` is only correct when every commit on the new head is patch-identical
  to the previous head's (a pure rebase). The tier step decides that from
  `git patch-id`; the gate trusts the header and does not recompute it.
- Every human push counts toward `Version-Limit`, whatever the mode.
- A malformed push mode (an unknown value, a `recheck` with no seat on the
  panel, an `escalate` naming a lower or unknown tier, or a push mode on a
  message with no `X-Upstream-Head`, which only the postmaster stamps) is
  treated as absent and reported as a reason in the gate's output. It is
  never silently honoured, and, being a reason, blocks `CONVERGED`.

How the gate reads a carry:

- **A carry version.** When every push since the posted version is a `carry`,
  the PR is on a synthetic next version. A carry does not move the review
  target (only the author's post does), so the gate takes that version's
  target and its frozen head from the newest push's `X-Upstream-Head`:
  `target.source` is `carry`, `target.version` is the posted version plus one
  per push, and `frozen_head` is `{sha, "upstream"}`. A panel that carries to
  convergence therefore signs off at the new head. Every seat's latest verdict
  and the secretary's trailer carry forward. A carried `RESPIN` contradicts a
  target that is its own frozen head, so it blocks `CONVERGED` like any other
  such verdict.
- **A posted version that answers a push.** The author's first post after a
  push, whose `Frozen-Head` is that push's head, carries every seat the pushes
  since the previous version do not withhold: `recheck` withholds the seats it
  lists, `escalate` and a missing or malformed mode withhold all. The
  secretary's trailer is not carried here; the post needs a fresh one.
- Carrying chains: a seat that carried onto a recheck version carries through
  a later carry push too.
- `seats[].carried` says whether a seat's verdict was given on this version
  (`false`) or carried (`true`), and `seats[].version` is the version it was
  given on, so a display can say "carried from v3".

#### Suite source, CI results and operator questions

A panel on a PR whose suite needs the preview environment's services cannot
run that suite in a seat's sandbox, and a seat that cannot run it only ever
reports its own environment. The thread can instead say that the PR's own CI
run is the suite's source of truth, and that a seat's question for the human
stops blocking after a set time. Three headers on the root and three on a CI
result mail; the CI side that kicks off the thread and posts the results sets
them, and this repo only reads them. Under `ci` no seat re-runs the project's
tests: the personas and the pr-review kickoff send the seats to verify the
change by hand instead, every variant of each changed path, against a live
environment when the thread names one.

On the root (kickoff) message:

| Header | Value | Meaning |
|---|---|---|
| `X-Lkml-Suite-Source` | `ci` | the CI gate below replaces the per-seat `Suite-Run` gate for this thread; any other value is a reason and leaves the `Suite-Run` gate in force |
| `X-Lkml-CI-From` | one address, `@ci` or `ci` | the one sender whose CI headers count on this thread; absent, `@operator`; anything else is a reason and falls back to `@operator` |
| `X-Lkml-Question-Timeout` | `<N>h`, whole hours, N of at least 1 | an operator question stops blocking once it is that old; malformed is a reason and no timeout |

On a CI result mail, one per result, `To: @operator` so that it wakes nobody,
with a short human summary (failing jobs and tests) as the body:

| Header | Value | Meaning |
|---|---|---|
| `X-Lkml-CI-Status` | `success`, `failure` or `pending` | what CI said |
| `X-Lkml-CI-Head` | `<branch> <sha>`, the syntax of `X-Upstream-Head` | the commit CI ran on |
| `X-Lkml-CI-Url` | a URL, optional | where a human can read the run |

Rules for the CI gate (only under `X-Lkml-Suite-Source: ci`; without it the
`Suite-Run` gate in the kickoff section is unchanged, byte for byte):

- **Trust.** A CI header counts only on a mail from the trusted sender,
  and there is exactly one: `@operator`, unless the root's `X-Lkml-CI-From`
  names an address, in which case that address instead (`@operator`'s CI mail
  then no longer counts). A recipient is not required. Only the root may name
  it, because no seat can change the root; `X-Lkml-CI-From` on any other
  message is ignored and reported as a reason. Any seat can set an `X-*`
  header, so a CI header from any other sender is ignored and reported as a
  reason. A mail from the trusted sender with an unknown status, or a head
  that is not exactly one `<branch> <sha>`, is ignored with a reason too.
- **The gate.** `CONVERGED` needs the newest trusted CI mail whose head sha
  equals the current frozen head's to say `success`. None, or `pending`, is
  "CI has not reported on `<sha8>`"; `failure` is "CI failed on `<sha8>`". A
  result on any other sha says nothing about this one: a carry version's
  frozen head is the pushed head, so a rebase needs CI success on the new head.
- **Seats.** No seat owes a `Suite-Run` line and none is read (every
  `seats[].suite_run` is null); `Suite-Seats` is ignored for gating. The
  personas follow: the tests seat reviews test code and reads the CI mail, and
  the author does not run the full suite.
- **The panel's own commits are never CI-tested.** A `RESPIN`'s bundle sits
  above the frozen head CI ran on; `ci.covers_target` is false there, and the
  cover says the author's commits are not CI-tested.

A question for the human is a message from a panel seat that carries the
`Question` tag and names `@operator` in `To:` or `Cc:`. The seat still gives
its code verdict on the same message, so a question alone leaves the seat
owing one. The gate lists every such question whatever the timeout, in
`questions`, so a dashboard can show it. With `X-Lkml-Question-Timeout` set, a
question at least that old stops blocking: the `Question` tag on that message
is dropped before any seat is judged and the strongest remaining tag on the
same message decides. A message whose only tag was the question leaves the seat
with no verdict from it, so it still owes one and falls back to its earlier
verdicts by the usual rules, carry included. **A timeout never manufactures a
positive verdict.** A question an `@operator` reply answered is ordinary: the
seat's next verdict decides.

The gate's output gains `ci` (`{"source", "status", "sha", "branch", "url",
"message_id", "covers_target"}`: the newest trusted result on the frozen head,
reported on every thread, with `source` `ci` only when the root opted in),
`question_timeout_hours`, `questions` (`{"seat", "message_id", "asked_at",
"age_seconds", "timed_out", "subject"}`), and `now`. `lkml-panel-state.py`
takes `--now <ISO-8601>` to pin the clock the ages are taken at; the display
tools take theirs from `SOURCE_DATE_EPOCH`. `lkml-render.py` and
`lkml-fleet-status.sh` show the newest trusted result and the questions with
their ages as one compact line each.

### Closing

The secretary verifies the panel's state from the thread itself; it does not
take the author's word for it. It then posts one summary `To: @operator`,
which wakes nobody. The body ends with a machine-readable trailer block:

    Panel-Version: <N>
    Panel-Status: CONVERGED | IN-PROGRESS
    Panel-Verdict: SIGNED-OFF | RESPIN

`Panel-Verdict` appears only with `CONVERGED`. It follows the frozen head of
the version under review. It is `SIGNED-OFF` when that version's target is
its frozen head: the human's commits are good as they stand, whether that is
the PR's head at v1 or a later human integration. It is `RESPIN` when the
target differs, meaning the author's commits above the frozen head are the
recommended change, and the operator pulls them as a bundle. The panel never pushes to the PR, and no seat can: it has no
credential for anything remote.

## The gate: `lkml-panel-state.py`

`lkml-panel-state.py <thread-id> [--remote]` reads the thread export and the
postmaster's status for the thread, and prints one JSON object (schema
`lkml-panel-state/1`). Anything that acts on a panel's outcome, such as a CI
job or a dashboard, should read this object and nothing else.

| `status` | Meaning | What to do |
|---|---|---|
| `CONVERGED` | every panel seat holds a positive verdict on the current target, or a block a ruling overruled; the secretary agrees, and the postmaster is quiet | act on `verdict`; for `RESPIN`, `bundle` gives the base (the frozen head), tip and branch |
| `IN-PROGRESS` | work is still pending or running | wait |
| `STALLED` | nothing is pending, but the panel has not converged | a human looks; `reasons` says why |
| `NEEDS-OPERATOR` | the postmaster flagged the thread | a human looks; the flag reason is in `postmaster` |
| `AWAITING-OPERATOR` | a seat or the author asked @operator a question that is still open | answer it; `questions` lists them, open ones with `open: true` |
| `CLOSED` | the postmaster has the thread upstream closed (the pull request was closed or merged, or the thread was restarted), and it had not converged | nothing; no seat will wake. `upstream_state` names the closing message, which a caller can read for why |

`CLOSED` outranks every status but `CONVERGED`: a panel that converged
before its thread closed keeps its verdict. `AWAITING-OPERATOR` ranks below
`NEEDS-OPERATOR` and above the rest. A
question is open until it times out, the seat gives a newer verdict (for
the author's question, a new version is posted), or an @operator mail
replies to it or is addressed to the asking seat.

Every string in `reasons` names a condition that blocks `CONVERGED`. A
`CONVERGED` object has none. The script's `--help` documents the full field
list and the precedence rules.

Two keys describe the frozen head. `roster.frozen_head` is the root's value.
The top-level `frozen_head` is `{"sha", "source"}` (null when unknown) for the
current target, where `source` is `root` or `upstream` (a value vouched for by
an earlier `X-Upstream-Head`, as above). With a frozen head known, a
secretary verdict of `SIGNED-OFF` is valid only when the target sha equals it
and `RESPIN` only when it differs; the other is a contradiction, named in
`reasons`, and never `CONVERGED`. With none known, `SIGNED-OFF` is valid only
on v1 and `RESPIN` only above it. The change is additive, so the schema stays
`lkml-panel-state/1`.

The same additive change gives the object `tier` (`{"name", "reason",
"source", "message_id"}`: the root's, superseded by the newest valid
`escalate`), `panel` (the effective roster: the root's `Panel:` plus
escalated-in seats; `roster.panel` stays the root's), `push` (the newest
upstream-moved mail: its `mode`, `seats`, `malformed` text and whether it is
`answered`, or null), `seats[].carried`, `secretary.carried`, and a
`target.source` of `carry`. A carry version's frozen head is the pushed head,
so a panel that carries to convergence is `SIGNED-OFF` at the new head. See
"Tiers and push modes".

It also has `ci` (with `ci.trusted_from`, the sender whose CI mail counts),
`question_timeout_hours`, `questions` and `now`; see "Suite source, CI results
and operator questions".

`postmaster` carries the postmaster's budget facts as well: `budget`,
`budget_source` (`thread` or `global`), `spawns_total` (never reset) and
`grant_mode` (`none`, `file` or `missing`). Each is null when the status JSON
lacks it or has it in the wrong type (an older postmaster). They are for a
dashboard: they raise no reason and change no status.

The gate also compares the newest `X-Upstream-Head` on the thread with the
resolved frozen head. When they differ, the human author's newest push has no
version posted for it, so a sign-off on an older head does not describe the PR
as it now stands. That is a reason and the thread is not `CONVERGED`. It covers
an author that has not run yet, one that failed to post, and one that answered
a push with a mismatch report to the operator.

### Why the gate and the personas read verdicts differently

Three readers judge verdicts: the author seat, the secretary, and
`lkml-panel-state.py`. They do not use exactly the same rule.

- The **personas** take the tag on the *last* non-empty, non-quoted line of a
  seat's latest reply on vN. A reply with no tag there counts as blocking.
- **`lkml-panel-state.py`** accepts a `-by:` trailer on *any* line (at the
  left margin, not quoted), and a bare verdict on the first or last line. It
  matches replies by the target sha rather than by `X-Version`. When a reply
  carries several tags, the most severe one wins. These are
  `lkml-fleet-status.sh`'s rules, matched exactly.

The two rules can disagree in edge cases. For example, a reply might carry
`Reviewed-by:` mid-body and then end in prose. That disagreement is safe,
because `CONVERGED` needs both readers to agree. `lkml-panel-state.py`
reports `CONVERGED` only when its own reading shows every seat positive
*and* the secretary's on-target trailer says `CONVERGED`. When the secretary
says `CONVERGED` and the script's own reading disagrees, the result carries
a named reason instead. That is the false green this tooling exists to
catch. **The gate is `lkml-panel-state.py`**, never the secretary's trailer
alone.

## Configuring the fleet

In the cluster, each seat needs keys that only fleet.yaml can carry.
fork-sandbox refuses `backend`, `endpoint`, `grant` and `review-target` in
persona frontmatter, because a seat must not be able to choose its own
backend or promote itself to moving the target. The personas in this repo
therefore stay backend-neutral. The cluster placement lives in the fleet
file, which `lkml-fleet.sh` reads from `~/.config/lkml/fleet.yaml` (or from
`LKML_FLEET_FILE`).

An example, with invented names throughout:

```yaml
agents:
  # claude/opus from the persona frontmatter: the seats whose judgment
  # decides the outcome.
  pr-author:
    network: pinned
    backend: k8s
    review-target: sets          # the only seat that moves the target
    grant: required              # only if its tests must reach the preview environment
  core:
    network: pinned
    backend: k8s
    review-target: follow
    grant: required
  secretary:
    network: pinned
    backend: k8s
    review-target: follow        # required; see below
  # pi on a cluster model endpoint for the other reviewers.
  tests:
    harness: pi
    model: example-coder-medium
    network: pinned
    backend: k8s
    endpoint: gpu-pool-a
    review-target: follow
    grant: required
  docs:
    harness: pi
    model: example-coder-medium
    network: pinned
    backend: k8s
    endpoint: gpu-pool-a
    review-target: follow        # reads code only; no grant needed
  # architecture, newcomer and security follow the same shape as docs,
  # with grant: required on any seat that must reach the preview environment.
  # devils-advocate keeps claude/opus from its frontmatter, like core.
  # operability and second-opinion are pi in their frontmatter but name no
  # model, so the fleet entry supplies the model and the endpoint.
  operability:
    model: example-coder-medium
    network: pinned
    backend: k8s
    endpoint: gpu-pool-a
    review-target: follow
  # second-opinion: the same shape as operability.
  # author, ci and distiller are not on the roster; see below.
  author:
    harness: pi
    model: example-coder-medium
    network: pinned
    backend: k8s
    endpoint: gpu-pool-a
  # ci and distiller: the same shape as author.
```

What each key does here:

- **`backend: k8s`** runs the seat's wake as a Job in the cluster.
  `review-target` and `grant` are accepted only on such a seat.
- **`network: pinned`**: a k8s seat cannot run sealed, because its egress is
  governed by the cluster's NetworkPolicy instead.
- **`endpoint`** names one of the model endpoints registered with the
  cluster's model proxy. It is a label, not a URL.
- **`review-target: sets`** goes on the author, and on at most one seat per
  fleet. Only that seat's `Version:` key moves the target.
- **`review-target: follow`** goes on every panel seat **and on the
  secretary**. A `follow` seat is spawned at the current target, and its
  replies carry that target's `X-Review-Target`. If the secretary is not
  `follow`, its summary carries no target. `lkml-panel-state.py` then never
  counts its trailer as on target, and the panel can never reach
  `CONVERGED`.
- **`grant: required`** goes on seats that must reach the thread's preview
  environment. Such a seat waits until the thread has a grant. If the
  kickoff sent none, the postmaster flags the thread (`no-grant`) and
  `lkml-panel-state.py` reports `NEEDS-OPERATOR`. A kickoff sent with
  `--grant-pending` holds the seat quietly instead, until `fork-sandbox mail
  grant` arrives or the postmaster's grant-pending timeout runs out.

- **Every persona file is an agent**, including the ones the pr-review
  roster never addresses (`author`, `ci`, `distiller`). A cluster postmaster
  refuses local seats, so each of those needs a `backend: k8s` entry too.
  Putting them on pi means a stray address never spends a claude
  subscription.

The fleet entry wins over the persona frontmatter field by field, and it
cannot unset a field. `ci`, `operability` and `second-opinion` name
`harness: pi` and no model; every other persona names `harness: claude`,
with `model: opus` for the authors, core, devils-advocate, security and
secretary and `sonnet` for the rest. So a seat moved to pi must name a
model its endpoint serves, or it inherits a claude model name. A pi
persona with no model is where the fleet entry pins `model` and
`endpoint` for the site. Without them, a `backend: k8s` seat falls back to
the k8s install's defaults (`K8S_DEFAULT_ENDPOINT`, `K8S_DEFAULT_MODEL`)
and to discovery of the single endpoint and the single model it serves.
It fails only when those are ambiguous or unavailable. So pin them in the
fleet entry rather than rely on whatever the install happens to serve.

A claude seat in the cluster needs a claude credential installed with the
postmaster. See "Claude seats in a cluster postmaster" in fork-sandbox's
`docs/cluster-postmaster.md`. The personas were written and tuned against
claude. On pi, their behaviour is unproven until a panel has shown it.

The postmaster routing the thread must see this fleet file and this repo's
`fleet/personas/`. `lkml-fleet.sh` exports both as
`FORK_SANDBOX_FLEET_FILE` and `FORK_SANDBOX_PERSONAS_DIR`, and
`install --postmaster` reads the same two variables. It also exports
`FORK_SANDBOX_PROMPTS_DIR` as `fleet/prompts/`, which holds
`protocol-reviewer.md`: the shared protocol every role-only reviewer
persona names with `protocol: reviewer`. That variable is only the
runtime lookup. `install --postmaster` does not read it; it ships the
`prompts/` directory of its own config directory, so `fleet/prompts/`'s
`protocol-*.md` files must be copied there first (a deploy repo's CI
does this). So the cluster install is:

```bash
LKML_FLEET_FILE=<cluster fleet file> lkml-fleet.sh k8s install --postmaster
```

Check the file first with `lkml-fleet.sh fleet check --cluster` under the
same `LKML_FLEET_FILE`. Set `FORK_SANDBOX_CLUSTER_CLAUDE=1` for that check
when the install will carry a claude credential.

### Gating the author's wakes

Reviewers reply `To: @pr-author`, so the postmaster wakes the author on
every reply, and most of those wakes find a reviewer still unanswered. Each
one spends a spawn. A `wake-when` gate lets the postmaster ask first:

```yaml
budget-reserve: {spawns: 2, agents: [pr-author, secretary]}
agents:
  pr-author:
    wake-when: lkml-panel        # this seat only
```

- **`wake-when: lkml-panel`** goes on the `pr-author` agent and no other.
  The postmaster runs `$FORK_SANDBOX_HOOKS_DIR/wake-when.lkml-panel` before
  each spawn of that seat. The gate asks `lkml-panel-state.py` whether every
  panel seat holds a verdict on the current version, and defers the wake
  until they do. A carried verdict counts as answered, so a `recheck`
  version waits only on the seats it lists and a `carry` version on nobody;
  a seat escalated in by a push is a panel reviewer like any other. A human
  push, mail from anyone not on the panel, and a thread with no target always
  wake the author. So does a reviewer's block or question once every seat
  still waited on has run on the current target and posted nothing, with no
  retry pending (the postmaster re-runs a deferred gate after each zero-reply
  harvest): no reply is coming, and waiting would strand the author.
- **`budget-reserve`** names both seats because the author's final post
  comes before the secretary's verdict. A reserve held for the secretary
  alone would refuse that post, and the secretary would never be woken.
- **Staging.** Run `lkml-wake-gate-install.sh`, then `lkml-wake-gate-install.sh
  --check`, before `install --postmaster`. The gate runs a staged copy of
  `lkml-panel-state.py`, and `--check` fails when that copy has drifted from
  the repo's.
- **Exit codes.** 0 wakes the author. 1 defers: nothing spawns and no budget
  is spent, and the author's next wake sees the whole thread. 2 means the
  gate itself failed (a missing input, or `lkml-panel-state.py` erroring);
  the postmaster wakes the author anyway and logs `wake-gate-error`, so look
  for that in the postmaster log. A defer that no later reply ever wakes shows
  up as a `wake-deferred` flag, which `lkml-panel-state.py` reports as
  `NEEDS-OPERATOR`.

## Known limits

- Nothing wakes a thread when an operator question times out: no mail
  arrives, and the gate only reads the clock when it is asked. The secretary
  and the author count a question to `@operator` given beside a positive
  verdict as that verdict, so the secretary's on-target CONVERGED can stand
  with the question open and the gate converges when the question is answered
  or times out, on its next read. A message that is only a question leaves
  the secretary writing IN-PROGRESS, and nothing revisits that after a
  timeout; reviewers are told never to send one.
- A reviewer that Cc's another seat can buy that seat an extra wake on the
  same version. The author and the secretary both read a seat's *latest*
  reply on vN, so an extra reply can replace the seat's earlier verdict.
