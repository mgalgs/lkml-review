# Judge the feedback a pull request drew after its review panel signed off

## Output contract (read this first)

This is a read-only investigation. Do not commit, and do not change any
tracked file. Your whole deliverable is two files in the artifact outbox
directory your preamble names:

- `verdicts.json` (the schema is at the end of this document)
- `verdicts.md` (the same verdicts as a short readable table plus notes)

Write `verdicts.json` as soon as you have judged your first item, and
rewrite it after each further item. A run that ends early must still
leave every verdict it reached. Scratch files go under `/tmp`, never in
the repository.

## Goal

A panel of AI reviewers reviewed pull request #@@PR@@ ("@@TITLE@@") and
signed off on it. After that sign-off, people and other review agents
left more feedback on the pull request. Decide, for each piece of that
later feedback, whether it describes a real defect that was already
present in the tree the panel signed off on. That tree is your checkout.

Why it matters: every real defect found after the panel signs off is
treated as a bug in the panel, and your verdicts decide which reviewer
instructions get changed. A nit counted as a defect sends the panel
chasing noise. A real defect waved through as a design choice leaves the
gap open. The presence of a comment proves nothing in either direction:
the commenter may be wrong, and a polite short comment may be the most
serious one. Judge the code.

## What you have

- **Your checkout** is commit `@@SHA@@`: exactly the tree the panel
  signed off on (@@TIER@@ tier, version @@VERSION@@, verdict
  @@VERDICT@@, at @@SIGNOFF_DATE@@ UTC). Confirm with
  `git rev-parse HEAD` and say so in your report if it differs.
- @@RESPIN_NOTE@@
- @@BASE_NOTE@@
- `/attachments/pr.md`: the pull request description (as it reads today).
- @@THREAD_FILES@@: the panel's whole review thread up to and including
  the sign-off. Every seat's review, the author seat's covers and
  changelogs, and the secretary's closing summary. This is what the
  panel knew and said.
- `/attachments/feedback.md`: the @@N_ITEMS@@ later feedback items, ids
  `F1`...`F@@N_ITEMS@@`, with replies shown under the item they answer.
- `/attachments/later.md`: the pull request's commit list as it stands
  today. Later commits are evidence of what somebody changed afterwards.
  They are not the tree under judgment, and a fix commit does not prove
  the thing it fixed was a defect.

There is no database, no search cluster and no network. Run code when a
self-contained check settles the question (import a module, call a pure
function, run a snippet against a library the repository vendors or the
environment already has). Otherwise trace the code and cite
`path:line`. Do not build a harness. Spend effort in proportion: a
finding that decides nothing gets a minute, a finding that would be a
serious defect gets a real investigation.

## Method, per feedback item

1. **State the claim** in one sentence of your own. If the item makes
   several independent claims, split it (`F3a`, `F3b`). If two items make
   the same claim, judge it once and mark the other `duplicate`.
2. **Find the code at HEAD.** If the code the comment talks about is not
   in your checkout because it was added after the sign-off, the verdict
   is `not-in-reviewed-tree`, unless the same defect already existed at
   HEAD in another form, in which case judge that.
3. **Decide whether the claim is true at HEAD.** Reproduce it, or trace
   it and cite the lines. Say which you did. If you cannot settle it, say
   so (`unresolved`) and say what would settle it; do not guess.
4. **Classify** (definitions below).
5. **Check what the panel did with it.** Search the thread files for the
   function, file, symbol and failure the item is about, in more than
   one wording. Say whether a seat raised it, and what became of it.
6. **For a real defect, say whose code it is.** Run `git blame` (or
   `git log -S`) on the defective lines at HEAD. A commit authored by
   `fork-sandbox agent <agent@fork-sandbox.invalid>` is the panel's own
   code, written by its author seat. Any other author within the pull
   request's range is the pull request author's code. Code that predates
   the pull request is `pre-existing`.

## Verdicts

- `real-defect`: at HEAD there is a concrete input, state or sequence of
  events that produces a wrong result, a crash, lost or corrupted data,
  a security exposure or an operational failure. Also: a factual claim
  in the pull request description, a doc or a code comment that is false
  in a way that would mislead someone deciding to merge or operate this;
  and a test that cannot fail or asserts the wrong thing while claiming
  to cover a behaviour. You must name the failure scenario. Give a
  severity: `high` (data loss, security, an outage or a wrong result in
  the main path), `medium` (a wrong result or failure in a real but
  narrower case), `low` (real but minor, cosmetic consequence).
- `design-disagreement`: the code does what its author intended and the
  commenter prefers another design, where both are defensible. This
  includes a choice the panel considered and made on purpose. If the
  chosen design has a concrete failure the panel did not weigh, that is
  a `real-defect`, not a disagreement.
- `nit`: style, naming, wording, formatting or a project convention,
  with no effect on behaviour or on a reader's decisions.
- `not-knowable`: a real problem that could not have been found from
  this tree and the pull request's own materials at review time: it
  depends on production data or scale that nothing here states, on a
  change merged concurrently, or on an outside system's undocumented
  behaviour. Be strict. If a careful reviewer holding this tree and the
  pull request's own evidence could have asked the question or run the
  check, it was knowable.
- `not-in-reviewed-tree`: about code added after the sign-off (step 2).
- `not-a-finding`: a question that was answered with no change needed,
  praise, status, merge mechanics, process chatter, an approval.
- `duplicate`: same claim as another item (name it).
- `unresolved`: you could not settle it; say what would.

## Panel coverage (for every item that is not `not-a-finding`)

- `missed`: no seat raised it.
- `raised-and-dropped`: a seat raised it, and it was neither fixed nor
  ruled on (handed to another seat's lane, waved off as out of scope
  with the failure unanswered, or lost between versions).
- `raised-and-decided`: a seat raised it and the pull request's human
  author, or a ruling on the thread, decided against it with a reason.
- `raised-and-fixed-short`: a seat raised it, a fix was made, and the
  fix did not cover what the later feedback found.
- `predicted`: a seat told the humans to check exactly this before
  merging or running it.
- `n-a`.

Quote the message ids (the thread files print `id <uuid>`; the first 8
hex digits are enough) for anything other than `missed`.

For a `real-defect` that was `missed`, also say in one or two sentences
what a reviewer would have had to do to find it (the question to ask or
the check to run), and which seat's job that was. The seats: `@core`
(correctness, hunts bugs, highest bar), `@tests`, `@architecture`,
`@security`, `@docs`, `@operability`, `@newcomer`, `@devils-advocate`,
`@second-opinion`, `@pr-author` (the panel's author seat, which wrote
the panel's commits), `@secretary` (writes the closing summary). Not
every panel has every seat; this panel's roster was: @@ROSTER@@.
If the seat whose job it was is not on that roster, say so.

## `verdicts.json`

```json
{
  "pr": @@PR@@,
  "reviewed_sha": "@@SHA@@",
  "head_matches": true,
  "findings": [
    {
      "id": "F1",
      "claim": "one sentence",
      "verdict": "real-defect",
      "severity": "medium",
      "true_at_head": true,
      "how_checked": "reproduced | traced | read",
      "evidence": "what you ran and what it printed, or the path:line trace; a few sentences",
      "failure_scenario": "the input or state and the wrong outcome (real-defect only)",
      "panel_coverage": "missed",
      "panel_refs": ["0a1b2c3d"],
      "code_owner": "human | panel | both | pre-existing | description | n-a",
      "blame": ["<12-hex sha> <author> <path>:<line>"],
      "gap": "what a reviewer would have had to do to find it",
      "seat": "@core",
      "seat_on_roster": true,
      "confidence": "high | medium | low",
      "duplicate_of": null
    }
  ],
  "notes": "anything the reader must know: a head mismatch, evidence you could not open, an item you split"
}
```

Use `null` for fields that do not apply. Every `F` id in
`/attachments/feedback.md` must appear (or be covered by a `duplicate`
or a split).

## Report

End with a final message of at most eight lines: how many items, the
count per verdict, each `real-defect` in one line (id, severity, code
owner, panel coverage), and anything you are unsure of.
