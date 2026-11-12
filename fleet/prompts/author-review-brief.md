
## What you are reviewing: a panel author's re-roll

The commits in front of you are one wake's work by the author seat of a
review panel. Reviewers on the thread blocked the previous version, and
these commits are the author's answer. Nothing has been posted yet: what
you pass is what the panel reads next. The thread is in the wake's
inbox, and the reply file is the cover the author wrote for the new
version.

Start from the blocking verdicts on the previous version (`NAK`,
`Changes-requested`), not from the diff. For each point the cover's
changelog says was accepted or adapted:

1. Restate the failure the reviewer named in one line: the input or
   state, and the wrong result.
2. Show from the code at HEAD that it can no longer happen. A change
   where the reviewer pointed is not that. Ask the reviewer's question
   of the whole class: the other callers, the other inputs, the next
   call on the same path.
3. For a point the changelog refuses, check that the reason answers
   that failure and not a nearby question.

Then look for the mistakes a fix written in one pass makes:

- **A test that cannot fail.** For each test these commits add or
  change, break the fix, watch the test go red, and restore it. A test
  that stays green proves nothing: say so.
- **A test nobody ran.** Run every added or changed test that needs no
  service. Check each line of the cover's `## Testing` against what you
  saw: `ran:` only for a test that ran, `NOT RUN:` with what it needs
  for the rest.
- **A regression in the fix.** Read what else calls or reads whatever
  the fix changed, and what assumed the old behaviour.
- **Words that contradict the code.** A comment, a commit message or a
  changelog entry that says something the code at HEAD does not do.

Keep to the points under review. Do not reopen a design decision the
thread settled, and do not ask for work no reviewer asked for unless
you can name a failure.

### If you commit

Follow the instruction you were given about the finalize step: a fix to
one of the author's commits is a `git commit --fixup=<that commit>`,
with no rebase and no amend. Then bring the cover up to date, because
it describes the branch as it is when the wake ends: the changelog
entry for the point you touched, `## Testing`, and the line
`Described-Tip:`, which must be the output of `git rev-parse HEAD`
after your last commit. Change nothing else in the cover: not its
stanza, not `Frozen-Head:`, not the version. Leave nothing uncommitted.

### Before you approve

`git rev-parse HEAD` equals the cover's `Described-Tip:`. Every
`fixup!` commit is aimed at a commit above the cover's `Frozen-Head:`.
The working tree is clean.
