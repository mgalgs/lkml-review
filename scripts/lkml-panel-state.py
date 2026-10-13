#!/usr/bin/env python3
"""lkml-panel-state.py — where does a fleet-transport review panel stand,
as one machine-readable JSON object.

Usage: lkml-panel-state.py <thread-id> [--remote] [--now <ISO-8601>]
       lkml-panel-state.py --export-file <f> --status-file <f> [--now <ISO-8601>]
       lkml-panel-state.py -h|--help

The first form runs, as subprocesses (argv lists, never a shell):

    fork-sandbox mail [--remote] export <thread-id> --json
    fork-sandbox postmaster [--remote] status --thread <thread-id> --json

The second form reads the same two documents from saved files ('-' is
stdin, for at most one of them). BOTH inputs are required: no mode
computes anything without the postmaster's view of the thread.

Output is one compact JSON object on stdout, then a newline. Exit 0
whenever an object was produced, whatever it says; 1 on an input failure
(a subprocess failed, JSON unparsable or the wrong shape, the two inputs
name different threads) with a one-line "Error: ..." on stderr and
nothing on stdout; 2 on a usage error. Python 3 stdlib only. It is a
READER: it writes nothing anywhere, and caches nothing.

Why this exists, and the rule that decides every ambiguous case: the
failure mode of this tooling is the FALSE GREEN. A seat that went quiet
reads identically to a seat that agreed unless a positive signal is
demanded. So a panel is CONVERGED only when every panel seat holds a
positive verdict on the CURRENT review target, and anything missing,
stale, contradictory or unreadable pushes the answer AWAY from
CONVERGED, with a reason string saying why. Every string in "reasons" is
a condition that blocks CONVERGED; a CONVERGED object has none.

This is the judgment layer. lkml-fleet-status.sh is the human screen
that deliberately never judges convergence; it is untouched, and the tag
rules below are its rules, matched exactly (tests/lkml-panel-state-test.sh
feeds the same bodies through both and compares).

Roster -- read from the thread root (the message with the lowest seq).
Each line alone on its line, whitespace around it ignored, keys
case-sensitive, the first occurrence of a key wins:

    Author: @pr-author
    Panel: @core, @tests, @docs
    Secretary: @secretary
    Version-Limit: 4
    Frozen-Head: <40- or 64-hex sha>
    Suite: <command>
    Suite-Seats: @tests[, @other]

An address must match ^@[a-z0-9][a-z0-9-]*$; a malformed one is dropped
with a reason (and, being a reason, blocks CONVERGED: a seat silently
dropped from the panel is a seat nobody waits for). A missing or empty
Panel means the roster is unusable.

Suite -- the exact command the repository under review says its suite
seats must run. Its value must be non-empty once stripped; an empty one
is malformed: a reason, and the root is read as having no Suite line
(never as a Suite that is present and satisfied). Suite-Seats lists the
panel seats that must run it, comma-separated, each an address. It only
means something with a Suite: without one it is a reason. With a Suite
and no Suite-Seats line the suite seats default to @tests when @tests is
on the panel; otherwise there are none, which is a reason ("Suite: set
but no Suite-Seats and @tests is not on the panel"): a suite nobody must
run is a gap, not a pass. A Suite-Seats entry not on the panel is a
reason and is dropped, and so is a Suite-Seats line that leaves no seat.
roster.suite_seats is the RESOLVED list ([] with no Suite).

Tier -- the root's `X-Lkml-Tier: quick|standard|full` header says how big
a panel the CI side chose for this thread, and `X-Lkml-Tier-Reason` (one
line) why. The top-level "tier" is {"name","reason","source","message_id"},
all null when the root carries neither. Exactly one distinct tier value,
spelled exactly; anything else leaves name null and is a reason (a tier
nobody can read is not a smaller panel, it is no claim at all). The reason
is display text: its first line, at most 200 characters, never a reason of
its own. The tier does not change who must answer: that is the roster
(`Panel:`), and a smaller tier is a smaller NAMED roster, never "fewer
seats happened to answer".

Pushes and push modes -- the postmaster's upstream-moved mail (the one
stamped `X-Upstream-Head`, sent when the human pushes to the PR) may say,
in `X-Lkml-Push-Mode`, how the CI side wants the push handled:

    carry      every seat's latest verdict carries forward unchanged
    recheck    `X-Lkml-Recheck-Seats: core, tests` -- the author posts the
               new version to those seats only; the rest carry forward
    escalate   `X-Lkml-Tier: <tier>` and `X-Lkml-Add-Seats: security` (may
               be empty) -- the roster grows by the added seats, the tier
               ratchets, and every seat needs a fresh verdict
    (absent)   as always: every seat needs a fresh verdict

A mode is identified by the header alone, never by the mail's recipients:
a carry mail is addressed to @operator so that it wakes nobody, and being
addressed to the operator it must not be read as a question to them.
Seat tokens may be bare (`core`) or addressed (`@core`).

Every upstream-moved mail is a "push" record: {"seq","message_id","sha",
"branch","mode","seats","tier","malformed","answered"}. mode is null when
the mail names none, or when what it names is malformed (and malformed
then holds the text). A malformed push mode is treated as ABSENT -- every
seat owes a fresh verdict -- and reported as a reason, never honoured:

  * several distinct modes, or one that is not carry, recheck or escalate
  * recheck with no X-Lkml-Recheck-Seats, or one that leaves no seat on
    the panel (a token that is not on the panel, or malformed, is dropped
    with a reason, and the others are honoured)
  * escalate with no usable X-Lkml-Tier, or one BELOW the tier in force:
    the tier only ratchets up within a thread (naming the same tier, to
    add seats, is fine)
  * a push mode on a message with no parseable X-Upstream-Head: only the
    postmaster stamps that header, and any seat can set an X-* header, so
    it is ignored with a reason

A valid escalate sets the tier in force (tier.source "escalate"; its
X-Lkml-Tier-Reason replaces the root's when it has one) and appends each
not-yet-seated X-Lkml-Add-Seats token to the effective roster: the
top-level "panel" is the root's `Panel:` plus every added seat, in order.
roster.panel stays the root's own. Every seat in "panel" owes a positive
verdict; a seat nobody listed on the root but escalated in is a seat like
any other. Top-level "push" is the newest push record, with "answered":
true when its sha is the current target's frozen head; null when the
thread has no push.

Carry -- a verdict is only ever CARRIED from a verdict the seat actually
gave, on an earlier version of the same thread; a carried blocker is still
a blocker, and a seat with nothing to carry still owes a verdict. Carry
never rewrites anything. Two shapes:

  * A carry version. When every push since the current posted version is a
    carry and the newest is not already that version's frozen head, the PR
    is on a synthetic version: a carry does NOT move the postmaster's
    review target (only the author's post does), so target and frozen head
    are both taken from the newest push's X-Upstream-Head. target.source is
    "carry", target.version is the posted version plus one per push since
    (every human push counts toward Version-Limit, whatever its mode; this
    script only numbers them), set_by/set_at are the push's. The frozen
    head is {sha, "upstream"}, so a panel that carries to convergence is
    SIGNED-OFF at the new head. No push is unanswered on it. Every seat's
    latest verdict, and the secretary's trailer (nobody is woken, so no
    fresh one can exist), carry from the posted version. A carried RESPIN
    therefore contradicts a carry version (target == frozen head) and
    blocks CONVERGED, like any other RESPIN on a frozen head.
  * A posted version that answers a push. The author's version answers a
    push when it is the first post after it and its resolved frozen head
    is the push's stamped head; every push since the previous version then
    counts. A seat carries forward from the previous version unless some
    push in that interval withholds it: recheck withholds the seats it
    lists, escalate and a push with no (or a malformed) mode withhold
    every seat. The secretary's trailer is NOT carried here: a posted
    version needs a fresh one.

Carrying chains: a seat that carried onto a recheck version carries through
a later carry push the same way, because its verdict on the earlier version
is what the recheck said still stands. The push modes are decided CI-side
(`carry` is only correct for a pure rebase, which CI checks from
patch-ids); this script trusts the header and does not recompute it.

Frozen head -- the commit the human's PR stood on when a version's review
began, which decides what a sign-off means. roster.frozen_head is the
ROOT's value and keeps that meaning. The top-level "frozen_head"
({"sha", "source"}, null when unknown) is the frozen head of the CURRENT
target, resolved so:

  1. The candidate is the `Frozen-Head: <sha>` line (same line rules as
     the roster: alone on its line, whitespace ignored, the first
     occurrence wins, 40- or 64-hex) of the newest message FROM the
     roster's Author whose X-Review-Target-Set sha is the current
     target's: the cover that set this version. A malformed line is
     ignored, with a reason.
  2. A candidate equal to the root's frozen head -> source "root".
  3. Any other candidate is accepted only if a message with a LOWER seq
     than that cover carries an X-Upstream-Head whose sha equals it
     (source "upstream"). That header is stamped by the postmaster when
     the human author pushes a new head to the PR; nobody else can
     forge it. This is the anti-false-green gate: the author is a model
     and must not be able to declare its own commits "frozen" and so
     earn a SIGNED-OFF. An unvouched candidate is a reason, and the
     frozen head falls back to the root's (source "root").
  4. No candidate -> the root's value (source "root"), else null.

Before any of that: a target the postmaster re-froze is its own frozen
head (source "upstream"). When a force-push orphans a version before any
seat has replied on it, the postmaster moves its review_target to the
pushed head in place, keeps the version, sets set_by to @postmaster and
sends no mail, so no cover names the new sha. Its say-so alone is not
enough: the re-freeze counts only when a message's stamped
X-Upstream-Head (parsed as in rule 3, at any seq) names the target's
sha. Otherwise the rules above apply unchanged. The same vouched
re-freeze is why the mail witness's older sha for that version is not a
disagreement under "Current target" below.

A version whose target IS its frozen head is the human's own head
(v1, or a later human integration); a version whose target differs is
the author persona's re-roll on top of it.

Unanswered push -- the newest X-Upstream-Head on the thread names the
PR's current head. When its sha is not the resolved frozen head, the
human author's newest push has no version posted for it (the author has
not run yet, failed to post, or answered with a mismatch report to the
operator), and a sign-off on an older head says nothing about the PR as
it now stands. That is a reason, so the thread is not CONVERGED; it is
not a status of its own. A carry push has no version posted for it by
design: see Carry, which moves the target and frozen head to the push.

Current target -- the postmaster's review_target is authoritative. The
newest message carrying X-Review-Target-Set is the mail-side witness: it
is the fallback when the postmaster has none (source "mail", with a
reason) and a disagreement, when both exist, is a reason too. No target
at all is a reason.

Per-seat verdict -- for each panel seat, the messages FROM it whose
X-Review-Target sha equals the current target sha ("on target"). Tags,
exactly as lkml-fleet-status.sh's "Design decision -- tags": Reviewed-by:,
Acked-by:, Tested-by: count only with the colon, at line start, anywhere
in the body; the bare verdicts Changes-requested, Question, NAK count
only on the first or last non-empty line; quoted ('>') lines never
count. A seat's verdict is the tag of its latest on-target message that
has any tag (a message carrying several takes the most severe: NAK,
Changes-requested, Question, then the -by trailers). state is:

    positive   Reviewed-by / Acked-by / Tested-by
    blocking   Changes-requested / NAK
    question   Question
    stale      no on-target tagged message, but a tagged message about
               another target exists; or a tagged message with no usable
               X-Review-Target is NEWER than the on-target positive (it
               may retract it, so the positive is not trusted)
    silent     no tagged message from the seat at all

A seat with no on-target tagged message may, under Carry above, take its
verdict from the nearest earlier version it gave one on. The entry then has
carried true and version/sha/message_id of the giving message, so a display
can say "carried from v3". Everything else about the verdict (the
stale-retraction rule, the Suite-Run read off the giving message) is
unchanged; a carried blocking verdict is reported "@core: Changes-requested
on v2 (carried from v1)". A seat that may carry but has nothing to carry
owes a verdict ("no verdict on v2 and nothing to carry from v1"), and a
seat a recheck push listed owes one ("recheck seat; nothing carries").
carried is false for every verdict given on the version it is judged on.

Suite run -- every seat in roster.suite_seats must state, on the SAME
message that supplied its verdict, that it ran the Suite command. On a
line of its own at the left margin, not quoted (QUOTED_RE, the tags'
rule); when a message has several the LAST one counts:

    Suite-Run: <N> passed, <M> failed
    Suite-Run: could-not-run <the first error line>

The grammar is exact: ^Suite-Run: ([0-9]{1,18}) passed, ([0-9]{1,18})
failed[ \t]*$ or ^Suite-Run: could-not-run( .*)?$; anything else that
starts "Suite-Run:" is malformed. Each seat's suite_run is null for a
seat that is not a suite seat (or with no Suite), else {"status",
"passed", "failed", "detail"} with status:

    clean          N >= 1 and M == 0
    no-tests       N == 0 and M == 0: a run that matched nothing proved
                   nothing
    failed         M >= 1
    could-not-run  detail is the line's text after "could-not-run"
    malformed      detail is the clipped offending line
    missing        no Suite-Run on the verdict message, or no verdict
                   message at all (silent, stale)

The rule: a suite seat that is positive without a clean suite run adds a
reason, which blocks CONVERGED (STALLED once quiescent: an operator must
fix the environment). Its state stays "positive": the seat HAS answered,
and a consumer that keys off state (lkml-wake-gate.py) must still see
that. A suite seat that is blocking or asking needs no extra reason.

Suite source and the CI gate -- a root header `X-Lkml-Suite-Source: ci`
turns the gate on for that thread, and ONLY that thread. Without it
nothing here changes: the Suite-Run gate above is in force, byte for
byte. Any other value (or several distinct values) is a reason, leaves the
Suite-Run gate in force, and reports ci.source null.

The CI side posts one mail per CI result, `To: @operator`:

    X-Lkml-CI-Status: success|failure|pending
    X-Lkml-CI-Head:   <branch> <sha>     (the commit CI ran on)
    X-Lkml-CI-Url:    <url>              (optional)

TRUST: a CI header counts only on a message From exactly `@operator`,
or, when the root carries `X-Lkml-CI-From: <address>`, exactly that
address instead (a bare name is accepted; mail from it needs no particular
recipient). The root is written once by the kickoff and no seat can change
it, which is why only the root may name the sender: the header on any
other message is ignored and, under `ci`, a reason. One distinct,
well-formed address is needed; anything else is a reason and `@operator`
stays trusted, never "anyone". Any seat can set an X-* header, so on any
other sender a CI header is ignored and, under `ci`, a reason. A mail from
the trusted sender whose status is not one distinct value of
success/failure/pending, or whose head is not one parseable
`<branch> <sha>`, is ignored with a reason too.

Under `ci`, CONVERGED needs the NEWEST (highest seq) trusted CI mail whose
sha equals the current frozen head's to say `success`. None, or `pending`,
is "CI has not reported on <sha8>"; `failure` is "CI failed on <sha8>".
A result on any other sha says nothing about this one: a carry version's
frozen head is the pushed head, so a rebase needs CI on the new head. The
seats' Suite-Run lines are neither required nor read (every suite_run is
null); roster.suite and roster.suite_seats are still reported. The panel's
own commits (a RESPIN's bundle) are never CI-tested: ci.covers_target is
false when the target sits above the frozen head.

The `ci` object reports the newest trusted result on the frozen head on
every thread, gated or not; reasons are raised only under `ci`.

Operator questions and the timeout -- a message from a seat on the
effective panel that carries the `Question` tag and names @operator among
its To/Cc recipients is an operator question. They are listed, whatever
the timeout, so a dashboard can show them:

    "questions": [{"seat","message_id","asked_at","age_seconds",
                   "timed_out","subject"}]    (every version, seq order)

asked_at is the message's Date as an ISO UTC stamp, age_seconds is
against `now` (--now <ISO-8601>, default the clock; the output carries it
as "now"), subject is the first line, clipped to 200 characters. A Date
that cannot be read leaves those three null and the question blocking.

The timeout is the root's `X-Lkml-Question-Timeout: <N>h` (whole hours,
N >= 1; so every reader of a thread agrees). Absent: no timeout, and
timed_out is null. Malformed: a reason, no timeout. A question is timed out
when its age is >= N hours. Then the `Question` tag on that message is
dropped before any seat is judged and the strongest REMAINING tag on the
same message decides; a message whose only tag was the question gives the
seat no verdict, so it still owes one and falls back to its earlier
verdicts by the usual rules (carry included). A timeout NEVER manufactures
a positive verdict. A question answered by an @operator reply is ordinary:
the seat's next verdict decides. Nothing wakes a thread when a question
times out; the timeout is read, not scheduled.

Secretary -- the roster's Secretary seat reports the panel's overall
state in the LAST non-empty lines of a message body, in this order:

    Panel-Version: <n>
    Panel-Status: CONVERGED|IN-PROGRESS
    Panel-Verdict: SIGNED-OFF|RESPIN      (only with CONVERGED)

The newest secretary message carrying any Panel-* line is the one that
counts (a later malformed one is not quietly skipped in favour of an
older good one). It is on_target when its X-Review-Target sha is the
current target's AND its Panel-Version is the target's version. A
trailer out of order, with an unknown value, with a Panel-Verdict under
IN-PROGRESS, without one under CONVERGED, or with a Panel-* line outside
the trailing block, is recorded as malformed with a reason and never
counts as CONVERGED.

Postmaster facts -- from `postmaster status`. quiescent means unrouted
== 0, no live run, no pending retry and no held seat. A run is live
unless its state is "harvested" (the postmaster writes only "live" and
"harvested"); a retry is pending only when its state is "pending" (the
postmaster's own quiescence test; "exhausted", "recovered" and a
FAILS-only record with no state are history). A state this script does
not recognize is treated as live/pending, with a reason. flagged means
the postmaster's flag is not null.

The postmaster's budget facts -- budget, budget_source ("thread" or
"global"), spawns_total (never reset) and grant_mode ("none", "file" or
"missing") -- are passed through in the `postmaster` object for a
dashboard: an int (not a bool) for the two counts, a non-empty string for
the two words, else null (absent, or an older postmaster). A word this
script does not know is passed through, not nulled. They raise no reason
and change no status.

Status -- precedence top to bottom, first match wins:

    NEEDS-OPERATOR  the thread is flagged
    CONVERGED       usable roster; a current target; every panel seat
                    positive; the secretary's message on target,
                    well-formed and saying CONVERGED; quiescent; the
                    target sources agree; no other reason. verdict is
                    the secretary's Panel-Verdict -- but with a frozen
                    head known, SIGNED-OFF is valid only when the target
                    sha IS the frozen head and RESPIN only when it is
                    not; the other is a contradiction and not CONVERGED.
                    With no frozen head known, SIGNED-OFF is valid only
                    on version 1 and RESPIN only above it
    STALLED         quiescent but not converged: nobody will wake, the
                    operator must look
    IN-PROGRESS     otherwise

On a carry version the secretary's trailer for the posted version carries
forward (entry.carried true, on_target judged against the posted version).

A secretary saying CONVERGED while the facts disagree is a named reason
("secretary says CONVERGED but @tests is blocking"): that is the false
green this script exists to catch.

Output (null, never an omitted key, for what is unknown):

    {"schema": "lkml-panel-state/1", "thread", "subject",
     "status", "verdict",          # verdict only when CONVERGED
     "target": {"branch","sha","version","set_by","set_at","source"},
                                        # source: postmaster, mail or carry
     "roster": {"author","panel","secretary","version_limit","frozen_head",
                "suite","suite_seats"},   # suite: string|null; suite_seats:
                                          # the resolved list, [] w/o Suite
     "tier": {"name","reason","source","message_id"},   # see "Tier"
     "panel": [...],                    # the effective roster: the root's
                                        # panel plus escalated-in seats
                                        # (roster.panel is unchanged)
     "push": {"seq","message_id","sha","branch","mode","seats","tier",
              "malformed","answered"},  # newest upstream-moved mail, or
                                        # null; see "Pushes and push modes"
     "frozen_head": {"sha","source"},   # of the current target; source
                                        # "root" or "upstream"
     "ci": {"source","trusted_from","status","sha","branch","url",
            "message_id","covers_target"},
                                        # source "ci"|null; trusted_from is
                                        # the CI sender counted (@operator
                                        # unless the root names one); the
                                        # rest describe
                                        # the newest trusted CI result on
                                        # the frozen head, null when none;
                                        # see "Suite source and the CI gate"
     "question_timeout_hours": N|null,  # see "Operator questions ..."
     "questions": [...],
     "now": "<ISO UTC>",                # the clock the ages were taken at
     "seats": [{"seat","state","verdict","message_id","version","sha",
                "suite_run","carried"}],   # suite_run: null, or {"status",
                                 # "passed","failed","detail"}; see "Suite
                                 # run". carried: false = the verdict was
                                 # given on this version
     "secretary": {"message_id","version","status","verdict",
                   "on_target","malformed","carried"},
     "postmaster": {"quiescent","flagged","flag_reason","live_runs",
                    "pending_retries","held","unrouted","budget",
                    "budget_source","spawns_total","grant_mode"},
     "bundle": {"base","tip","branch"},   # RESPIN + a frozen head only;
                                          # base is that frozen head
     "reasons": [...]}                    # empty only for CONVERGED
"""

import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

SCHEMA = "lkml-panel-state/1"

TRAILER_TAGS = ("Reviewed-by", "Acked-by", "Tested-by")
VERDICT_TAGS = ("Changes-requested", "Question", "NAK")
POSITIVE_TAGS = frozenset(TRAILER_TAGS)
BLOCKING_TAGS = frozenset(("Changes-requested", "NAK"))
SEVERITY = ("NAK", "Changes-requested", "Question",
            "Reviewed-by", "Acked-by", "Tested-by")

# awk's [[:space:]], written out: Python's \s would also match Unicode
# spaces and str.splitlines() would split on more than "\n".
SPACE = " \t\n\r\f\v"
QUOTED_RE = re.compile("^[" + SPACE + "]*>")
VERDICT_RE = {
    tag: re.compile("^" + re.escape(tag) + "([" + SPACE + r":.!,]|\Z)")
    for tag in VERDICT_TAGS
}
ADDRESS_RE = re.compile(r"^@[a-z0-9][a-z0-9-]*$")
HEX_SHA_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")
FROZEN_HEAD_RE = re.compile(r"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")
FROZEN_HEAD_LINE_RE = re.compile(r"^Frozen-Head:(.*)$")
ROSTER_KEYS = ("Author", "Panel", "Secretary", "Version-Limit", "Frozen-Head",
               "Suite", "Suite-Seats")
ROSTER_LINE_RE = re.compile(r"^(" + "|".join(ROSTER_KEYS) + r"):(.*)$")
PANEL_LINE_RE = re.compile(r"^Panel-[A-Za-z]+:")
PANEL_KNOWN_RE = re.compile(r"^Panel-(?:Version|Status|Verdict):")
SUITE_RUN_PREFIX = "Suite-Run:"
SUITE_RUN_COUNTS_RE = re.compile(
    r"Suite-Run: ([0-9]{1,18}) passed, ([0-9]{1,18}) failed[ \t]*")
SUITE_RUN_COULD_NOT_RE = re.compile(r"Suite-Run: could-not-run( .*)?")
SECRETARY_KEYS = ("Panel-Version", "Panel-Status", "Panel-Verdict")
TIERS = ("quick", "standard", "full")
TIER_HEADER = "X-Lkml-Tier"
TIER_REASON_HEADER = "X-Lkml-Tier-Reason"
TIER_REASON_MAX = 200
PUSH_MODE_HEADER = "X-Lkml-Push-Mode"
RECHECK_HEADER = "X-Lkml-Recheck-Seats"
ADD_SEATS_HEADER = "X-Lkml-Add-Seats"
PUSH_MODES = ("carry", "recheck", "escalate")
OPERATOR = "@operator"
SUITE_SOURCE_HEADER = "X-Lkml-Suite-Source"
CI_STATUS_HEADER = "X-Lkml-CI-Status"
CI_HEAD_HEADER = "X-Lkml-CI-Head"
CI_URL_HEADER = "X-Lkml-CI-Url"
CI_FROM_HEADER = "X-Lkml-CI-From"
CI_HEADERS = (CI_STATUS_HEADER, CI_HEAD_HEADER, CI_URL_HEADER)
CI_STATUSES = ("success", "failure", "pending")
QUESTION_TIMEOUT_HEADER = "X-Lkml-Question-Timeout"
QUESTION_TIMEOUT_RE = re.compile(r"([0-9]{1,18})h")
QUESTION_SUBJECT_MAX = 200

USAGE = """\
Usage: lkml-panel-state.py <thread-id> [--remote] [--now <ISO-8601>]
       lkml-panel-state.py --export-file <f> --status-file <f> [--now <ISO-8601>]
       lkml-panel-state.py -h|--help"""


UINT_RE = re.compile(r"[0-9]{1,18}")


def parse_uint(text):
    """A non-negative integer from digits, or None. The length cap keeps
    int() away from strings long enough to raise ValueError (Python 3.11+
    refuses 4300+ digits); no real version or count is anywhere near it."""
    return int(text) if UINT_RE.fullmatch(text) else None


def clip(text, n=40):
    return text if len(text) <= n else text[:n] + "..."


class InputError(Exception):
    pass


class UsageError(Exception):
    pass


def body_tags(body):
    """The tags a message body carries, in lkml-fleet-status.sh's
    canonical order (Reviewed-by Acked-by Tested-by Changes-requested
    Question NAK). Mirrors its fs_body_tags awk line for line."""
    first = last = None
    trailers = set()
    for line in body.split("\n"):
        if QUOTED_RE.match(line):
            continue
        if line.strip(" \t") == "":
            continue
        if first is None:
            first = line
        last = line
        for tag in TRAILER_TAGS:
            if line.startswith(tag + ":"):
                trailers.add(tag)
    out = [t for t in TRAILER_TAGS if t in trailers]
    for tag in VERDICT_TAGS:
        rx = VERDICT_RE[tag]
        if (first is not None and rx.match(first)) or \
           (last is not None and rx.match(last)):
            out.append(tag)
    return out


def header_values(msg, name):
    want = name.lower()
    out = []
    for pair in msg["headers"]:
        if (isinstance(pair, (list, tuple)) and len(pair) == 2
                and isinstance(pair[0], str)
                and pair[0].strip().lower() == want):
            out.append(str(pair[1]).strip())
    return out


def parse_target_value(value):
    """'<branch> <sha>' -> (branch, sha-lowercased), or None."""
    parts = value.split()
    if len(parts) != 2 or not HEX_SHA_RE.match(parts[1]):
        return None
    return parts[0], parts[1].lower()


def single_target_header(msg, name):
    """The one (branch, sha) a message states in header `name`, or None
    when it has no such header, an unparseable one, or several that
    disagree (a message that contradicts itself is about no target)."""
    parsed = {parse_target_value(v) for v in header_values(msg, name)}
    if len(parsed) != 1:
        return None
    return next(iter(parsed))


def int_header(msg, name):
    vals = {v for v in header_values(msg, name)}
    if len(vals) != 1:
        return None
    v = next(iter(vals))
    return parse_uint(v)


def normalize_message(raw):
    """One export message -> a dict the rest of the script reads. A
    malformed export entry (seq/error/file only), or one missing the
    fields the judgment needs, comes back with ok=False; the caller
    turns that into a reason rather than skipping it silently."""
    if not isinstance(raw, dict) or isinstance(raw.get("seq"), bool) \
            or not isinstance(raw.get("seq"), int):
        raise InputError("export has a message without an integer seq")
    m = {"seq": raw["seq"], "ok": False, "id": None, "from": None,
         "subject": None, "date": None, "body": "", "headers": [],
         "to": [], "cc": [], "sha": None, "version": None, "tags": []}
    if "error" in raw:
        return m
    if not (isinstance(raw.get("from"), str) and isinstance(raw.get("body"), str)
            and isinstance(raw.get("headers"), list)):
        return m
    m.update(ok=True, id=raw.get("id"), body=raw["body"],
             headers=raw["headers"], date=raw.get("date"),
             subject=raw.get("subject"))
    m["from"] = raw["from"].strip()
    for key in ("to", "cc"):
        if isinstance(raw.get(key), list):
            m[key] = [x.strip() for x in raw[key] if isinstance(x, str)]
    tgt = single_target_header(m, "X-Review-Target")
    m["sha"] = tgt[1] if tgt else None
    m["version"] = int_header(m, "X-Version")
    m["tags"] = body_tags(raw["body"])
    return m


def address(value, what, reasons):
    value = value.strip()
    if ADDRESS_RE.match(value):
        return value
    reasons.append(f"roster: malformed {what} address {value!r} dropped")
    return None


def first_line(text, limit):
    lines = text.strip().splitlines()
    return lines[0].strip()[:limit] if lines else ""


def parse_tier(root):
    """The root's tier headers -> (tier, reasons). See the module
    docstring, "Tier"."""
    tier = {"name": None, "reason": None, "source": None, "message_id": None}
    if root is None or not root["ok"]:
        return tier, []
    reasons = []
    for v in header_values(root, TIER_REASON_HEADER):
        text = first_line(v, TIER_REASON_MAX)
        if text:
            tier["reason"] = text
            break
    vals = set(header_values(root, TIER_HEADER))
    if not vals:
        return tier, reasons
    if len(vals) == 1 and next(iter(vals)) in TIERS:
        tier.update(name=next(iter(vals)), source="root",
                    message_id=root["id"])
    else:
        shown = " / ".join(repr(clip(v)) for v in sorted(vals))
        reasons.append(f"root {TIER_HEADER} {shown} is not quick, standard "
                       f"or full")
    return tier, reasons


def parse_suite_source(root):
    """The root's X-Lkml-Suite-Source -> (source|None, reasons). Only the
    value `ci` turns the CI gate on; see the module docstring, "Suite
    source and the CI gate"."""
    if root is None or not root["ok"]:
        return None, []
    vals = set(header_values(root, SUITE_SOURCE_HEADER))
    if not vals:
        return None, []
    if vals == {"ci"}:
        return "ci", []
    shown = " / ".join(repr(clip(v)) for v in sorted(vals))
    return None, [f"root {SUITE_SOURCE_HEADER} {shown} is not ci; the "
                  f"Suite-Run gate stays in force"]


def parse_ci_from(root):
    """The root's X-Lkml-CI-From -> (trusted sender, reasons). Absent, or
    not exactly one well-formed address: @operator (never "anyone")."""
    if root is None or not root["ok"]:
        return OPERATOR, []
    vals = set(header_values(root, CI_FROM_HEADER))
    if not vals:
        return OPERATOR, []
    if len(vals) == 1:
        addr = next(iter(vals))
        if not addr.startswith("@"):
            addr = "@" + addr
        if ADDRESS_RE.match(addr):
            return addr, []
    shown = " / ".join(repr(clip(v)) for v in sorted(vals))
    return OPERATOR, [f"root {CI_FROM_HEADER} {shown} is not one "
                      f"well-formed address; {OPERATOR}'s CI mail counts"]


def parse_ci_mails(msgs, gated, trusted=OPERATOR):
    """Every CI result mail -> (trusted records, reasons). A CI header
    counts only on a message From `trusted` (any seat can set an X-*
    header); anything else is ignored, and a reason only when `gated`.
    X-Lkml-CI-From on a non-root message is ignored: only the root names
    the sender."""
    records, reasons = [], []
    for m in msgs[1:]:
        if not m["ok"]:
            continue
        if gated and header_values(m, CI_FROM_HEADER):
            reasons.append(
                f"message seq {m['seq']} ({m['id']}) from "
                f"{clip(m['from'] or 'an unknown sender')} carries "
                f"{CI_FROM_HEADER}; only the root names the trusted CI "
                f"sender; ignored")
        present = [h for h in CI_HEADERS if header_values(m, h)]
        if not present:
            continue
        where = f"message seq {m['seq']} ({m['id']})"
        if m["from"] != trusted:
            if gated:
                reasons.append(
                    f"{where} from {clip(m['from'] or 'an unknown sender')} "
                    f"carries {present[0]}; only {trusted}'s CI mail "
                    f"counts; ignored")
            continue
        statuses = set(header_values(m, CI_STATUS_HEADER))
        head = single_target_header(m, CI_HEAD_HEADER)
        if len(statuses) != 1 or next(iter(statuses)) not in CI_STATUSES:
            shown = " / ".join(repr(clip(v)) for v in sorted(statuses)) \
                or "missing"
            if gated:
                reasons.append(
                    f"CI mail seq {m['seq']} ({m['id']}): {CI_STATUS_HEADER} "
                    f"{shown} is not success, failure or pending; ignored")
            continue
        if head is None:
            if gated:
                reasons.append(
                    f"CI mail seq {m['seq']} ({m['id']}): no parseable "
                    f"{CI_HEAD_HEADER}; ignored")
            continue
        url = next((v for v in header_values(m, CI_URL_HEADER) if v), None)
        records.append({"seq": m["seq"], "message_id": m["id"],
                        "status": next(iter(statuses)), "branch": head[0],
                        "sha": head[1], "url": url})
    return records, reasons


def ci_result(records, frozen_head, target, source, trusted=OPERATOR):
    """The newest trusted CI result on the frozen head -> (ci object,
    reasons). The object reports the fact whatever the source; reasons are
    raised only when the root opted in with `ci`."""
    ci = {"source": source, "trusted_from": trusted, "status": None, "sha": None, "branch": None,
          "url": None, "message_id": None, "covers_target": None}
    gated = source == "ci"
    if frozen_head is None:
        return ci, (["CI gate: no frozen head is known, so no CI result "
                     "can apply"] if gated else [])
    head = frozen_head["sha"]
    on_head = [r for r in records if r["sha"] == head]
    if not on_head:
        return ci, ([f"CI has not reported on {head[:8]}"] if gated else [])
    r = on_head[-1]
    ci.update(status=r["status"], sha=r["sha"], branch=r["branch"],
              url=r["url"], message_id=r["message_id"],
              covers_target=target is not None and target["sha"] == head)
    reasons = []
    if gated and r["status"] == "pending":
        reasons.append(f"CI has not reported on {head[:8]} "
                       f"(pending, message {r['message_id']})")
    elif gated and r["status"] == "failure":
        reasons.append(f"CI failed on {head[:8]} (message {r['message_id']})")
    return ci, reasons


def parse_question_timeout(root):
    """The root's X-Lkml-Question-Timeout -> (hours|None, reasons). See the
    module docstring, "Operator questions and the timeout"."""
    if root is None or not root["ok"]:
        return None, []
    vals = set(header_values(root, QUESTION_TIMEOUT_HEADER))
    if not vals:
        return None, []
    mt = QUESTION_TIMEOUT_RE.fullmatch(next(iter(vals))) \
        if len(vals) == 1 else None
    if mt and int(mt.group(1)) >= 1:
        return int(mt.group(1)), []
    shown = " / ".join(repr(clip(v)) for v in sorted(vals))
    return None, [f"root {QUESTION_TIMEOUT_HEADER} {shown} is not <N>h with "
                  f"N >= 1; no timeout applied"]


def parse_when(text):
    """A message Date (RFC 2822) or an ISO-8601 stamp -> an aware datetime,
    or None. A stamp with no zone is read as UTC."""
    if not isinstance(text, str) or not text.strip():
        return None
    text = text.strip()
    when = None
    try:
        when = parsedate_to_datetime(text)
    except (TypeError, ValueError, IndexError):
        iso = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
        try:
            when = datetime.fromisoformat(iso)
        except ValueError:
            return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.astimezone(timezone.utc)


def stamp(when):
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def operator_questions(msgs, panel, hours, now):
    """Every operator question on the thread -> (list, reasons). A message
    from a seat on the effective panel that carries the Question tag and
    names @operator among its recipients is one. When a timeout is set and
    the question is at least that old, its `Question` tag is dropped IN
    PLACE, before any seat is judged: the strongest remaining tag decides,
    and a message left with none is not a verdict at all. A timeout never
    produces a positive verdict by itself."""
    out, reasons = [], []
    for m in msgs:
        if not (m["ok"] and m["from"] in panel and "Question" in m["tags"]
                and OPERATOR in m["to"] + m["cc"]):
            continue
        asked = parse_when(m["date"])
        age = timed_out = None
        if asked is not None:
            age = int((now - asked).total_seconds())
            if hours is not None:
                timed_out = age >= hours * 3600
        elif hours is not None:
            reasons.append(f"question {m['id']} from {m['from']}: unreadable "
                           f"Date; the timeout cannot apply")
        if timed_out:
            m["tags"] = [t for t in m["tags"] if t != "Question"]
        out.append({"seat": m["from"], "message_id": m["id"],
                    "asked_at": stamp(asked) if asked else None,
                    "age_seconds": age, "timed_out": timed_out,
                    "subject": first_line(m["subject"] or "",
                                          QUESTION_SUBJECT_MAX)})
    return out, reasons


def seat_tokens(msg, name, reasons):
    """The seats an X-Lkml-*-Seats header lists, as '@name' addresses in
    header order, without duplicates. Bare names are accepted."""
    out = []
    for value in header_values(msg, name):
        for tok in value.split(","):
            tok = tok.strip()
            if not tok:
                continue
            addr = tok if tok.startswith("@") else "@" + tok
            if not ADDRESS_RE.match(addr):
                reasons.append(f"malformed {name} address {clip(tok)!r} dropped")
            elif addr not in out:
                out.append(addr)
    return out


def upstream_head(msg):
    """(branch, sha) of the last parseable X-Upstream-Head, or None."""
    found = None
    for v in header_values(msg, "X-Upstream-Head"):
        parsed = parse_target_value(v)
        if parsed is not None:
            found = parsed
    return found


def validate_push(msg, panel, tier):
    """One push's mode -> (mode|None, seats, new_tier|None, malformed|None,
    reasons). `panel` and `tier` are those in force when the push arrived;
    new_tier is set only by a valid escalate."""
    reasons = []
    modes = set(header_values(msg, PUSH_MODE_HEADER))
    if not modes:
        return None, [], None, None, reasons
    mode = next(iter(modes)) if len(modes) == 1 else None
    if mode not in PUSH_MODES:
        shown = " / ".join(repr(clip(v)) for v in sorted(modes))
        bad = (f"{PUSH_MODE_HEADER} {shown} is not carry, recheck or "
               f"escalate; treated as absent")
        return None, [], None, bad, reasons
    if mode == "carry":
        return "carry", [], None, None, reasons
    if mode == "recheck":
        listed = seat_tokens(msg, RECHECK_HEADER, reasons)
        kept = [a for a in listed if a in panel]
        for a in listed:
            if a not in panel:
                reasons.append(f"{RECHECK_HEADER} names {a}, which is not "
                               f"on the panel; dropped")
        if not kept:
            bad = f"{RECHECK_HEADER} names no seat on the panel; treated as absent"
            return None, [], None, bad, reasons
        return "recheck", kept, None, None, reasons
    tiers = set(header_values(msg, TIER_HEADER))
    name = next(iter(tiers)) if len(tiers) == 1 else None
    if name not in TIERS:
        shown = " / ".join(repr(clip(v)) for v in sorted(tiers)) or "none"
        bad = (f"{PUSH_MODE_HEADER} escalate names no usable {TIER_HEADER} "
               f"({shown}); ignored as malformed, treated as absent")
        return None, [], None, bad, reasons
    current = tier["name"]
    if current is not None and TIERS.index(name) < TIERS.index(current):
        bad = (f"{PUSH_MODE_HEADER} escalate names tier {name!r} below the "
               f"current {current!r}; ignored as malformed, treated as absent")
        return None, [], None, bad, reasons
    added = [a for a in seat_tokens(msg, ADD_SEATS_HEADER, reasons)
             if a not in panel]
    reason = tier["reason"]
    for v in header_values(msg, TIER_REASON_HEADER):
        text = first_line(v, TIER_REASON_MAX)
        if text:
            reason = text
            break
    new_tier = {"name": name, "reason": reason, "source": "escalate",
                "message_id": msg["id"]}
    return "escalate", added, new_tier, None, reasons


def parse_pushes(msgs, root_panel, tier):
    """Every upstream-moved mail -> (pushes, effective panel, tier in force,
    reasons). See the module docstring, "Pushes and push modes"."""
    pushes, reasons = [], []
    panel = list(root_panel)
    for m in msgs[1:]:
        if not m["ok"]:
            continue
        head = upstream_head(m)
        if head is None:
            if header_values(m, PUSH_MODE_HEADER):
                reasons.append(
                    f"message seq {m['seq']} ({m['id']}): {PUSH_MODE_HEADER} "
                    f"without a stamped X-Upstream-Head; ignored")
            continue
        mode, seats, new_tier, bad, why = validate_push(m, panel, tier)
        where = f"push seq {m['seq']} ({m['id']}): "
        reasons += [where + w for w in why]
        if bad:
            reasons.append(where + bad)
        if mode == "escalate":
            tier = new_tier
            panel += seats
        pushes.append({"seq": m["seq"], "message_id": m["id"],
                       "sha": head[1], "branch": head[0], "mode": mode,
                       "seats": seats, "tier": tier["name"],
                       "malformed": bad})
    return pushes, panel, tier, reasons


def parse_roster(root):
    """The roster from the thread root -> (roster, reasons)."""
    roster = {"author": None, "panel": [], "secretary": None,
              "version_limit": None, "frozen_head": None,
              "suite": None, "suite_seats": []}
    reasons = []
    if root is None or not root["ok"]:
        reasons.append("thread root is unreadable; no panel roster")
        return roster, reasons
    seen = {}
    for line in root["body"].split("\n"):
        mt = ROSTER_LINE_RE.match(line.strip(" \t\r"))
        if mt and mt.group(1) not in seen:
            seen[mt.group(1)] = mt.group(2).strip(" \t\r")
    if "Author" in seen:
        roster["author"] = address(seen["Author"], "Author", reasons)
    if "Secretary" in seen:
        roster["secretary"] = address(seen["Secretary"], "Secretary", reasons)
    if "Panel" in seen:
        for tok in seen["Panel"].split(","):
            tok = tok.strip()
            if not tok:
                continue
            addr = address(tok, "Panel", reasons)
            if addr and addr not in roster["panel"]:
                roster["panel"].append(addr)
    if "Version-Limit" in seen:
        roster["version_limit"] = parse_uint(seen["Version-Limit"])
        if roster["version_limit"] is None:
            reasons.append(
                f"roster: malformed Version-Limit "
                f"{clip(seen['Version-Limit'])!r} dropped")
    if "Frozen-Head" in seen:
        if FROZEN_HEAD_RE.match(seen["Frozen-Head"]):
            roster["frozen_head"] = seen["Frozen-Head"].lower()
        else:
            reasons.append(
                f"roster: malformed Frozen-Head {seen['Frozen-Head']!r} dropped")
    if not roster["panel"]:
        reasons.append("no panel roster on the thread root")
    reasons += resolve_suite(roster, seen)
    return roster, reasons


def resolve_suite(roster, seen):
    """Suite and Suite-Seats from the root's roster lines -> reasons;
    fills roster["suite"] and roster["suite_seats"]. See the module
    docstring, "Suite"."""
    reasons = []
    if "Suite" in seen:
        if seen["Suite"]:
            roster["suite"] = seen["Suite"]
        else:
            reasons.append("roster: empty Suite value; read as no Suite line")
    if roster["suite"] is None:
        if "Suite-Seats" in seen:
            reasons.append("roster: Suite-Seats without a Suite")
        return reasons
    if "Suite-Seats" not in seen:
        if "@tests" in roster["panel"]:
            roster["suite_seats"] = ["@tests"]
        else:
            reasons.append("roster: Suite: set but no Suite-Seats and "
                           "@tests is not on the panel")
        return reasons
    for tok in seen["Suite-Seats"].split(","):
        tok = tok.strip()
        if not tok:
            continue
        addr = address(tok, "Suite-Seats", reasons)
        if addr is None or addr in roster["suite_seats"]:
            continue
        if addr in roster["panel"]:
            roster["suite_seats"].append(addr)
        else:
            reasons.append(f"roster: Suite-Seats names {addr}, "
                           f"which is not on the panel; dropped")
    if not roster["suite_seats"]:
        reasons.append("roster: Suite: set but Suite-Seats names no seat "
                       "on the panel")
    return reasons


def opt_int(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return parse_uint(value)
    return None


def opt_str(value):
    return value if isinstance(value, str) and value != "" else None


def target_label(target):
    """'v3 (a1b2c3d4)', or '(a1b2c3d4)' when the version is unknown."""
    if target is None:
        return "the current target"
    sha8 = target["sha"][:8]
    if target["version"] is None:
        return f"({sha8})"
    return f"v{target['version']} ({sha8})"


def refrozen(target, msgs):
    """Whether `target` is a postmaster re-freeze vouched by the thread:
    set by @postmaster, with a sha some message's stamped X-Upstream-Head
    names. See the module docstring, "Frozen head"."""
    if (target is None or target.get("source") != "postmaster"
            or target.get("set_by") != "@postmaster"):
        return False
    for m in msgs:
        if m["ok"]:
            for v in header_values(m, "X-Upstream-Head"):
                parsed = parse_target_value(v)
                if parsed is not None and parsed[1] == target["sha"]:
                    return True
    return False


def resolve_target(status, msgs):
    """The current review target -> (target|None, reasons). The
    postmaster's is authoritative; the newest X-Review-Target-Set in mail
    is the fallback and the cross-check."""
    reasons = []
    pm_raw = status["review_target"]
    pm = None
    if pm_raw is not None:
        if not isinstance(pm_raw, dict):
            raise InputError("postmaster status: review_target is not an object")
        sha = opt_str(pm_raw.get("sha"))
        if sha is None or not HEX_SHA_RE.match(sha.strip()):
            reasons.append("postmaster review target has no usable sha")
        else:
            pm = {"branch": opt_str(pm_raw.get("branch")),
                  "sha": sha.strip().lower(),
                  "version": opt_int(pm_raw.get("version")),
                  "set_by": opt_str(pm_raw.get("set_by")),
                  "set_at": opt_str(pm_raw.get("set_at")),
                  "source": "postmaster"}

    mail = None
    setters = [m for m in msgs if m["ok"] and header_values(m, "X-Review-Target-Set")]
    if setters:
        newest = setters[-1]
        tgt = single_target_header(newest, "X-Review-Target-Set")
        if tgt is None:
            reasons.append(
                f"unparseable X-Review-Target-Set on message seq {newest['seq']}")
        else:
            mail = {"branch": tgt[0], "sha": tgt[1],
                    "version": int_header(newest, "X-Version"),
                    "set_by": newest["from"] or None,
                    "set_at": opt_str(newest["date"]),
                    "source": "mail"}

    if pm is not None:
        # A re-freeze moves the sha in place and sends no mail; it keeps
        # the version, so only a version mismatch is still a disagreement.
        if (mail is not None and mail["sha"] != pm["sha"]
                and not (refrozen(pm, msgs) and mail["version"] == pm["version"])):
            reasons.append(
                f"postmaster target {target_label(pm)} disagrees with the "
                f"newest X-Review-Target-Set in mail {target_label(mail)}")
        elif (mail is not None and mail["version"] is not None
                and pm["version"] is not None and mail["version"] != pm["version"]):
            reasons.append(
                f"postmaster target says v{pm['version']} but the newest "
                f"X-Review-Target-Set in mail says v{mail['version']}")
        return pm, reasons
    if mail is not None:
        reasons.append("postmaster has no review target; using the newest "
                       "X-Review-Target-Set from mail")
        return mail, reasons
    reasons.append("no review target")
    return None, reasons


def pick_tag(tags):
    for tag in SEVERITY:
        if tag in tags:
            return tag
    return None


def seat_state_of(tag):
    if tag in POSITIVE_TAGS:
        return "positive"
    if tag in BLOCKING_TAGS:
        return "blocking"
    return "question"


def suite_run(status, passed=None, failed=None, detail=None):
    return {"status": status, "passed": passed, "failed": failed,
            "detail": detail}


def parse_suite_run(body):
    """The Suite-Run claim a message body makes -> a suite_run object.
    Only non-quoted lines at the left margin count; the last one wins."""
    last = None
    for line in body.split("\n"):
        if QUOTED_RE.match(line):
            continue
        line = line.rstrip("\r")
        if line.startswith(SUITE_RUN_PREFIX):
            last = line
    if last is None:
        return suite_run("missing")
    mt = SUITE_RUN_COUNTS_RE.fullmatch(last)
    if mt:
        n, m = int(mt.group(1)), int(mt.group(2))
        status = "failed" if m else ("clean" if n else "no-tests")
        return suite_run(status, n, m)
    mt = SUITE_RUN_COULD_NOT_RE.fullmatch(last)
    if mt:
        return suite_run("could-not-run",
                         detail=clip((mt.group(1) or "").strip(" \t"), 200) or None)
    return suite_run("malformed", detail=clip(last, 80))


def suite_run_reason(seat, run):
    st = run["status"]
    if st == "clean":
        return None
    if st in ("failed", "no-tests"):
        what = f"{st}: {run['passed']} passed, {run['failed']} failed"
    elif st == "missing":
        what = "missing: no Suite-Run line on the verdict message"
    else:
        what = st + (f": {run['detail']}" if run["detail"] else "")
    return f"{seat} signed off without a clean suite run ({what})"


def posted_versions(msgs):
    """The versions the author posted, oldest first: one per run of
    X-Review-Target-Set messages naming the same sha, at the seq of the
    first. A carry push is not a posted version."""
    out = []
    for m in msgs:
        if not m["ok"]:
            continue
        tgt = single_target_header(m, "X-Review-Target-Set")
        if tgt is None or (out and out[-1]["sha"] == tgt[1]):
            continue
        out.append({"seq": m["seq"], "branch": tgt[0], "sha": tgt[1],
                    "version": int_header(m, "X-Version")})
    return out


def push_permits(push, seat):
    """Does this push let `seat` carry its verdict forward?"""
    if push["mode"] == "carry":
        return True
    return push["mode"] == "recheck" and seat not in push["seats"]


def link_pushes(msgs, roster, pushes, versions, i):
    """The pushes version i of `versions` answers, or None when it answers
    none and so nothing carries into it. A version answers a push when its
    resolved frozen head is that push's stamped head and the push arrived
    between the previous version and it. Every push in the interval counts,
    not only the answered one: a push whose mode withholds a seat's carry
    withholds it however the author later posts."""
    if i <= 0:
        return None
    v, prev = versions[i], versions[i - 1]
    fh, _ = resolve_frozen_head(msgs, roster, v)
    if fh is None or fh["source"] != "upstream":
        return None
    q = [p for p in pushes if prev["seq"] < p["seq"] < v["seq"]]
    return q if any(p["sha"] == fh["sha"] for p in q) else None


def ver_label(target):
    """'v3', or '(a1b2c3d4)' when the version is unknown."""
    if target["version"] is not None:
        return f"v{target['version']}"
    return f"({target['sha'][:8]})"


def judge_on(entry, seat, m, tagged, target, suite_seats, source=None):
    """Fill `entry` from `m`, the seat's latest tagged message on `target`
    -> (entry, reason|None). `source` is the target the verdict was GIVEN on
    when it is being carried forward, else None; `target` is always the
    version being judged."""
    tag = pick_tag(m["tags"])
    entry.update(state=seat_state_of(tag), verdict=tag, message_id=m["id"],
                 version=m["version"], sha=m["sha"], carried=source is not None)
    if seat in suite_seats:
        entry["suite_run"] = parse_suite_run(m["body"])
    if entry["state"] == "positive":
        newer = [x for x in tagged if x["seq"] > m["seq"] and x["sha"] is None]
        if newer:
            # A later tagged message about no readable target may be
            # a retraction; "silently vanishes" would be a false green.
            u = newer[-1]
            utag = pick_tag(u["tags"])
            entry.update(state="stale", verdict=utag, message_id=u["id"],
                         version=u["version"], sha=None, carried=False)
            if entry["suite_run"] is not None:
                # The Suite-Run was read off the older message; the
                # entry now names a message that made no such claim.
                entry["suite_run"] = suite_run("missing")
            return entry, (f"{seat}: newer message {u['id']} carries "
                           f"{utag} with no usable X-Review-Target; "
                           f"{tag} on {target_label(source or target)} not trusted")
        if entry["suite_run"] is not None:
            return entry, suite_run_reason(seat, entry["suite_run"])
        return entry, None
    where = ver_label(target)
    what = "unanswered Question" if tag == "Question" else tag
    carried = f" (carried from {ver_label(source)})" if source else ""
    return entry, f"{seat}: {what} on {where}{carried}"


def judge_seat(seat, msgs, target, suite_seats=(), carry_chain=(),
               recheck=False):
    """-> (seat entry, reason|None) for one panel seat. `carry_chain` is
    the targets, nearest first, whose verdicts this seat may carry forward
    onto `target` (see "Pushes and push modes"); empty means the seat owes
    a fresh verdict, and `recheck` says that is because a recheck push
    listed it."""
    tsha = target["sha"] if target else None
    mine = [m for m in msgs if m["ok"] and m["from"] == seat]
    tagged = [m for m in mine if m["tags"]]
    on = [m for m in tagged if tsha is not None and m["sha"] == tsha]
    entry = {"seat": seat, "state": "silent", "verdict": None,
             "message_id": None, "version": None, "sha": None,
             "suite_run": suite_run("missing") if seat in suite_seats else None,
             "carried": False}
    if on:
        return judge_on(entry, seat, on[-1], tagged, target, suite_seats)
    fallback = dict(entry)
    if tagged:
        m = tagged[-1]
        fallback.update(state="stale", verdict=pick_tag(m["tags"]),
                        message_id=m["id"], version=m["version"], sha=m["sha"])
    for prev in carry_chain:
        given = [m for m in tagged if m["sha"] == prev["sha"]]
        if given:
            return judge_on(entry, seat, given[-1], tagged, target,
                            suite_seats, source=prev)
    if carry_chain:
        return fallback, (f"{seat}: no verdict on {ver_label(target)} and "
                          f"nothing to carry from {ver_label(carry_chain[0])}")
    if recheck:
        return fallback, (f"{seat}: no verdict on {ver_label(target)} "
                          f"(recheck seat; nothing carries)")
    if tagged:
        m = tagged[-1]
        seen = target_label({"sha": m["sha"], "version": m["version"]}) \
            if m["sha"] else "a message with no usable X-Review-Target"
        return fallback, (f"{seat}: verdict is on {seen}, none on "
                          f"{target_label(target)}")
    return fallback, f"{seat}: no verdict on {target_label(target)}"


SEAT_PHRASE = {"blocking": "is blocking", "question": "has an open Question",
               "stale": "is stale", "silent": "is silent",
               "positive": "is positive"}


def plural(n, one, many=None):
    return f"{n} {one if n == 1 else (many or one + 's')}"


def parse_trailer(body):
    """The secretary's trailer block -> (fields|None, malformed-reason|None).
    None/None means the body carries no Panel-* line at all."""
    lines = [ln.strip(SPACE) for ln in body.split("\n") if ln.strip(SPACE) != ""]
    if not any(PANEL_KNOWN_RE.match(ln) for ln in lines):
        return None, None
    k = len(lines)
    while k > 0 and PANEL_LINE_RE.match(lines[k - 1]):
        k -= 1
    block = lines[k:]
    if not block:
        return None, "a Panel-* line is not in the last lines of the body"
    if any(PANEL_LINE_RE.match(ln) for ln in lines[:k]):
        return None, "a Panel-* line sits outside the trailing trailer block"
    keys = tuple(ln.split(":", 1)[0] for ln in block)
    vals = [ln.split(":", 1)[1].strip(SPACE) for ln in block]
    if keys not in (SECRETARY_KEYS[:2], SECRETARY_KEYS):
        return None, ("trailer block is not Panel-Version, Panel-Status "
                      "[, Panel-Verdict] in that order")
    fields = {"version": None, "status": None, "verdict": None}
    fields["version"] = parse_uint(vals[0])
    if fields["version"] is None:
        return None, f"Panel-Version {clip(vals[0])!r} is not a number"
    if vals[1] not in ("CONVERGED", "IN-PROGRESS"):
        return None, f"unknown Panel-Status {vals[1]!r}"
    fields["status"] = vals[1]
    if len(vals) == 3:
        if vals[2] not in ("SIGNED-OFF", "RESPIN"):
            return None, f"unknown Panel-Verdict {vals[2]!r}"
        if vals[1] != "CONVERGED":
            return None, "Panel-Verdict present under IN-PROGRESS"
        fields["verdict"] = vals[2]
    elif vals[1] == "CONVERGED":
        return None, "Panel-Status CONVERGED without a Panel-Verdict"
    return fields, None


def verdict_contradiction(verdict, target, frozen_head):
    if frozen_head is not None and target is not None:
        is_head = target["sha"] == frozen_head["sha"]
        where = f"target {target_label(target)}"
        head = f"frozen head ({frozen_head['sha'][:8]})"
        if verdict == "SIGNED-OFF" and not is_head:
            return (f"secretary verdict SIGNED-OFF contradicts {where} "
                    f"(SIGNED-OFF is only possible when the target is the "
                    f"{head})")
        if verdict == "RESPIN" and is_head:
            return (f"secretary verdict RESPIN contradicts {where} "
                    f"(the target is the {head}; nothing to respin)")
        return None
    v = target["version"] if target else None
    if v is None:
        return None
    if verdict == "SIGNED-OFF" and v > 1:
        return (f"secretary verdict SIGNED-OFF contradicts target v{v} "
                f"(SIGNED-OFF is only possible on v1)")
    if verdict == "RESPIN" and v == 1:
        return "secretary verdict RESPIN contradicts target v1 (nothing to respin yet)"
    return None


def resolve_frozen_head(msgs, roster, target):
    """The frozen head of the current target -> ({sha, source}|None,
    reasons). See the module docstring, "Frozen head"."""
    root_sha = roster["frozen_head"]
    fallback = {"sha": root_sha, "source": "root"} if root_sha else None
    author = roster["author"]
    if target is None or author is None:
        return fallback, []
    if refrozen(target, msgs):
        return {"sha": target["sha"], "source": "upstream"}, []
    covers = []
    for m in msgs:
        if m["ok"] and m["from"] == author:
            tgt = single_target_header(m, "X-Review-Target-Set")
            if tgt is not None and tgt[1] == target["sha"]:
                covers.append(m)
    if not covers:
        return fallback, []
    cover = covers[-1]
    raw = None
    for line in cover["body"].split("\n"):
        mt = FROZEN_HEAD_LINE_RE.match(line.strip(" \t\r"))
        if mt:
            raw = mt.group(1).strip(" \t\r")
            break
    if raw is None:
        return fallback, []
    if not FROZEN_HEAD_RE.match(raw):
        # The root's own malformed line already has a roster reason.
        why = [] if cover is msgs[0] else [
            f"cover seq {cover['seq']}: malformed Frozen-Head "
            f"{clip(raw)!r} ignored"]
        return fallback, why
    cand = raw.lower()
    if cand == root_sha:
        return {"sha": cand, "source": "root"}, []
    for m in msgs:
        if m["ok"] and m["seq"] < cover["seq"]:
            for v in header_values(m, "X-Upstream-Head"):
                parsed = parse_target_value(v)
                if parsed is not None and parsed[1] == cand:
                    return {"sha": cand, "source": "upstream"}, []
    return fallback, [f"cover Frozen-Head {cand[:8]} is not a stamped "
                      f"X-Upstream-Head on this thread"]


def carry_chain(seat, msgs, roster, pushes, versions, cur, synthetic):
    """-> (targets, rechecked): the earlier versions, nearest first, whose
    verdicts `seat` may carry forward onto version `cur`. A link in the
    chain exists while the version answers pushes that all let the seat
    carry; a synthetic carry version is all carry pushes by construction.
    rechecked says the walk stopped at the current version because a
    recheck push listed the seat."""
    chain, rechecked, i = [], False, cur
    while i is not None and i > 0:
        q = [] if (synthetic and i == cur) \
            else link_pushes(msgs, roster, pushes, versions, i)
        if q is None:
            break
        if not all(push_permits(p, seat) for p in q):
            rechecked = i == cur and any(
                p["mode"] == "recheck" and seat in p["seats"] for p in q)
            break
        chain.append(versions[i - 1])
        i -= 1
    return chain, rechecked


def carry_overlay(msgs, pushes, versions, cur, target, frozen_head):
    """-> (target, frozen_head, carry_from). When every push since the
    current posted version was a carry (so nobody was asked to look at
    anything) and the newest is not already that version's frozen head,
    the PR is on a synthetic carry version: its target AND frozen head are
    the newest push's stamped head (a carry does not move the postmaster's
    review target; only the author's post does), numbered one past the
    posted version per push (every human push counts). carry_from is the
    posted target the verdicts carry from, None when no overlay applies."""
    q = [p for p in pushes if p["seq"] > versions[cur]["seq"]]
    if not q or any(p["mode"] != "carry" for p in q):
        return target, frozen_head, None
    newest = q[-1]
    if frozen_head is not None and frozen_head["sha"] == newest["sha"]:
        return target, frozen_head, None
    mail = next(m for m in msgs if m["seq"] == newest["seq"])
    version = target["version"]
    synthetic = {"branch": newest["branch"], "sha": newest["sha"],
                 "version": None if version is None else version + len(q),
                 "set_by": mail["from"] or None,
                 "set_at": opt_str(mail["date"]), "source": "carry"}
    return (synthetic, {"sha": newest["sha"], "source": "upstream"},
            {"sha": target["sha"], "version": target["version"]})


def unanswered_push(msgs, frozen_head):
    """-> reasons. The newest X-Upstream-Head on the thread is the PR's
    current head; when it is not the resolved frozen head, the human
    author's newest push has not been posted as a version, and whatever the
    panel signed off is not the PR as it now stands."""
    newest = None
    for m in msgs:
        if not m["ok"]:
            continue
        for v in header_values(m, "X-Upstream-Head"):
            parsed = parse_target_value(v)
            if parsed is not None:
                newest = (m["seq"], parsed[1])
    if newest is None:
        return []
    if frozen_head is not None and frozen_head["sha"] == newest[1]:
        return []
    have = frozen_head["sha"][:8] if frozen_head else "none"
    return [f"the human author's newest push {newest[1][:8]} (seq {newest[0]}) "
            f"is not the frozen head of the current target ({have}): "
            f"no version has been posted for it"]


def judge_secretary(msgs, roster, target, carry_from=None):
    """-> (secretary entry|None, reasons). `carry_from` is the version a
    carry push moved on from: a secretary trailer that is on THAT version
    carries forward (nobody is woken to write a fresh one)."""
    sec = roster["secretary"]
    if sec is None:
        return None, ["roster has no usable Secretary"]
    cands = [m for m in msgs
             if m["ok"] and m["from"] == sec and parse_trailer(m["body"]) != (None, None)]
    if not cands:
        return None, [f"secretary {sec} has not reported a Panel-Status"]
    m = cands[-1]
    fields, bad = parse_trailer(m["body"])
    entry = {"message_id": m["id"], "version": None, "status": None,
             "verdict": None, "on_target": False, "malformed": bad,
             "carried": False}
    if bad:
        return entry, [f"secretary {sec} message {m['id']}: malformed trailer: {bad}"]
    entry.update(fields)
    reasons = []

    def on(t):
        return (t is not None and m["sha"] == t["sha"]
                and t["version"] is not None and fields["version"] == t["version"])

    entry["on_target"] = on(target)
    if not entry["on_target"] and on(carry_from):
        entry.update(on_target=True, carried=True)
    if not entry["on_target"]:
        said = f"v{fields['version']}" + (f" ({m['sha'][:8]})" if m["sha"] else "")
        reasons.append(f"secretary's Panel-Status is for {said}, "
                       f"not the current target {target_label(target)}")
    elif fields["status"] != "CONVERGED":
        reasons.append("secretary says IN-PROGRESS")
    return entry, reasons


def postmaster_facts(status):
    reasons = []
    unrouted = opt_int(status["unrouted"])
    live = pending = 0
    for r in status["runs"]:
        state = r.get("state") if isinstance(r, dict) else None
        if state == "harvested":
            continue
        live += 1
        if state != "live":
            rid = r.get("run_id") if isinstance(r, dict) else None
            reasons.append(f"run {rid}: unrecognized state {state!r}, treated as live")
    for r in status["retries"]:
        state = r.get("state") if isinstance(r, dict) else "unreadable"
        if state in (None, "exhausted", "recovered"):
            continue
        pending += 1
        if state != "pending":
            agent = r.get("agent") if isinstance(r, dict) else None
            reasons.append(
                f"retry for {agent}: unrecognized state {state!r}, treated as pending")
    held = len(status["held"])
    flag = status["flag"]
    flag_reason = None
    if isinstance(flag, dict):
        flag_reason = opt_str(flag.get("reason"))
    elif flag is not None:
        flag_reason = opt_str(flag)
    if unrouted is None:
        reasons.append("postmaster unrouted count is unreadable")
    elif unrouted:
        reasons.append(plural(unrouted, "unrouted message"))
    if live:
        reasons.append(plural(live, "live run"))
    if pending:
        reasons.append(plural(pending, "pending retry", "pending retries"))
    if held:
        reasons.append(plural(held, "held seat"))
    if flag is not None:
        reasons.append("the thread is flagged for the operator"
                       + (f": {flag_reason}" if flag_reason else ""))
    facts = {"quiescent": unrouted == 0 and not live and not pending and not held,
             "flagged": flag is not None, "flag_reason": flag_reason,
             "live_runs": live, "pending_retries": pending, "held": held,
             "unrouted": unrouted}
    budget, spawns = status.get("budget"), status.get("spawns_total")
    facts.update(
        budget=budget if isinstance(budget, int)
        and not isinstance(budget, bool) else None,
        budget_source=opt_str(status.get("budget_source")),
        spawns_total=spawns if isinstance(spawns, int)
        and not isinstance(spawns, bool) else None,
        grant_mode=opt_str(status.get("grant_mode")))
    return facts, reasons


def build_state(export, status, now):
    if not isinstance(export, dict) or not isinstance(export.get("thread"), str) \
            or not isinstance(export.get("messages"), list):
        raise InputError("mail export is not a thread object "
                         "(want 'thread' and 'messages')")
    if not isinstance(status, dict) or not isinstance(status.get("thread"), str):
        raise InputError("postmaster status is not a thread object "
                         "(want 'thread')")
    for key in ("unrouted", "flag", "review_target", "runs", "retries", "held"):
        if key not in status:
            raise InputError(f"postmaster status is missing '{key}'")
    for key in ("runs", "retries", "held"):
        if not isinstance(status[key], list):
            raise InputError(f"postmaster status: '{key}' is not a list")
    if export["thread"] != status["thread"]:
        raise InputError(
            f"thread ids disagree: export is {export['thread']!r}, "
            f"postmaster status is {status['thread']!r}")

    msgs = sorted((normalize_message(r) for r in export["messages"]),
                  key=lambda m: m["seq"])
    reasons = []
    root = msgs[0] if msgs else None
    if root is None:
        reasons.append("the thread has no messages")
    roster, roster_reasons = parse_roster(root)
    reasons += roster_reasons
    tier, tier_reasons = parse_tier(root)
    reasons += tier_reasons
    pushes, panel, tier, push_reasons = parse_pushes(msgs, roster["panel"], tier)
    reasons += push_reasons
    source, source_reasons = parse_suite_source(root)
    reasons += source_reasons
    trusted, from_reasons = parse_ci_from(root)
    reasons += from_reasons
    ci_records, ci_mail_reasons = parse_ci_mails(msgs, source == "ci", trusted)
    reasons += ci_mail_reasons
    timeout, timeout_reasons = parse_question_timeout(root)
    reasons += timeout_reasons
    questions, question_reasons = operator_questions(msgs, panel, timeout, now)
    reasons += question_reasons

    bad = [str(m["seq"]) for m in msgs if not m["ok"]]
    if bad:
        reasons.append(f"{len(bad)} unreadable message(s) in the export "
                       f"(seq {', '.join(bad)})")

    target, target_reasons = resolve_target(status, msgs)
    reasons += target_reasons

    frozen_head, fh_reasons = resolve_frozen_head(msgs, roster, target)
    reasons += fh_reasons

    versions = posted_versions(msgs)
    cur = next((i for i in range(len(versions) - 1, -1, -1)
                if target is not None and versions[i]["sha"] == target["sha"]),
               None)
    carry_from = None
    if cur is not None:
        target, frozen_head, carry_from = carry_overlay(
            msgs, pushes, versions, cur, target, frozen_head)
        if carry_from is not None:
            versions.append(dict(sha=target["sha"], version=target["version"],
                                 seq=pushes[-1]["seq"], branch=target["branch"]))
            cur = len(versions) - 1
    reasons += unanswered_push(msgs, frozen_head)

    ci, ci_reasons = ci_result(ci_records, frozen_head, target, source, trusted)
    reasons += ci_reasons
    # Under `ci` the suite's truth is CI's result, not a seat's claim: no
    # seat owes a Suite-Run line, and none is read.
    suite_seats = () if source == "ci" else roster["suite_seats"]

    seats = []
    for seat in panel:
        chain, rechecked = carry_chain(seat, msgs, roster, pushes, versions,
                                       cur, carry_from is not None)
        entry, why = judge_seat(seat, msgs, target, suite_seats,
                                chain, rechecked)
        seats.append(entry)
        if why:
            reasons.append(why)

    secretary, sec_reasons = judge_secretary(msgs, roster, target, carry_from)
    reasons += sec_reasons

    pm, pm_reasons = postmaster_facts(status)
    reasons += pm_reasons

    push = None
    if pushes:
        push = dict(pushes[-1], answered=(frozen_head is not None
                                          and frozen_head["sha"] == pushes[-1]["sha"]))

    seats_ok = bool(seats) and all(s["state"] == "positive" for s in seats)
    sec_says_converged = (secretary is not None and secretary["on_target"]
                          and secretary["status"] == "CONVERGED")
    if sec_says_converged:
        for s in seats:
            if s["state"] != "positive":
                reasons.append(
                    f"secretary says CONVERGED but {s['seat']} {SEAT_PHRASE[s['state']]}")
        if not pm["quiescent"]:
            reasons.append("secretary says CONVERGED but the thread is not quiescent")
        if pm["flagged"]:
            reasons.append("secretary says CONVERGED but the thread is flagged")
        contradiction = verdict_contradiction(secretary["verdict"], target, frozen_head)
        if contradiction:
            reasons.append(contradiction)

    reasons = list(dict.fromkeys(reasons))
    facts_ok = (bool(roster["panel"]) and target is not None and seats_ok
                and sec_says_converged and bool(pm["quiescent"]))
    if not facts_ok and not reasons:
        reasons.append("internal: not converged for a cause that was not "
                       "recorded; treat as IN-PROGRESS")

    if pm["flagged"]:
        status_word = "NEEDS-OPERATOR"
    elif not reasons:
        status_word = "CONVERGED"
    elif pm["quiescent"]:
        status_word = "STALLED"
    else:
        status_word = "IN-PROGRESS"

    verdict = secretary["verdict"] if status_word == "CONVERGED" else None
    bundle = None
    if verdict == "RESPIN" and frozen_head:
        bundle = {"base": frozen_head["sha"], "tip": target["sha"],
                  "branch": target["branch"]}

    return {
        "schema": SCHEMA,
        "thread": export["thread"],
        "subject": opt_str(root["subject"]) if root and root["ok"] else None,
        "status": status_word,
        "verdict": verdict,
        "target": target,
        "roster": roster,
        "tier": tier,
        "panel": panel,
        "push": push,
        "frozen_head": frozen_head,
        "ci": ci,
        "question_timeout_hours": timeout,
        "questions": questions,
        "now": stamp(now),
        "seats": seats,
        "secretary": secretary,
        "postmaster": pm,
        "bundle": bundle,
        "reasons": reasons,
    }


def read_json(path, label):
    try:
        if path == "-":
            text = sys.stdin.read()
        else:
            with open(path, encoding="utf-8") as f:
                text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise InputError(f"cannot read {label} {path}: {e}")
    return parse_json(text, label)


def parse_json(text, label):
    try:
        return json.loads(text)
    except ValueError as e:
        raise InputError(f"{label} is not valid JSON: {e}")


def run_fork_sandbox(argv, label):
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise InputError(f"cannot run {argv[0]}: {e}")
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip().splitlines()
        raise InputError(f"{label} failed (exit {p.returncode})"
                         + (f": {err[-1]}" if err else ""))
    return parse_json(p.stdout.decode("utf-8", "replace"), label)


def parse_when_iso(text):
    """--now's value: ISO-8601 only (a mail Date is not one)."""
    iso = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
    try:
        when = datetime.fromisoformat(iso)
    except ValueError:
        raise UsageError(f"--now {text!r} is not an ISO-8601 timestamp")
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.astimezone(timezone.utc)


def parse_args(argv):
    opts = {"thread": None, "remote": False, "export": None, "status": None,
            "help": False, "now": None}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            opts["help"] = True
        elif a == "--remote":
            opts["remote"] = True
        elif a in ("--export-file", "--status-file"):
            if i + 1 >= len(argv):
                raise UsageError(f"{a} requires a file")
            opts["export" if a == "--export-file" else "status"] = argv[i + 1]
            i += 1
        elif a == "--now":
            if i + 1 >= len(argv):
                raise UsageError("--now requires an ISO-8601 timestamp")
            opts["now"] = parse_when_iso(argv[i + 1])
            i += 1
        elif a.startswith("--now="):
            opts["now"] = parse_when_iso(a[len("--now="):])
        elif a.startswith("-") and a != "-":
            raise UsageError(f"unknown option '{a}'")
        elif opts["thread"] is None:
            opts["thread"] = a
        else:
            raise UsageError(f"only one thread id may be given "
                             f"(got '{opts['thread']}' and '{a}')")
        i += 1
    if opts["help"]:
        return opts
    files = opts["export"] is not None or opts["status"] is not None
    if opts["thread"] is not None and files:
        raise UsageError("a thread id and --export-file/--status-file "
                         "are different forms; give one")
    if files:
        if opts["export"] is None or opts["status"] is None:
            raise UsageError("--export-file and --status-file are both required")
        if opts["remote"]:
            raise UsageError("--remote applies to the <thread-id> form only")
        if opts["export"] == "-" and opts["status"] == "-":
            raise UsageError("at most one input may be '-' (stdin)")
    elif opts["thread"] is None:
        raise UsageError("give a thread id, or --export-file and --status-file")
    return opts


def main(argv):
    try:
        opts = parse_args(argv)
    except UsageError as e:
        sys.stderr.write(f"Error: {e}\n{USAGE}\n")
        return 2
    if opts["help"]:
        sys.stdout.write(__doc__)
        return 0
    try:
        if opts["thread"] is not None:
            tid = opts["thread"]
            remote = ["--remote"] if opts["remote"] else []
            export = run_fork_sandbox(
                ["fork-sandbox", "mail", *remote, "export", tid, "--json"],
                "fork-sandbox mail export")
            status = run_fork_sandbox(
                ["fork-sandbox", "postmaster", *remote, "status",
                 "--thread", tid, "--json"],
                "fork-sandbox postmaster status")
        else:
            export = read_json(opts["export"], "mail export")
            status = read_json(opts["status"], "postmaster status")
        state = build_state(export, status,
                            opts["now"] or datetime.now(timezone.utc))
    except InputError as e:
        sys.stderr.write("Error: " + " ".join(str(e).split()) + "\n")
        return 1
    sys.stdout.write(json.dumps(state, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
