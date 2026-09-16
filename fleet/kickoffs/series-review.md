<!--
Kickoff template: start a full-panel review of a patch series.

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
  ${SUBJECT}   e.g. "[PATCH v1 0/N] <series summary>"
  ${SUMMARY}   one paragraph: what the series does and why
  ${HANDOFF}   CI-first wave-one instructions; empty for ordinary kickoffs
  ${BASE}      the base ref/commit this series applies on top of
  ${BRANCH}    the series' own branch name (branch-name variant only)
  ${PATCH_COUNT} number of patches in the series

Expected fleet.yaml crew for ${TO} (author and secretary are not part
of the review-kickoff `To:` -- the author is this mail's `From:`, so
reviewers' reply-alls land in the author's `To:` and wake it to
answer; the secretary is invoked solo,
later, once review replies are in -- see fleet/personas/secretary.md):

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
kickoff's To: or Cc: when the series touches a trust boundary. Keeping
the expensive seats out of the default crew is the cost throttle.)

Payload: pick ONE of the two variants below and delete the other.

  Variant A -- attachments. Format the series first:
      git format-patch ${BASE}..${BRANCH} -o <tmpdir>
  then pass each file as its own `--attach <file>` (repeatable, 4 MiB
  cap each). Good when reviewers' sandboxes do not already have the
  branch.

  Variant B -- branch name in the body (below). Good when every
  reviewer's sandbox is a clone of the same repo and can check the
  branch out itself; nothing to attach, nothing to stage.
-->

${HANDOFF}

${SUMMARY}

Base: ${BASE}
Branch: ${BRANCH}
Patches: ${PATCH_COUNT}

Read the diff either from the attached patches (if this message carries
any) or by checking out the branch yourself:

    git fetch origin ${BRANCH}
    git checkout ${BRANCH}

## What's being asked

Read the series and reply on this thread with your findings, in your
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

## Next version

v2 goes out as a reply to this thread, with a changelog answering
review comment by comment and the v2 patches inline in the body, one
fenced code block per patch, each headed by its filename. Reviewer
sandboxes cannot fetch branches, and a wake's reply cannot carry
attachments, so the inline copy is the review copy — a version named
only as a branch is a version nobody on this thread can read.
