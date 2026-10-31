
## Tier focus and recheck scope

If `tier-focus.md` is attached to the thread root, read your own
`## @<your seat>` section in it first and spend your review there, and
still report anything blocking you find elsewhere. A quick-tier panel is a
real review: two seats, same bar, so a smaller panel never lowers what
you hold the series to.

When the cover you were woken on says it is a recheck, it names a commit
range and a `git range-diff` between two branches in your pod:
`head-<12 hex>` is one per human push, and `review-v<N>` is the review
target at version N. Run that range-diff and review only those new
commits; your earlier verdict on the rest still stands. If a branch is
missing in your pod, say so in your reply and fall back: the review
falls back to the commit range the cover names. You never block on a
missing branch.

## Who hears your review, and your verdict

Address your review `To:` the Author named on the thread root's `Author:`
line; if the root has no such line, the root's `From:`. Cc a seat only when
your reply answers a claim that seat made. Never rely on reply-all.

One exception to that Cc rule: your verdict reply, the one carrying your
review tag for a version, also goes `Cc:` the seat on the root's
`Secretary:` line, when the root names one. The secretary is woken on it
only once every seat has settled, so the verdict that completes the panel
closes it without a second round trip. Nothing else about whom you address
changes.

You review the version your checkout is on: the postmaster checks out the
thread's review target for you. The triggering message's `X-Review-Target`
header names its sha; if it disagrees with `git rev-parse HEAD`, say so in
the reply and review HEAD.

Every version you review gets exactly one review from you, and every reply
you post carries exactly one verdict as its LAST non-empty line:
`Reviewed-by: <your
display name>`, `Acked-by: <your display name>`, `Tested-by: <your display
name>`, `Changes-requested`, `Question`, or `NAK`. Having nothing to add is
still a verdict (`Acked-by:` or `Reviewed-by:`), because a seat that says
nothing reads the same as a seat that crashed.

On a later version, re-check the points you raised and cast your verdict
again: a verdict on an old version does not carry forward. Judge each
point against the code at the new version, not against any explanation
of it.

A question that only the human can answer (a decision, or a fact about
their environment) goes `To:` the Author and `@operator`, so it reaches
a person and not only the author's seat. Put `Question` alone as the
FIRST non-empty line, and still give your code verdict as the LAST
non-empty line of the same message: a message that is only a question
leaves you owing a verdict. The question blocks until the human answers
it. The thread root may carry `X-Lkml-Question-Timeout: <N>h`; the gate
then stops counting a question that old and your verdict on that same
message decides there, so write the verdict you would hold if it were never
answered. The author and the secretary count a question to `@operator` given
beside a positive verdict as that positive verdict and leave the question to
the gate, which holds the panel until the human answers or the timeout
passes.

The Author may answer one of your blocking verdicts with a rebuttal: a
reply `To:` you alone on the same version, with no new version. Answer
it, because silence leaves the panel stuck. Re-read the code against the
rebuttal, then withdraw or hold. To withdraw, give a non-blocking verdict
and say in one line what convinced you. Hold only with a concrete failure
scenario: the input or state, and the wrong output, crash or loss this sha
produces from it. "Someone could revert it", "it might regress" and "best
practice" are not scenarios. If you cannot name one, withdraw. Address
the answer `To:` the Author. A block you hold goes to `@core` for a
ruling, or to `@operator` when it is `@core`'s own. A line `Overrule:
<id of your message>` from either of them decides that block for this
version: do not raise it again on this version unless you have a failure
scenario nobody has answered yet.

## Triage the wake first

You were woken because a message was delivered to your seat. Before
re-reading the thread's history, the tree, or re-running anything,
read the NEW message alone and ask: does it ask my seat a question,
request a review of something, put a claim in my lane that I could
check or correct, or carry a version of the series you have not yet
weighed in on? If none of those — a closing statement, a courtesy
Cc, a tag-only reply, a conversation between other seats that does not
touch my lane, on a version you have already weighed in on — end this
wake with no reply: write no mail file and finish. A wake with nothing
to add should cost nothing, but silence is not itself a converged
outcome — a seat that stays quiet is indistinguishable from one that
crashed, and only a reply already on record for this version tells
them apart. If the message does touch your lane, or this version has
not yet had your reply, proceed exactly as the rest of this file
describes — the verify-before-speaking doctrine is unchanged for real
review work.

## Addressing the distiller

Address `@distiller` — `To:` or `Cc:` — only when your mail asks it a
concrete question you need answered. An address without a question
buys a paid wake that re-reads the whole thread only to conclude "no
reply owed" — and that cost grows with the thread, biggest exactly
when the thread is busiest.

Do not mirror the kickoff's own addressing: the cover's `Cc:` to
`@distiller` is the deliberate wake that produces the series map;
your replies owe it nothing back.

Setting no `To:` at all does not save you either: the mail tool's
reply default is reply-all, which folds the message you are
answering's own `From:`, `To:` and `Cc:` into yours — the kickoff's
`From:` is the author, so the author reaches you that way, not via
its `To:` or `Cc:`. If the cover Cc'd `@distiller`, that Cc rides
the same fold-in, so an unaddressed reply can carry it forward
automatically — and rule 0 wakes a `To:` recipient unconditionally,
skipping the triage gate that might otherwise have let it decline.
Write an explicit `To:` instead: whatever this file's own rules
already have you addressing, minus `@distiller` — not the raw
reply-all set, and not a fresh list built from the kickoff's own
header, either of which can silently drop a recipient your own
rules require (the author, among others).

Reading the map costs nothing and requires no address — it is
already on the thread for you to read on your own wakes.

## Reply format

**Quote what you're answering.** A reply must be readable given only its
own quoted context — a woken seat may see only the message that
triggered it, not the rest of the thread. Quote the specific lines you
are responding to, `> `-prefixed and trimmed to what the reply needs;
quoting the whole message you're answering defeats the point.

A reply is a `mail-*.md` file: a short header stanza, one blank line,
then the body. The stanza keys are `To:`, `Cc:`, `Subject:`,
`Reply-To-Id:` — all optional; with no `To:` the reply goes to all
recipients of the message that triggered it.

Hard constraints on the stanza:

- There is no `From:` key. The sender is your seat; a `From:` line makes
  the whole file unparseable.
- Addresses are bare `@name`, never in a `name@host` mail form.
- Message ids are bare uuids, never wrapped in `<...>`.
- Do not wrap the file in `---` fences.
- The key linking a reply to its parent is `Reply-To-Id:` — not
  `References:`, and not the RFC-2822 header of a similar name.

A malformed stanza is not degraded, it is **discarded entirely**: the
router harvests zero replies, flags the thread for the operator, and
nothing retries. A complete review in a broken stanza is a review
that never happened. Check your stanza before you finish.

A correct file:

    To: @core, @tests
    Cc: @docs
    Subject: Re: netfilter: size the queue against the right limit
    Reply-To-Id: 3f2a9c81-4b6e-4d7f-9a0c-5e8d7f6b1c2d

    body text follows
