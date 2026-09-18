<!--
Kickoff template: start a review of a single patch (the small variant
of series-review.md -- one commit, no cover letter, no changelog
section, otherwise the same convention).

Send with something like:
    fork-sandbox mail send --from ${FROM} --to ${TO} [--cc ${CC}] \
        --subject "${SUBJECT}" --body - <<'BODY'
    ... this file, with placeholders filled ...
    BODY

Placeholders (dumb substitution -- fill with envsubst or sed, not a
template engine):
  ${FROM}      sending address, e.g. @author
  ${TO}        the review crew, e.g. @lkml-panel (see the `lists:`
               example below) or a comma-separated set of `@agent`
               addresses
  ${CC}        optional observers -- a Cc'd seat still wakes by
               default to read it (wake-on-cc gates this per agent),
               but no response is requested of it
  ${SUBJECT}   e.g. "[PATCH] <one-line summary of the change>"
  ${SUMMARY}   one or two sentences: what the patch does and why
  ${HANDOFF}   CI-first wave-one instructions; empty for ordinary kickoffs
  ${BASE}      the base ref/commit this patch applies on top of
  ${BRANCH}    the branch carrying the single commit (branch-name
               variant only)

Expected fleet.yaml crew for ${TO} -- same as series-review.md; for a
small patch a narrower crew is often enough (e.g. core + tests, or
core + security for anything touching a trust boundary):

  lists:
    lkml-panel-small:
      members:
        - core
        - tests

Payload: pick ONE of the two variants below and delete the other.

  Variant A -- patch message. Post this cover with `fork-sandbox mail
  send`, then post ONE `fork-sandbox mail reply --to @operator
  --reply-to <cover-id>` whose body is the patch's own
  `git format-patch` output (`lkml-fleet-kickoff.sh --patches` does
  this for you). Good when the reviewer's sandbox does not already
  have the branch.

  Variant B -- branch name in the body (below). Reviewer sandboxes
  check the branch out themselves; nothing to post per patch.
-->

${HANDOFF}

${SUMMARY}

Base: ${BASE}
Branch: ${BRANCH}

Read the diff either from the patch message on this thread (posted
separately, if this round used --patches) or by checking out the
branch yourself:

    git fetch origin ${BRANCH}
    git checkout ${BRANCH}

## What's being asked

Read the patch and reply on this thread with your findings, in your
own voice and focus. Silence is a valid outcome: reply only if you
have something to add.

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

The colon after the three `-by` trailers is load-bearing: a trailer
without it does not register. A trailer must start its own line at
the left margin, with no leading whitespace — a trailer that is
indented (under a bullet, for instance) or embedded mid-prose does
not count. A bare verdict (`Changes-requested`, `Question`, `NAK`)
registers only on the first or last non-empty, non-quoted line of
the body. Recommended form: your verdict as the FIRST line of the
body, and the trailer block as the last lines. (A trailer block
ends most replies, so a last-line verdict and a trailer block
collide; a first-line verdict also gives a reader the decision
immediately. If you open with a salutation instead, your verdict
is not on the first line and will not register there.)

## Next version

A fix goes out as one cover reply to this thread, followed by ONE
patch message (`[PATCH v2 1/1] ...`, addressed `To: @operator` so it
sits on the thread without waking anyone) carrying the revised patch.
Reviewer sandboxes cannot fetch branches, and a wake's reply cannot
carry attachments, so the patch message is the review copy.
