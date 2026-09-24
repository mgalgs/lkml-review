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
    Panel: @architecture, @core, @docs, @newcomer, @security, @tests
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
on top.

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
  --remote --send
```

`--template pr-review` takes its roster from `fleet/kickoffs/pr-review.roster`.
`--author`, `--panel`, `--secretary` and `--version-limit` override it one
key at a time. The panel becomes the cover's `To:` and its `X-Seats` header,
so the recipients and the roster cannot drift apart. `--remote` sends through
the mail API; the client reads `FORK_SANDBOX_MAIL_API_URL` and
`FORK_SANDBOX_MAIL_API_TOKEN_FILE` from the environment. The grant flags
(`--allow-namespace`, `--reach-probe`, `--context-secret`) attach to the new
thread. `--header` adds headers of the caller's own; the headers the mail
layer or this script owns are refused. `lkml-fleet-kickoff.sh --help` has
the full rules.

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
   - if some seat still blocks and N has reached `Version-Limit`, it asks the
     secretary to close the panel as it stands, naming what still blocks;
   - otherwise it re-rolls. It posts version N+1 as one cover reply, `To:`
     the panel, with a `Version: N+1` key in its reply stanza. The body holds
     a changelog answering each review point, a `## Testing` section, and a
     `## Since vN` range-diff.
4. **The target moves.** The postmaster stamps the re-roll cover with the
   branch and sha the author committed, and moves the thread's review target
   to them. The panel wakes on the cover, each seat checked out at the new
   sha, and the round repeats. A verdict on an old version does not carry
   forward.

### Closing

The secretary verifies the panel's state from the thread itself; it does not
take the author's word for it. It then posts one summary `To: @operator`,
which wakes nobody. The body ends with a machine-readable trailer block:

    Panel-Version: <N>
    Panel-Status: CONVERGED | IN-PROGRESS
    Panel-Verdict: SIGNED-OFF | RESPIN

`Panel-Verdict` appears only with `CONVERGED`. It is `SIGNED-OFF` when the
panel converged on v1, meaning the PR is good as it stands. It is `RESPIN`
when the panel converged on a later version. The commits above
`Frozen-Head` are then the recommended change, and the operator pulls them
as a bundle. The panel never pushes to the PR, and no seat can: it has no
credential for anything remote.

## The gate: `lkml-panel-state.py`

`lkml-panel-state.py <thread-id> [--remote]` reads the thread export and the
postmaster's status for the thread, and prints one JSON object (schema
`lkml-panel-state/1`). Anything that acts on a panel's outcome, such as a CI
job or a dashboard, should read this object and nothing else.

| `status` | Meaning | What to do |
|---|---|---|
| `CONVERGED` | every panel seat holds a positive verdict on the current target, the secretary agrees, and the postmaster is quiet | act on `verdict`; for `RESPIN`, `bundle` gives the base, tip and branch |
| `IN-PROGRESS` | work is still pending or running | wait |
| `STALLED` | nothing is pending, but the panel has not converged | a human looks; `reasons` says why |
| `NEEDS-OPERATOR` | the postmaster flagged the thread | a human looks; the flag reason is in `postmaster` |

Every string in `reasons` names a condition that blocks `CONVERGED`. A
`CONVERGED` object has none. The script's `--help` documents the full field
list and the precedence rules.

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
  `lkml-panel-state.py` reports `NEEDS-OPERATOR`.

- **Every persona file is an agent**, including the ones the pr-review
  roster never addresses (`author`, `ci`, `distiller`). A cluster postmaster
  refuses local seats, so each of those needs a `backend: k8s` entry too.
  Putting them on pi means a stray address never spends a claude
  subscription.

The fleet entry wins over the persona frontmatter field by field, and it
cannot unset a field. Every persona except `ci` names `harness: claude`,
with `model: opus` for the author, core, security and secretary and
`sonnet` for the rest. So a seat moved to pi must name a model its endpoint
serves, or it inherits a claude model name.

A claude seat in the cluster needs a claude credential installed with the
postmaster. See "Claude seats in a cluster postmaster" in fork-sandbox's
`docs/cluster-postmaster.md`. The personas were written and tuned against
claude. On pi, their behaviour is unproven until a panel has shown it.

The postmaster routing the thread must see this fleet file and this repo's
`fleet/personas/`. `lkml-fleet.sh` exports both as
`FORK_SANDBOX_FLEET_FILE` and `FORK_SANDBOX_PERSONAS_DIR`, and
`install --postmaster` reads the same two variables. So the cluster install
is:

```bash
LKML_FLEET_FILE=<cluster fleet file> lkml-fleet.sh k8s install --postmaster
```

Check the file first with `lkml-fleet.sh fleet check --cluster` under the
same `LKML_FLEET_FILE`. Set `FORK_SANDBOX_CLUSTER_CLAUDE=1` for that check
when the install will carry a claude credential.

## Known limits

- A reviewer that Cc's another seat can buy that seat an extra wake on the
  same version. The author and the secretary both read a seat's *latest*
  reply on vN, so an extra reply can replace the seat's earlier verdict.
- The kickoff has no "unless a panel is already open for this PR" check yet.
  A CI job that runs twice opens two threads.
