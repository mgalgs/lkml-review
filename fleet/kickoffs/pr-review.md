<!--
Kickoff template: start a panel review of an open pull request, run
entirely by the personas. There is no orchestrator between rounds: the
author seat (fleet/personas/pr-author.md) decides on every wake whether
the panel is still reviewing, has converged, or needs a re-roll, and the
secretary (fleet/personas/secretary.md) closes the thread.

Send with `lkml-fleet-kickoff.sh --template pr-review --review-target
<branch>:<sha> ...`, which fills every placeholder below: the roster
from pr-review.roster (or --author/--panel/--secretary/--version-limit),
${FROZEN_HEAD} from the --review-target sha. docs/cluster-panel.md walks
through the whole flow.

Placeholders (dumb substitution, not a template engine):
  ${FROM}          sending address (not the Author: reviewers address
                   the seat named on the Author: line, not this mail's
                   From:)
  ${SUBJECT}       e.g. "[PATCH v1 0/N] <series summary>"
  ${AUTHOR}        the author seat's address, e.g. @pr-author
  ${PANEL}         the reviewing seats, comma-separated @addrs, e.g.
                   "@core, @tests, @docs". This is also the kickoff's
                   `To:` -- one list, so the roster and the recipients
                   cannot drift apart
  ${SECRETARY}     the secretary seat's address, e.g. @secretary
  ${VERSION_LIMIT} the highest version the author may post before it
                   must ask the secretary to close the panel as it
                   stands, e.g. 4
  ${FROZEN_HEAD}   the 40-hex sha of the PR's head commit: everything up
                   to and including it belongs to the PR's human author
                   and is never rewritten
  ${SUMMARY}       one paragraph: what the PR does and why
  ${BASE}          the base ref/commit the PR applies on top of
  ${BRANCH}        the PR's branch name
  ${PATCH_COUNT}   number of commits in the PR

Do not Cc anyone and do not put the author or the secretary in `To:`.
The author wakes on each review it receives; the secretary is woken
by the author, once, when the panel has converged or the version limit
is reached; its summary goes to the operator and wakes nobody.

The thread's review target is set to the PR head as version 1 by
whatever posts this kickoff; every reviewer's checkout is at that
target, so there is no branch to fetch and no per-patch message to post.
-->

Author: ${AUTHOR}
Panel: ${PANEL}
Secretary: ${SECRETARY}
Version-Limit: ${VERSION_LIMIT}
Frozen-Head: ${FROZEN_HEAD}

${SUMMARY}

Base: ${BASE}
Branch: ${BRANCH}
Patches: ${PATCH_COUNT}

Your checkout is already at the version under review: for v1 that is the
PR's head. Read the code there, for example:

    git log --oneline ${BASE}..HEAD
    git diff ${BASE}..HEAD

## What's being asked

Every seat on the `Panel:` line above replies once per version, `To:`
the Author named on the `Author:` line, and ends that reply with exactly
one verdict line (below) as its last non-empty line. Silence is NOT a
valid outcome here: the author acts only once every panel seat has
replied on the current version, and a seat that says nothing is
indistinguishable from one that crashed. If you have nothing to add,
say so with `Acked-by:` or `Reviewed-by:`.

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

`Reviewed-by:`, `Acked-by:` and `Tested-by:` are non-blocking.
`Changes-requested`, `Question` and `NAK` are blocking. The panel has
converged only when every seat's latest verdict on the current version
is non-blocking.

## Next version

If any seat blocks, the Author posts the next version as one cover
reply to this thread: a changelog answering review point by point, a
`## Since v<N>` range-diff, and a new `Version:`. There are no per-patch
messages; your checkout moves to the new version's sha. Review that
version and cast a fresh verdict: a verdict on an old version does not
carry forward. If the panel is still blocked when the version limit
above is reached, the Author stops and asks the Secretary to close the
panel with what still blocks.

The Secretary's summary is the last message on the thread. It goes to
the operator; do not reply to it.
