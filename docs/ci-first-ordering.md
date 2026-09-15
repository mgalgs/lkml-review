# CI-first ordering as an address graph

Answers the `TODO(fleet)` in `fleet/personas/ci.md`, and the "drops the old
CI-first ordering guarantee" note on `lkml-round.sh`'s row in
`docs/RETIRED.md`.

Written for whoever builds it, so it can be read instead of re-derived.

## The gap

The old pipeline ran the `ci` seat first on every new version, before any
other reviewer reasoned about the code. Under the fleet model a kickoff's
`To:`/`Cc:` *is* the fan-out, and spawn-on-delivery wakes everyone addressed
at once, so there is no scheduler left to hold an ordering in.

The obvious fix -- re-grow a scheduler that runs one seat before the others
-- is the wrong shape. It puts back exactly the component the fleet model
removed, to restore a guarantee the model can already express.

## Why the ordering is worth keeping

It is not about tidiness, and it is not "CI is important." It is about what
a reviewer asserts when the facts are absent.

`ci` is the only seat that executes rather than reasons. Every other seat
reads a diff and predicts. A reviewer who has traced a path and expects it
to work will say so with the same confidence as one who ran the suite, and
the thread cannot tell those apart -- both are prose from a persona with a
model name attached.

So a panel woken without test results produces opinion first and correction
second. That costs a round, which is the cheap part. The expensive part is
that the superseded opinion stays in the archive at equal visual weight
forever, and the next reader -- human or seat -- has to reconstruct which
claims were made before the numbers landed.

Worked example, from a real series: `ci` opened with a NAK, 39 red out of
2787 tests. The correct reading was "environment red, series green" -- the
series changed no Python at all, so it could not have broken a Python test.
That conclusion is only available to someone holding the test output. A seat
reasoning from the diff alone would either not raise it, or raise it as a
guess. Every later message on that thread was shaped by the numbers being
there first.

## The shape: two waves, expressed as addresses

Do not order the seats. Order the *mail*.

1. **The kickoff addresses only `ci`.** Not the panel.
2. **`ci`'s reply addresses the panel.** Its `To:` carries the reviewer
   seats, and delivery wakes them the way delivery always does.

Ordering stops being a scheduler feature and becomes a property of the
address graph -- which is the thing the transport already honours. Nothing
new has to exist.

## Preconditions (verified, not assumed)

All three confirmed before this was written, against **fork-sandbox's**
`docs/agent-mail.md` — the transport's own documentation, which lives in that
repo rather than this one. Every other path named here (`fleet/personas/ci.md`,
`docs/RETIRED.md`, `lkml-round.sh`) is local to this repo.

- **A reply may address seats the kickoff did not.** The reply stanza's
  `To:` is optional and defaults to reply-all, but it is free-form and is
  not constrained to the trigger's participants. So `ci` can name the panel.
- **Routing rule 0 expands a reply's `To:` like any other message's**, and
  every expanded name that resolves as a fleet agent is a wake candidate.
  There is no subset restriction and no "already on the thread" condition.
- **A seat cannot wake itself.** Rule 0 excludes a message's own `From` as a
  candidate, even via a list. So the second wave is exactly the panel, with
  no self-wake to suppress.

## Two properties this gains over the thing it replaces

- **The panel wakes with the whole thread.** Every wake carries the thread,
  so reviewers get the kickoff *and* the CI results in one prompt. The old
  guarantee only promised the numbers were on the thread by the time they
  looked; this puts them in the same prompt as the diff.
- **It fails in the safe direction.** If `ci` dies, its reply is never sent,
  so the panel is never addressed and nobody reviews blind. Under a
  scheduler the equivalent failure wakes five seats against a version
  nothing ran.

## The cost: one extra hop, and it must be compensated

**This is a required part of the pattern, not a caveat.**

Hops decrement per reply. The two-wave graph inserts one reply before the
panel ever speaks, so everything downstream is shifted by one: `ci`'s reply
is `kickoff - 1`, and the panel's replies are `kickoff - 2`.

The default is 8 on a new thread, so an ordinary single-version panel is
unaffected. The thing that hits the floor is a long revise/re-review series
-- exactly the case this whole mode exists for -- and it hits it one round
earlier than whoever set the number expected.

The failure mode is what makes this worth stating loudly: the thread is
flagged needs-operator with `hops exhausted`. Nobody reads that and thinks
about the fan-out shape. The person who hits it is four versions deep,
debugging a review that stopped, and the address graph is the last place
they will look.

**Compensation: pass `mail send --hops` on the kickoff, raised by at least
one over whatever the series would otherwise want.** Anyone adopting the
two-wave shape adopts the hops bump with it. If the two are ever separated
-- a template that does one but not the other -- the result is a series that
works for three versions and then stops for reasons that look unrelated.

**It has to be the kickoff, because there is no way to raise hops later.** A
reply copies its parent's `X-Hops` verbatim -- that is true of an operator's
reply too, not just a seat's -- so mailing into an exhausted thread re-arms
it (the operator reset clears needs-operator and zeroes the spawn count) but
does *not* give it more hops. The only remedy after the fact is a fresh
thread, which means re-posting the version and abandoning the archived
discussion. So this is not "remember to pass the flag" advice; the flag is
the single moment at which the number can be chosen at all.

## What this does not solve

- **It orders `ci` against the panel, and nothing else.** Any other
  ordering constraint someone wants later (`security` before `newcomer`,
  say) needs its own justification; this is not a general priority
  mechanism and should not be grown into one.
- **It does not make `ci` authoritative.** A NAK from `ci` still needs a
  human or an author seat to weigh it. Putting the numbers first makes the
  panel's reasoning better informed; it does not make the numbers correct.
  The worked example above is a case where the NAK was real output and the
  right response was to contest it, not to fix anything.
- **It says nothing about seats that need services** — and that is a
  precondition of the shape, not a footnote to it. Read the next section
  before implementing any of the above.

## The precondition: a repo where `ci` cannot run at all

The two-wave graph assumes the `ci` seat exists and executes. Where it does
not, the shape does not degrade -- it stops.

An earlier version of this document treated only the weak form: a `ci` seat
that cannot reach a populated environment produces environment-shaped red,
and ordering that red first only means the panel is well-informed about the
environment. True, and not the case that bites.

The case that bites is the strong form, reported from real use. For a repo
whose suite needs postgres, opensearch and redis, `ci` cannot run in a
sandbox at all, and the operator drops the seat from the panel. Under the old
scheduler, a panel with no `ci` seat simply reviewed without test numbers.
Under the two-wave graph **the kickoff addresses only `ci`** -- so with the
seat dropped the kickoff addresses nobody, no reply is ever sent, the panel
is never addressed, and no seat wakes.

**The whole panel silently does not start.** Not an error: hops are intact,
the mailbox is well-formed, nothing failed. It looks exactly like a round
that has not got going yet, which is the most expensive shape a failure can
have -- and it is strictly worse than the ordering gap this document exists
to close. So it is a gate on adopting the shape, not a caveat beside it:

> **Before addressing a kickoff to `ci` alone, establish that `ci` will run
> in this repo.** If it will not, do not adopt the two-wave graph there until
> one of the answers below is in place.

Two answers, and it is a real fork rather than a detail:

- **A services-backed `ci` seat** -- give the seat the stack its suite needs,
  so it executes for real. Strongest, because it preserves the property that
  makes `ci` worth ordering first at all: it is the only seat that executes
  rather than predicts. Costs a per-seat environment.
- **An explicit "tests were run elsewhere" injection** -- no `ci` seat runs;
  the kickoff itself carries test results produced somewhere that has the
  services, with their provenance stated. Cheaper, and honest so long as the
  evidence says where it came from. The numbers are then as old as their
  source, which the panel must be able to see.

A third option that is **not** on the list: addressing the kickoff to the
panel directly when `ci` is absent, "just for this repo." That silently
restores the ordering this document exists to fix, and does so in the repo
least able to notice -- nobody there has seen a wave-one message to miss.
