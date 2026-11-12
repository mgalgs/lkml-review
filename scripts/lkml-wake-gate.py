#!/usr/bin/env python3
"""lkml-wake-gate.py — a wake-when gate for the PR panel's author and
secretary seats.

Usage: FS_HOOK_AGENT=pr-author|secretary FS_HOOK_MESSAGE=<id> \\
       FS_HOOK_EXPORT_FILE=<f> FS_HOOK_STATUS_FILE=<f> lkml-wake-gate.py
       lkml-wake-gate.py -h|--help

Why this exists: reviewers reply To: the author seat, and the postmaster
wakes the author on EVERY reply. Most of those wakes are empty: the
author finds that not every reviewer has answered the current version
yet and goes back to sleep, having spent a spawn. This gate answers
"is it worth waking the author for this message?" before the spawn.

It also closes a converged panel one wake sooner. A reviewer's verdict
reply Cc's the root's Secretary seat, so the reply that makes every seat
settled reaches both seats at once. The secretary is woken on it and
writes the closing summary; the author, whose only move would be a
one-line "verdict on vN?" To: the secretary, is skipped. The secretary
is skipped on every other reviewer reply. A reply that missed the
secretary still wakes the author, which asks the secretary as before: a
forgotten Cc costs a wake, never a converged panel with nobody woken.

The contract (fork-sandbox's per-seat `wake-when: <suffix>` fleet key):
the postmaster runs $FORK_SANDBOX_HOOKS_DIR/wake-when.<suffix>
synchronously, with a 30 s timeout, before any spawn of that seat. It is
staged as wake-when.lkml-panel by lkml-wake-gate-install.sh, next to a
copy of lkml-panel-state.py. The environment it gets:

    FS_HOOK_EVENT         wake-when
    FS_HOOK_THREAD        the thread id
    FS_HOOK_AGENT         the seat about to be woken, as the bare fleet
                          name (pr-author, secretary); an '@' prefix is
                          accepted too
    FS_HOOK_MESSAGE       id of the message that triggered the wake
    FS_HOOK_EXPORT_FILE   = `fork-sandbox mail export <thread> --json`
    FS_HOOK_STATUS_FILE   = `fork-sandbox postmaster status --thread
                            <thread> --json`

Exit codes: 0 wakes the seat. 1 defers: no spawn, no budget spent, and
the seat's next wake sees the whole thread; a thread that goes quiet
with a defer outstanding is flagged wake-deferred by the postmaster,
which lkml-panel-state.py already reports as NEEDS-OPERATOR. 3 skips:
no spawn, no budget spent, no wake-deferred record, and any standing
defer for that seat on that thread is cleared; the message is simply not
one the seat is woken for. Any other exit, or a timeout, wakes the seat
and is logged as wake-gate-error.

Exit 3 needs a postmaster that knows it. An older one treats it as an
unknown exit and fails open, waking the seat: no wake is lost, but the
author and the secretary are then both woken on the closing reply, and
the secretary on every reviewer reply that Cc's it.

This script exits 2 on every failure of its own (a missing env var, the
sibling lkml-panel-state.py failing or answering something unexpected, a
trigger message absent from the export). The postmaster wakes the seat
either way, but 2 makes the broken gate VISIBLE as wake-gate-error: a
silent wake would hide it behind normal behaviour, which is the false
green this tooling exists to avoid.

On a child thread a wake must not bypass the capacity check, so there
each of those failures exits 1 instead, a defer, with the one line
reading "lkml-wake-gate: child: defer: gate error: <reason>". Whether
the thread is a child is read from the export's root message directly,
before panel-state runs and whatever it answers: a root carrying
X-Lkml-Parent-Thread with any value, malformed included, is a child. An
export whose root cannot be read leaves that unknown, and the gate
exits 2 as on a main thread.

The seat states come from the SIBLING lkml-panel-state.py, run as a
subprocess (argv list, no shell, 20 s timeout). It is the single
authority on what a seat's verdict is; nothing of its logic is copied
here. This script reads the export only to find the trigger message,
and the status only for the runs[] and retries[] of rules g and m.
"Settled" is panel-state's own word: a seat whose state is positive or
overruled on the current target (carried included).

"Every seat" below means every GATING seat: a seat panel-state marks
"advisory" (named on the root's Advisory: line) is never waited for and
never counted, settled or not. Its reply is still a panel reviewer's
reply, so it reaches rule d like any other and wakes the author when the
gating seats warrant it.

A sub-panel (docs/cluster-panel.md, "Sub-panel") touches the gate twice.
On a main thread, its digest is relayed To: the author carrying
X-Lkml-Sub-Panel; rule p wakes the author on it however the panel stands,
since after convergence nothing else would. On the child thread itself
(the root carries X-Lkml-Parent-Thread) there is no author: rule a does not
apply, and the secretary is woken once every seat has ANSWERED, whatever
the verdicts, since nothing there waits for a block to settle. Back on the
main thread, a digest the author has not answered (relayed, or attached
to the root as sub-panel-digest.md) holds the secretary by rule q, so a
settled panel wakes the author by rule f rather than closing round it:
the author must take or decline the digest before the panel converges.
A wake on a child thread, any seat's, by any rule, also waits for room
on the model server (docs/cluster-panel.md, "Sub-panel capacity").
Its LKML_CAPACITY_* settings come from the environment or from the file
lkml-capacity.env in $FORK_SANDBOX_HOOKS_DIR (else beside this script,
symlinks followed), the environment winning. The file's KEY=value lines
are parsed, never sourced.

Handovers. When the decision is to wake the AUTHOR seat (exit 0), the
gate can hand the spawner values panel-state derives from the thread, each
as one value, and nothing else, in a file whose path is an optional
environment variable. A variable that is unset or empty means no
handover, and the gate then behaves exactly as without this feature:

    FS_HOOK_PIPELINE_SIZE_FILE   the size of the fix this wake owes: the
                                 largest Fix-Size (xs < s < m < l) over
                                 the open blocking verdicts of gating
                                 seats on the current version (panel-state
                                 author_wake.fix_size; a blocking verdict
                                 with no usable Fix-Size line counts as
                                 m). Not written when no gating seat
                                 blocks.
    FS_HOOK_FINALIZE_FLOOR_FILE  one full sha: the frozen head the author's
                                 next version stands on, the lowest commit
                                 the finalize script may rewrite history
                                 down to. That is the frozen head of the
                                 current review target as posted: for an
                                 author version, its cover's Frozen-Head
                                 line; for a head the human pushed (the
                                 root included), that head. Not written,
                                 and said, when panel-state cannot tell
                                 (a cover without a usable line).
    FS_HOOK_CHECKOUT_FILE        one full sha, written only for an
                                 INTEGRATION wake: the head H the human
                                 pushed, which the author resets its
                                 branch to and posts unchanged, so the
                                 wake starts at H. panel-state decides
                                 what an integration wake is (the
                                 persona's checklist, "Has the human
                                 author pushed?": the newest push that is
                                 not a carry, unanswered, with every owed
                                 seat replied or the Secretary already
                                 asked). For that wake, when this variable
                                 is set, neither a floor nor a size is
                                 written; for every other author wake
                                 nothing is written here.

Nothing is written for a skip, a defer, an error or a wake of any other
seat (the secretary). A value that cannot be worked out, or a file that
cannot be written, is said on stderr in one extra "lkml-wake-gate:
handover: ..." line after the decision line, and changes nothing else:
the exit code is the one the gate returns without the variable.

Rules, in order; the first match decides, and every path prints exactly
one "lkml-wake-gate: ..." line on stderr naming the decision and rule
(plus one "handover:" line per handover that could not be made, when a
handover variable is set):

    a  roster.author is null, but the root names a Panel or a
       Secretary, and the thread is not a sub-panel -> exit 2
       (a PR panel root with no readable Author line)
    b  the agent is neither roster.author nor roster.secretary -> exit 0
       (this gate judges those two seats only; a root with no Secretary
       line gates no secretary, and a root naming none of Author, Panel
       and Secretary is not a PR panel thread, so the secretary invoked
       solo there, on a series review or a To: @secretary request, is
       woken without judgement)

The author seat, after b:

    c  the trigger has an X-Upstream-Head header  -> exit 0
       (the human author's push always wakes the author)
    p  the trigger carries X-Lkml-Sub-Panel, is To: the author, and its
       sender is not on the panel                 -> exit 0
       (a relayed sub-panel digest is advice for the author, not
       reviewer chatter; it wakes mid-review and after convergence
       alike. A panel seat's message is reviewer chatter, tag or not,
       and goes on to the rules below)
    d  the trigger's sender is not in the panel   -> exit 0
       (operator, CI, secretary and the root are not reviewer chatter;
       the panel is panel-state's effective roster, so a seat escalated in
       by an X-Lkml-Push-Mode: escalate push is a reviewer)
    e  no target, or the target has no sha        -> exit 0
       (nothing to wait for)
    i  every seat is answered (f's case), every seat is settled, AND the
       trigger is To: or Cc: roster.secretary, AND rules j-o, run for the
       secretary on this same message, wake it -> exit 3
       (the secretary is being woken on this message to close the panel;
       the author would only ask it to. Checked before f, and only
       where f would wake. A trigger the secretary would skip, because
       a push or a sub-panel digest is unanswered, a secretary run is
       live or pending, or it already posted on the target, falls
       through to f, so skipping
       the author never leaves the panel with nobody woken. A live
       secretary run whose trigger is this message is not rule m's live
       run here: it is the secretary already woken on it, should the
       postmaster spawn it before gating the author)
    f  every seat is positive, overruled, blocking or question -> exit 0
       (every reviewer has answered the current version; a verdict
       panel-state reports as carried forward is a verdict, so a recheck
       version waits only on the seats it listed and a carry version on
       nobody; with a sub-panel digest unanswered, this is the wake on
       which the author takes or declines it)
    g  some seat is blocking or question, and every seat still waiting
       ran on the current target and went silent  -> exit 0
       (the postmaster status's runs[]: the seat's newest harvested run
       with review_target_sha = the target sha posted replies == 0, it
       has no live run there, and no retries[] entry of state pending.
       Waiting on it would strand the author: nothing else will reply.
       A waiting seat with no run at the target sha keeps the author
       waiting)
    h  otherwise                                  -> exit 1
       (some seat is still stale or silent)

The secretary seat, after b:

    j  the trigger is from roster.author or @operator -> exit 0
       (a deliberate request: the author's verdict request, its
       Version-Limit request naming what still blocks, the operator)
    k  no target with a sha, or some seat is not settled -> exit 3
       (a reviewer's verdict that leaves the panel open; the seats
       are named. On a sub-panel, read "has not answered" for "is not
       settled": a block there is a finding for the digest)
    l  panel-state's push is unanswered           -> exit 3
       (the author owes a version for the human's push first)
    q  on a main thread, a sub-panel digest is unanswered -> exit 3
       (a relayed one, rule p's test, or the root's attachment
       sub-panel-digest.md; answered once a later message from the
       author is a cover (X-Version), or is To: the secretary or To:
       the digest's sender. The author owes it an answer before the
       panel closes; holding the secretary here makes rule i fall
       through to f, which wakes the author)
    m  a secretary run is live, or a secretary retry is pending
                                                  -> exit 3
       (status runs[]/retries[] read as rule g reads them: a run is
       live unless harvested, a retry pending only in state pending)
    n  panel-state's secretary.on_target is true  -> exit 3
       (it already posted on this target)
    o  otherwise                                  -> exit 0
       (the panel is settled: close it)

Python 3 stdlib only.
"""

import json
import math
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

SCHEMA = "lkml-panel-state/1"
TIMEOUT = 20
REQUIRED = ("FS_HOOK_AGENT", "FS_HOOK_MESSAGE",
            "FS_HOOK_EXPORT_FILE", "FS_HOOK_STATUS_FILE")
ANSWERED = frozenset(("positive", "overruled", "blocking", "question"))
OBJECTING = frozenset(("blocking", "question"))
SETTLED = frozenset(("positive", "overruled"))
OPERATOR = "@operator"
DIGEST_ATTACHMENT = "sub-panel-digest.md"
# The capacity read on a child thread: each query gets HTTP_TIMEOUT
# seconds, both together CAPACITY_BUDGET, inside the postmaster's 30 s
# after panel-state's 20 s.
HTTP_TIMEOUT = 4
CAPACITY_BUDGET = 8
MAX_BODY = 1 << 20
CAPACITY_FILE = "lkml-capacity.env"
CAPACITY_PREFIX = "LKML_CAPACITY_"
SIZE_VAR = "FS_HOOK_PIPELINE_SIZE_FILE"
FLOOR_VAR = "FS_HOOK_FINALIZE_FLOOR_FILE"
CHECKOUT_VAR = "FS_HOOK_CHECKOUT_FILE"
SIZE_RE = re.compile(r"[a-z][a-z0-9-]{0,15}")
SHA_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
SIZE_OR_SHA = {SIZE_VAR: SIZE_RE, FLOOR_VAR: SHA_RE, CHECKOUT_VAR: SHA_RE}
SIZE_OR_SHA_WORDS = {SIZE_VAR: "a token the spawner accepts",
                     FLOOR_VAR: "a full sha", CHECKOUT_VAR: "a full sha"}
DURATION_RE = re.compile(r"(?:[0-9]+(?:ms|s|m|h|d|w|y))+")


class Done(Exception):
    def __init__(self, code, text):
        self.code = code
        self.text = text
        # The parsed state and the normalised agent, set once the gate has
        # them, for the handover (see handover()).
        self.state = None
        self.agent = None


def fail(text):
    return Done(2, "error: " + text)


def panel_state(export_file, status_file):
    sibling = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "lkml-panel-state.py")
    argv = [sys.executable, sibling,
            "--export-file", export_file, "--status-file", status_file]
    try:
        proc = subprocess.run(argv, capture_output=True, text=True,
                              timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        raise fail("lkml-panel-state.py timed out after %d s" % TIMEOUT)
    except OSError as e:
        raise fail("cannot run %s: %s" % (sibling, e))
    if proc.returncode != 0:
        err = proc.stderr.strip().splitlines()
        raise fail("lkml-panel-state.py exited %d%s"
                   % (proc.returncode, ": " + err[-1] if err else ""))
    try:
        state = json.loads(proc.stdout)
    except ValueError:
        raise fail("lkml-panel-state.py printed unparsable JSON")
    if not isinstance(state, dict) or state.get("schema") != SCHEMA:
        raise fail("lkml-panel-state.py schema is not %s" % SCHEMA)
    return state


def is_child(export_file):
    """Whether the export's root (its lowest seq) carries the sub-panel
    header, with any value. Tolerant: an export that cannot be read is
    no child here, and its failure is reported where it is read."""
    try:
        with open(export_file or "") as f:
            messages = json.load(f)["messages"]
        roots = [m for m in messages if isinstance(m, dict)
                 and isinstance(m.get("seq"), int)
                 and not isinstance(m.get("seq"), bool)]
    except (OSError, ValueError, KeyError, TypeError):
        return False
    return bool(roots) and has_header(min(roots, key=lambda m: m["seq"]),
                                      "X-Lkml-Parent-Thread")


def read_messages(export_file):
    try:
        with open(export_file) as f:
            data = json.load(f)
        messages = data["messages"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise fail("cannot read the export %s: %s" % (export_file, e))
    return [m for m in (messages if isinstance(messages, list) else [])
            if isinstance(m, dict)]


def find_trigger(messages, message_id):
    for m in messages:
        if m.get("id") == message_id:
            return m
    raise fail("trigger message %s is not in the export" % message_id)


def read_status(status_file):
    try:
        with open(status_file) as f:
            status = json.load(f)
    except (OSError, ValueError) as e:
        raise fail("cannot read the status %s: %s" % (status_file, e))
    if not isinstance(status, dict):
        raise fail("the status %s is not an object" % status_file)
    return status


def bare(name):
    return str(name or "").strip().lstrip("@")


def silent_run(status, seat, sha):
    """The run id of seat's newest harvested, zero-reply run at sha, or
    None when the seat may still reply there."""
    name = bare(seat)
    for r in status.get("retries") or []:
        if (isinstance(r, dict) and bare(r.get("agent")) == name
                and r.get("state") == "pending"):
            return None
    runs = [r for r in status.get("runs") or []
            if isinstance(r, dict) and bare(r.get("agent")) == name
            and r.get("review_target_sha") == sha]
    if not runs or any(r.get("state") != "harvested" for r in runs):
        return None
    # ISO-8601 UTC strings order correctly as text; a record from before
    # harvested_at existed sorts first and so never decides.
    newest = max(runs, key=lambda r: str(r.get("harvested_at") or ""))
    replies = newest.get("replies")
    if isinstance(replies, bool) or replies != 0:
        return None
    return newest.get("run_id") or "?"


def has_header(msg, name):
    want = name.lower()
    headers = msg.get("headers")
    for pair in headers if isinstance(headers, list) else []:
        if (isinstance(pair, (list, tuple)) and pair
                and isinstance(pair[0], str)
                and pair[0].strip().lower() == want):
            return True
    return False


def names_of(msg, key):
    v = msg.get(key)
    return ["@" + bare(n) for n in (v if isinstance(v, list) else [])
            if isinstance(n, str)]


def sender_of(msg):
    sender = msg.get("from")
    return sender.strip() if isinstance(sender, str) else sender


def is_relayed_digest(msg, author, panel):
    """Rule p's test: a sub-panel digest relayed To: the author by a
    sender that is not on the panel."""
    return (has_header(msg, "X-Lkml-Sub-Panel") and sender_of(msg) not in panel
            and author in names_of(msg, "to"))


def open_digest(messages, author, secretary, panel):
    """The id of a sub-panel digest on a main thread that the author has
    not yet answered, or None. A digest is a relayed one (rule p's test)
    or the root's sub-panel-digest.md attachment. It counts as answered
    once a later message from the author is a cover (X-Version), or is
    To: the secretary or To: the digest's sender: the persona's three
    ways of answering one, judged by their envelope, not their prose."""
    pending = None
    for i, m in enumerate(messages):
        if i == 0:
            # The mail export lists attachments as {"name", "bytes"}.
            atts = m.get("attachments")
            if any(isinstance(a, dict) and isinstance(a.get("name"), str)
                   and os.path.basename(a["name"].strip()) == DIGEST_ATTACHMENT
                   for a in (atts if isinstance(atts, list) else [])):
                pending = (m.get("id") or "?", None)
            continue
        if pending and sender_of(m) == author:
            to = names_of(m, "to")
            if (has_header(m, "X-Version") or secretary in to
                    or (pending[1] is not None and pending[1] in to)):
                pending = None
        if is_relayed_digest(m, author, panel):
            pending = (m.get("id") or "?", sender_of(m))
    return pending[0] if pending else None


def secretary_run(status, seat, woken_on=None):
    """A description of seat's live run or pending retry, or None. A live
    run whose trigger is woken_on does not count: that run is the seat
    being woken on that very message."""
    name = bare(seat)
    for r in status.get("runs") or []:
        if (isinstance(r, dict) and bare(r.get("agent")) == name
                and r.get("state") != "harvested"
                and (woken_on is None or r.get("trigger") != woken_on)):
            return "run %s is %s" % (r.get("run_id") or "?", r.get("state"))
    for r in status.get("retries") or []:
        if (isinstance(r, dict) and bare(r.get("agent")) == name
                and r.get("state") == "pending"):
            return "a retry is pending"
    return None


def gating_seats(state):
    """The seats whose verdicts count: every seat but an advisory one."""
    return [s for s in state.get("seats") or []
            if isinstance(s, dict) and s.get("advisory") is not True]


def secretary_skip(state, status, secretary, digest, child, woken_on=None):
    """Rules k-n: (rule, why) when the secretary is not woken on a
    reviewer's trigger, or None when the panel is ready to close.
    digest is open_digest()'s answer; child is is_child()'s; woken_on is
    passed by rule i; see secretary_run."""
    target = state.get("target")
    seats = gating_seats(state)
    done = ANSWERED if child else SETTLED
    if not target or not target.get("sha"):
        return "k", "the thread has no review target"
    open_ = sorted((s for s in seats if s.get("state") not in done),
                   key=lambda s: str(s.get("seat")))
    if open_ or not seats:
        return "k", "not settled: " + (", ".join(
            "%s (%s)" % (s.get("seat"), s.get("state")) for s in open_)
            or "no seats")
    push = state.get("push")
    if push is not None and not push.get("answered"):
        return "l", "the push %s is unanswered" % push.get("message_id")
    if digest and not child:
        return "q", "the sub-panel digest %s is unanswered" % digest
    live = secretary_run(status, secretary, woken_on)
    if live:
        return "m", "%s %s" % (secretary, live)
    sec = state.get("secretary") or {}
    if sec.get("on_target"):
        return "n", "%s already posted on the target (%s)" % (
            secretary, sec.get("message_id"))
    return None


def addressed(msg, who):
    names = []
    for key in ("to", "cc"):
        v = msg.get(key)
        names += v if isinstance(v, list) else []
    return who in ["@" + bare(n) for n in names if isinstance(n, str)]


def decide(env):
    child = is_child(env.get("FS_HOOK_EXPORT_FILE"))
    try:
        decide_thread(env, child)
    except Done as d:
        # The postmaster wakes a seat whose gate fails, and a child's seat
        # must not wake past the capacity check: defer instead.
        if d.code == 2 and child:
            raise Done(1, "child: defer: gate " + d.text)
        raise


def decide_thread(env, child):
    for key in REQUIRED:
        if not env.get(key):
            raise fail("%s is missing or empty" % key)
    # The postmaster passes the bare fleet name; roster addresses carry
    # the '@'. Compare in the roster's form, or rule b wakes every time.
    agent = "@" + env["FS_HOOK_AGENT"].strip().lstrip("@")

    state = panel_state(env["FS_HOOK_EXPORT_FILE"], env["FS_HOOK_STATUS_FILE"])
    messages = read_messages(env["FS_HOOK_EXPORT_FILE"])
    trigger = find_trigger(messages, env["FS_HOOK_MESSAGE"])
    try:
        judge(env, state, messages, trigger, agent, child)
    except Done as d:
        d.state, d.agent = state, agent
        # A child's seats run on the self-hosted model: a wake there waits
        # for room on it. A defer, skip or error stands without a read.
        if d.code == 0 and child:
            busy = capacity_busy(env)
            if busy:
                raise Done(1, "capacity: defer: %s; held: %s" % (busy, d.text))
        raise


def judge(env, state, messages, trigger, agent, child):
    roster = state.get("roster") or {}
    author = roster.get("author")
    secretary = roster.get("secretary")
    # A root naming no Author, Panel or Secretary is not a PR panel (a
    # series review, a To: @secretary request): rule b wakes, not an error.
    if (author is None and not child
            and (secretary is not None or roster.get("panel"))):
        raise Done(2, "error: the roster names no author (rule a)")
    if agent not in (author, secretary):
        raise Done(0, "wake: %s is neither the author seat %s nor the "
                      "secretary seat %s (rule b)" % (agent, author, secretary))
    # The effective roster: the root's panel plus any escalated-in seat.
    panel = state.get("panel") or roster.get("panel") or []
    digest = open_digest(messages, author, secretary, panel)
    if agent == secretary:
        decide_secretary(env, state, trigger, author, secretary, digest, child)
    if has_header(trigger, "X-Upstream-Head"):
        raise Done(0, "wake: %s is the human author's push (rule c)"
                   % env["FS_HOOK_MESSAGE"])
    sender = sender_of(trigger)
    if is_relayed_digest(trigger, author, panel):
        raise Done(0, "wake: %s is a sub-panel digest from %s (rule p)"
                   % (env["FS_HOOK_MESSAGE"], sender))
    if sender not in panel:
        raise Done(0, "wake: %s is not a panel reviewer (rule d)" % sender)
    target = state.get("target")
    if not target or not target.get("sha"):
        raise Done(0, "wake: the thread has no review target (rule e)")
    seats = gating_seats(state)
    waiting = [s for s in seats if s.get("state") not in ANSWERED]
    if not waiting:
        if (secretary is not None and seats
                and all(s.get("state") in SETTLED for s in seats)
                and addressed(trigger, secretary)
                and secretary_skip(state, read_status(env["FS_HOOK_STATUS_FILE"]),
                                   secretary, digest, child,
                                   env["FS_HOOK_MESSAGE"]) is None):
            raise Done(3, "skip %s: every seat is settled and %s reaches "
                          "%s, which is woken on it (rule i)"
                       % (agent, env["FS_HOOK_MESSAGE"], secretary))
        raise Done(0, "wake: every reviewer has answered "
                      "the current version (rule f)")
    waiting.sort(key=lambda s: str(s.get("seat")))
    if any(s.get("state") in OBJECTING for s in seats):
        status = read_status(env["FS_HOOK_STATUS_FILE"])
        silent = [(s, silent_run(status, s.get("seat"), target["sha"]))
                  for s in waiting]
        if all(rid for _, rid in silent):
            names = ", ".join("%s (run %s)" % (s.get("seat"), rid)
                              for s, rid in silent)
            raise Done(0, "wake: a reviewer objects and every waiting seat "
                          "ran silent on the target: %s (rule g)" % names)
    names = ", ".join("%s (%s)" % (s.get("seat"), s.get("state"))
                      for s in waiting)
    raise Done(1, "defer %s: waiting on %s (rule h)" % (agent, names))


class CapacityError(Exception):
    pass


def capacity_settings(env):
    """-> (the LKML_CAPACITY_* settings, the file read for them). The file
    is $FORK_SANDBOX_HOOKS_DIR/lkml-capacity.env, else lkml-capacity.env
    beside this script (symlinks followed). Its KEY=value lines are
    parsed, never sourced: blank lines, '#' comments, lines without '='
    and keys outside LKML_CAPACITY_ are ignored, and one pair of matching
    quotes round a value is stripped. A variable set in the environment
    wins over the file. A missing or unreadable file sets nothing."""
    hooks = env.get("FORK_SANDBOX_HOOKS_DIR") or ""
    path = os.path.join(
        hooks or os.path.dirname(os.path.realpath(__file__)), CAPACITY_FILE)
    settings = {}
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, ValueError):
        lines = []
    for line in lines:
        if line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if not key.startswith(CAPACITY_PREFIX):
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        settings[key] = value
    settings.update((k, v) for k, v in env.items()
                    if k.startswith(CAPACITY_PREFIX))
    return settings, path


def capacity_config(env):
    """-> (base url, selector, max waiting, max preemptions, window),
    from the LKML_CAPACITY_* settings; CapacityError when unusable."""
    settings, path = capacity_settings(env)
    url = (settings.get("LKML_CAPACITY_PROMETHEUS") or "").strip()
    if not url:
        raise CapacityError("LKML_CAPACITY_PROMETHEUS is unset, in the "
                            "environment and in %s" % path)
    try:
        scheme = urllib.parse.urlsplit(url).scheme
    except ValueError as e:
        raise CapacityError("LKML_CAPACITY_PROMETHEUS %r is not a URL: %s"
                            % (url, e))
    if scheme not in ("http", "https"):
        raise CapacityError("LKML_CAPACITY_PROMETHEUS %r is not an http(s) "
                            "URL" % url)
    sel = (settings.get("LKML_CAPACITY_SELECTOR") or "").strip()
    if sel and not (sel.startswith("{") and sel.endswith("}")):
        raise CapacityError("LKML_CAPACITY_SELECTOR %r is not a {...} label "
                            "matcher" % sel)
    limits = []
    for key in ("LKML_CAPACITY_MAX_WAITING", "LKML_CAPACITY_MAX_PREEMPTIONS"):
        raw = (settings.get(key) or "0").strip()
        if not re.fullmatch(r"[0-9]+", raw):
            raise CapacityError("%s %r is not a non-negative integer"
                                % (key, raw))
        limits.append(int(raw))
    window = (settings.get("LKML_CAPACITY_WINDOW") or "5m").strip()
    if not DURATION_RE.fullmatch(window):
        raise CapacityError("LKML_CAPACITY_WINDOW %r is not a PromQL "
                            "duration" % window)
    return url.rstrip("/"), sel, limits[0], limits[1], window


def http_get(url, timeout):
    """The body at url, or CapacityError. The request runs on a daemon
    thread so a server that answers byte by byte cannot hold the gate
    past timeout: the socket timeout bounds only each read. The opener
    ignores *_proxy in the environment: the server is reached directly."""
    box = {}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def fetch():
        try:
            with opener.open(url, timeout=timeout) as resp:
                box["body"] = resp.read(MAX_BODY + 1)
        except urllib.error.HTTPError as e:
            box["error"] = "HTTP %d" % e.code
        except Exception as e:  # noqa: BLE001 -- every failure defers
            box["error"] = "unreachable: %s" % (getattr(e, "reason", None) or e)

    t = threading.Thread(target=fetch, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        raise CapacityError("prometheus timed out after %.1f s" % timeout)
    if "error" in box:
        raise CapacityError("prometheus " + box["error"])
    if len(box["body"]) > MAX_BODY:
        raise CapacityError("prometheus answered more than %d bytes"
                            % MAX_BODY)
    return box["body"]


def instant_query(base, promql, timeout):
    """The one finite number an instant query answers, or CapacityError."""
    body = http_get(base + "/api/v1/query?"
                    + urllib.parse.urlencode({"query": promql}), timeout)
    try:
        doc = json.loads(body)
    except ValueError:
        raise CapacityError("prometheus answered non-JSON for %s" % promql)
    if not isinstance(doc, dict) or doc.get("status") != "success":
        err = doc.get("error") if isinstance(doc, dict) else None
        raise CapacityError("prometheus status %r for %s%s" % (
            doc.get("status") if isinstance(doc, dict) else None, promql,
            ": %s" % err if err else ""))
    data = doc.get("data")
    result = data.get("result") if isinstance(data, dict) else None
    if not isinstance(result, list) or not result:
        raise CapacityError("no series for %s" % promql)
    if len(result) != 1 or not isinstance(result[0], dict):
        raise CapacityError("%d series for %s, want 1" % (len(result), promql))
    value = result[0].get("value")
    try:
        number = float(value[1])
    except (TypeError, ValueError, IndexError, KeyError):
        raise CapacityError("non-numeric value %r for %s" % (value, promql))
    if not math.isfinite(number):
        raise CapacityError("non-finite value %r for %s" % (value[1], promql))
    return number


def capacity_busy(env):
    """Why the model server has no room for a child seat, or None when it
    has. Every failure to tell is a reason: the postmaster wakes a seat
    whose gate errors, so the capacity read must fail closed itself."""
    try:
        base, sel, max_waiting, max_preempt, window = capacity_config(env)
        deadline = time.monotonic() + CAPACITY_BUDGET
        waiting = instant_query(
            base, "sum(vllm:num_requests_waiting%s)" % sel,
            min(HTTP_TIMEOUT, deadline - time.monotonic()))
        if waiting > max_waiting:
            return "%g requests waiting (max %d)" % (waiting, max_waiting)
        preempted = instant_query(
            base, "sum(increase(vllm:num_preemptions_total%s[%s]))"
            % (sel, window), min(HTTP_TIMEOUT, deadline - time.monotonic()))
        if preempted > max_preempt:
            return "%g preemptions in %s (max %d)" % (preempted, window,
                                                     max_preempt)
    except CapacityError as e:
        return str(e)
    return None


def decide_secretary(env, state, trigger, author, secretary, digest, child):
    sender = sender_of(trigger)
    if sender in (author, OPERATOR):
        raise Done(0, "wake: %s is a request from %s (rule j)"
                   % (env["FS_HOOK_MESSAGE"], sender))
    skip = secretary_skip(state, read_status(env["FS_HOOK_STATUS_FILE"]),
                          secretary, digest, child)
    if skip:
        raise Done(3, "skip %s: %s (rule %s)" % (secretary, skip[1], skip[0]))
    raise Done(0, "wake %s: every seat is settled on the target; "
                  "close the panel (rule o)" % secretary)


def write_handover(var, name, value):
    """Write `value`, and nothing else, to the path in the environment
    variable `var` -> a stderr line when it cannot be done, else None."""
    path = os.environ.get(var, "")
    try:
        with open(path, "w", encoding="ascii") as f:
            f.write(value)
    except (OSError, ValueError) as e:
        return "handover: %s not written to %s: %s" % (
            name, path, getattr(e, "strerror", None) or e)
    return None


def handover(done):
    """After the decision is final: when it is a wake of the author seat,
    hand the spawner what panel-state knows about the wake, each value in
    its own file named by its own optional variable (see the docstring,
    "Handovers"). Returns the stderr lines for what could not be handed
    over. Never raises and never changes the decision."""
    if done.code != 0 or done.state is None:
        return []
    out = []

    def put(var, name, value, why):
        """Hand `value` over, or say why not: `why` when there is no value."""
        if value is None:
            if why:
                out.append("lkml-wake-gate: handover: no %s: %s" % (name, why))
        elif not isinstance(value, str) or not SIZE_OR_SHA[var].fullmatch(value):
            out.append("lkml-wake-gate: handover: %s %r is not %s; not "
                       "written" % (name, value, SIZE_OR_SHA_WORDS[var]))
        else:
            err = write_handover(var, name, value)
            if err:
                out.append("lkml-wake-gate: " + err)

    try:
        author = (done.state.get("roster") or {}).get("author")
        if author is None or done.agent != author:
            return []
        wanted = [v for v in (SIZE_VAR, FLOOR_VAR, CHECKOUT_VAR)
                  if os.environ.get(v)]
        wake = done.state.get("author_wake")
        if not isinstance(wake, dict):
            return ["lkml-wake-gate: handover: panel-state reports no "
                    "author_wake; nothing written to %s" % v for v in wanted]
        # An integration wake starts at the pushed head: it gets that and
        # neither a floor nor a size. Only when the spawner asked for it.
        if wake.get("integration") is True and CHECKOUT_VAR in wanted:
            put(CHECKOUT_VAR, "checkout", wake.get("checkout"),
                wake.get("checkout_note") or "panel-state gave no pushed head")
        else:
            if SIZE_VAR in wanted:
                put(SIZE_VAR, "fix size", wake.get("fix_size"), None)
            if FLOOR_VAR in wanted:
                put(FLOOR_VAR, "finalize floor", wake.get("floor"),
                    wake.get("floor_note") or "panel-state gave no floor")
    except Exception as e:  # noqa: BLE001 -- a handover never changes the decision
        out.append("lkml-wake-gate: handover: failed: %s" % e)
    return out


def main(argv):
    if len(argv) > 1:
        if argv[1] in ("-h", "--help"):
            print(__doc__.rstrip("\n"))
            return 0
        print("lkml-wake-gate: error: unexpected argument %r" % argv[1],
              file=sys.stderr)
        return 2
    try:
        decide(os.environ)
    except Done as d:
        print("lkml-wake-gate: " + d.text, file=sys.stderr)
        for line in handover(d):
            print(line, file=sys.stderr)
        return d.code
    return 2  # unreachable: decide() always raises Done


if __name__ == "__main__":
    sys.exit(main(sys.argv))
