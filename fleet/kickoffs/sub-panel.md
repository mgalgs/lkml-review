<!--
Kickoff template: start a sub-panel, a child review thread that runs
beside a main panel thread on the same change. Its seats review once and
never gate the main panel; there is no author here to argue with. The
secretary (fleet/personas/secretary.md) writes one digest, which a
deployment relays into the parent thread for the main panel's author.
docs/cluster-panel.md, "Sub-panel", is the whole contract.

Send with `lkml-fleet-kickoff.sh --template sub-panel --parent-thread
<thread-id> --review-target <branch>:<sha> ...`. The roster comes from
sub-panel.roster (or --panel/--secretary); --parent-thread stamps the
root's X-Lkml-Parent-Thread header and fills ${PARENT_THREAD}. The kickoff
refuses this template without --parent-thread, and refuses an author.

Placeholders (dumb substitution, not a template engine):
  ${FROM}          sending address: the deployment that opened this
                   thread, which every seat replies To:
  ${PARENT_THREAD} the main panel's thread id
  ${PANEL}         the reviewing seats, comma-separated @addrs; also the
                   kickoff's To:
  ${SECRETARY}     the secretary seat's address, e.g. @secretary
  ${SUMMARY}       one paragraph: what the change does and why
  ${BASE}          the base ref/commit the change applies on top of
  ${BRANCH}        the change's branch name
  ${PATCH_COUNT}   number of commits in the change

There is no Author: line, no Version-Limit and no Frozen-Head: a sub-panel
reviews one version and has no next one.
-->

Parent-Thread: ${PARENT_THREAD}
Panel: ${PANEL}
Secretary: ${SECRETARY}

${SUMMARY}

Base: ${BASE}
Branch: ${BRANCH}
Patches: ${PATCH_COUNT}

Your checkout is already at the version under review. Read the code
there, for example:

    git log --oneline ${BASE}..HEAD
    git diff ${BASE}..HEAD

## This is a sub-panel

This thread is a sub-panel of the review on thread ${PARENT_THREAD}.
There is no author on this thread and there will be no next version.
Nobody here will argue a block, and nobody will answer a question.
Your findings reach the main panel's author only through the secretary's
digest, which the author reads beside its own panel's reviews and decides
what to take. A finding that needs this thread to make sense is lost.

## What's being asked

Every seat on the `Panel:` line above replies ONCE, on the version under
review, `To: ${FROM}` (the root's sender, which wakes nobody) and
`Cc: ${SECRETARY}`, and ends that reply with exactly one verdict line
(below) as its last non-empty line. Silence is NOT a valid outcome: the
secretary writes the digest only once every panel seat has replied, and a
seat that says nothing is indistinguishable from one that crashed. If you
have nothing to add, say so with `Acked-by:` or `Reviewed-by:`.

Write each finding so it stands on its own, without this thread:

- **Location**: the file and line, or the function, it is about.
- **Failure scenario**: the concrete input or state, and what goes wrong
  if this merges as it stands.
- **Evidence**: what you ran and what it printed, kept apart from what
  you only read or inferred.

## Sign-off convention

End your reply with exactly one of these, as the last non-empty line:

- `Reviewed-by: <persona>` — you'd stand behind this as committed.
- `Acked-by: <persona>` — the approach is right; you have not verified
  every line, or you have nothing to add.
- `Tested-by: <persona>` — you ran it and it behaved (or say what
  broke).
- `Changes-requested` — something must change before this merges.
- `Question` — you need an answer before you can form a view.
- `NAK` — this must not merge as it stands, with what would change
  your mind.

The colon after the three `-by` trailers is load-bearing: a trailer
without it does not register. A trailer must start its own line at the
left margin, with no leading whitespace. A bare verdict
(`Changes-requested`, `Question`, `NAK`) registers only on the first or
last non-empty, non-quoted line of the body; here it goes last.

Your verdict says how you read the change; it gates nothing. The
secretary judges each finding blocking or non-blocking on its own merits,
not from your trailer. A `Question` gets no answer here: put what you
would ask as a finding the author can check.

## Verifying it yourself

Check the change the way a human reviewer would: by poking at it.

- Exercise every variant of each changed code path, not only the one
  the change's own test takes: each accepted input form, each new
  branch and default, each error path. A filter that accepts both
  `a=1,2` and `a=1&a=2` gets both tried.
- When the attached context names a live environment for this version,
  try it there: call its API, load its pages, try the edge case you
  suspect.
- With no live environment, say so in one line, then verify by reading
  and by any self-contained check: call the function from a shell, run
  a snippet against the library. A missing environment is your
  environment, not a finding against the code.
- Reproduce a bug before you raise it, and put the reproduction in your
  reply.

Say what you actually ran and what it printed, and keep it apart from
what you only read or inferred: the author weighs the two differently
and can only do so if you say which is which. `Tested-by:` is for
something you ran. Never write to state you did not create: use your
own test databases and indices, not the environment's live data. Keep
every check proportionate: a reply that runs out of time is no reply at
all.

## After your reply

That is your whole part. Do not reply to another seat's review, and do
not reply to the secretary's digest: it is the last message on this
thread, and it goes to ${FROM}.
