<!--
Kickoff template: a focused FOLLOW-UP round on a series that is already
under review — round two or later, aimed at specific paths, patches, or
questions the operator read out of the first round. Not the first pass;
series-review.md starts a thread, this one lands inside one.

This is a REPLY, not a new thread. Under the agent-mail transport every
wake carries the entire thread in its prompt — the thread is the memory —
so a focused round only works where the earlier round's review already
lives. Send it with:
    fork-sandbox mail reply --from ${FROM} --to ${TO} [--cc ${CC}] \
        --reply-to <message-id> --body - <<'BODY'
    ... this file, with placeholders filled ...
    BODY
where <message-id> is a message from the thread being continued (the
original kickoff, or a review reply you are answering). The compose
harness fills templates into `fork-sandbox mail send`, which starts a
new thread: sending this template as a new thread throws away the
earlier round that makes a focused round worth running — the seats
would wake to be told to concentrate on things they cannot see. The
harness refuses --send for a template that carries ${FOCUS} and warns
in print-only mode; the bridge is to compose print-only and send the
leftover body file with the mail reply command above.

Placeholders (dumb substitution -- fill with envsubst or sed, not a
template engine):
  ${FROM}      sending address, e.g. @author
  ${TO}        the seats this round concentrates, e.g. the standing
               crew (see the `lists:` example below) or a narrower set
               of `@agent` addresses
  ${CC}        optional observers -- a Cc'd seat still wakes by
               default to read it (wake-on-cc gates this per agent),
               but no response is requested of it
  ${SUBJECT}   e.g. "[PATCH v2 0/N] <series summary> (focused round)"
  ${FOCUS}     what this round is for, stated by the operator: the
               paths, patches, or questions to concentrate on. This is
               the point of the template; without it the round has no
               reason to exist.
  ${SUMMARY}   optional context -- e.g. which version this round
               answers, and what changed since the last one
  ${HANDOFF}   CI-first wave-one instructions; empty for ordinary rounds
  ${BASE}      the base ref/commit the current version applies on top of
  ${BRANCH}    the branch carrying the current version (branch-name
               variant only)
  ${PATCH_COUNT} number of patches in the current version

Expected fleet.yaml crew for ${TO} -- same as series-review.md; a
focused round is where narrowing the crew pays off (e.g. core + tests
for a correctness focus, core + security for a trust-boundary one):

  lists:
    lkml-panel:
      members:
        - core
        - tests
        - docs
        - architecture
        - newcomer
        - ci

(@security is deliberately not in the standing crew — add it to this
round's To: or Cc: when the focus touches a trust boundary.)

Payload: the branch-name form below; or attach the current version's
patches with `--attach` (repeatable, 4 MiB cap each) if the seats
cannot check it out themselves — both `mail send` and `mail reply`
carry attachments.
-->

${HANDOFF}

This round is for: ${FOCUS}

${SUMMARY}

Base: ${BASE}
Branch: ${BRANCH}
Patches: ${PATCH_COUNT}

You already have the whole thread in your prompt — the earlier round's
review and the responses to it. Nothing here repeats it; this message
only says where to look this round.

Read the current version either by checking out the branch yourself or
from whatever your prompt already carries:

    git fetch origin ${BRANCH}
    git checkout ${BRANCH}

## A focus narrows attention, not standards

This round concentrates the panel on the focus above. It does not
license the panel to ignore the rest: a reviewer asked to look at
error handling who finds a security hole says so, and a Changes-
requested on an unfocused line is still a Changes-requested. A focus
that reads as permission to skip everything else is worse than no
focus at all — a narrowed round that comes back clean while holding
unexamined objections is a false green, not a convergence.

## What's being asked

Review within the focus and reply on this thread with your findings,
in your own voice, plus anything outside it that you cannot look away
from. Silence is a valid outcome: reply only if you have something to
add.

## Sign-off convention

Tag your reply, where applicable:

- `Reviewed-by: <persona>` — you'd stand behind this as committed.
- `Acked-by: <persona>` — the approach is right; you have not verified
  every line.
- `Tested-by: <persona>` — you ran it and it behaved (or say what
  broke).
- `Changes-requested` — something must change before this merges.
- `Question` — you need an answer before you can form a view.
- `NAK` — this must not merge as it stands, with what would change
  your mind.
