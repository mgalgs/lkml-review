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

The seat states come from the SIBLING lkml-panel-state.py, run as a
subprocess (argv list, no shell, 20 s timeout). It is the single
authority on what a seat's verdict is; nothing of its logic is copied
here. This script reads the export only to find the trigger message,
and the status only for the runs[] and retries[] of rules g and m.
"Settled" is panel-state's own word: a seat whose state is positive or
overruled on the current target (carried included).

Rules, in order; the first match decides, and every path prints exactly
one "lkml-wake-gate: ..." line on stderr naming the decision and rule:

    a  roster.author is null, but the root names a Panel or a
       Secretary                                  -> exit 2
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
       a push is unanswered, a secretary run is live or pending, or it
       already posted on the target, falls through to f, so skipping
       the author never leaves the panel with nobody woken. A live
       secretary run whose trigger is this message is not rule m's live
       run here: it is the secretary already woken on it, should the
       postmaster spawn it before gating the author)
    f  every seat is positive, overruled, blocking or question -> exit 0
       (every reviewer has answered the current version; a verdict
       panel-state reports as carried forward is a verdict, so a recheck
       version waits only on the seats it listed and a carry version on
       nobody)
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
       are named)
    l  panel-state's push is unanswered           -> exit 3
       (the author owes a version for the human's push first)
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
import os
import subprocess
import sys

SCHEMA = "lkml-panel-state/1"
TIMEOUT = 20
REQUIRED = ("FS_HOOK_AGENT", "FS_HOOK_MESSAGE",
            "FS_HOOK_EXPORT_FILE", "FS_HOOK_STATUS_FILE")
ANSWERED = frozenset(("positive", "overruled", "blocking", "question"))
OBJECTING = frozenset(("blocking", "question"))
SETTLED = frozenset(("positive", "overruled"))
OPERATOR = "@operator"


class Done(Exception):
    def __init__(self, code, text):
        self.code = code
        self.text = text


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


def find_trigger(export_file, message_id):
    try:
        with open(export_file) as f:
            data = json.load(f)
        messages = data["messages"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise fail("cannot read the export %s: %s" % (export_file, e))
    for m in messages if isinstance(messages, list) else []:
        if isinstance(m, dict) and m.get("id") == message_id:
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


def secretary_skip(state, status, secretary, woken_on=None):
    """Rules k-n: (rule, why) when the secretary is not woken on a
    reviewer's trigger, or None when the panel is ready to close.
    woken_on is passed by rule i; see secretary_run."""
    target = state.get("target")
    seats = state.get("seats") or []
    if not target or not target.get("sha"):
        return "k", "the thread has no review target"
    open_ = sorted((s for s in seats if s.get("state") not in SETTLED),
                   key=lambda s: str(s.get("seat")))
    if open_ or not seats:
        return "k", "not settled: " + (", ".join(
            "%s (%s)" % (s.get("seat"), s.get("state")) for s in open_)
            or "no seats")
    push = state.get("push")
    if push is not None and not push.get("answered"):
        return "l", "the push %s is unanswered" % push.get("message_id")
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
    for key in REQUIRED:
        if not env.get(key):
            raise fail("%s is missing or empty" % key)
    # The postmaster passes the bare fleet name; roster addresses carry
    # the '@'. Compare in the roster's form, or rule b wakes every time.
    agent = "@" + env["FS_HOOK_AGENT"].strip().lstrip("@")

    state = panel_state(env["FS_HOOK_EXPORT_FILE"], env["FS_HOOK_STATUS_FILE"])
    trigger = find_trigger(env["FS_HOOK_EXPORT_FILE"], env["FS_HOOK_MESSAGE"])

    roster = state.get("roster") or {}
    author = roster.get("author")
    secretary = roster.get("secretary")
    # A root naming no Author, Panel or Secretary is not a PR panel (a
    # series review, a To: @secretary request): rule b wakes, not an error.
    if author is None and (secretary is not None or roster.get("panel")):
        raise Done(2, "error: the roster names no author (rule a)")
    if agent not in (author, secretary):
        raise Done(0, "wake: %s is neither the author seat %s nor the "
                      "secretary seat %s (rule b)" % (agent, author, secretary))
    if agent == secretary:
        decide_secretary(env, state, trigger, author, secretary)
    if has_header(trigger, "X-Upstream-Head"):
        raise Done(0, "wake: %s is the human author's push (rule c)"
                   % env["FS_HOOK_MESSAGE"])
    sender = trigger.get("from")
    sender = sender.strip() if isinstance(sender, str) else sender
    # The effective roster: the root's panel plus any escalated-in seat.
    if sender not in (state.get("panel") or roster.get("panel") or []):
        raise Done(0, "wake: %s is not a panel reviewer (rule d)" % sender)
    target = state.get("target")
    if not target or not target.get("sha"):
        raise Done(0, "wake: the thread has no review target (rule e)")
    seats = state.get("seats") or []
    waiting = [s for s in seats if s.get("state") not in ANSWERED]
    if not waiting:
        if (secretary is not None and seats
                and all(s.get("state") in SETTLED for s in seats)
                and addressed(trigger, secretary)
                and secretary_skip(state, read_status(env["FS_HOOK_STATUS_FILE"]),
                                   secretary, env["FS_HOOK_MESSAGE"]) is None):
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


def decide_secretary(env, state, trigger, author, secretary):
    sender = trigger.get("from")
    sender = sender.strip() if isinstance(sender, str) else sender
    if sender in (author, OPERATOR):
        raise Done(0, "wake: %s is a request from %s (rule j)"
                   % (env["FS_HOOK_MESSAGE"], sender))
    skip = secretary_skip(state, read_status(env["FS_HOOK_STATUS_FILE"]),
                          secretary)
    if skip:
        raise Done(3, "skip %s: %s (rule %s)" % (secretary, skip[1], skip[0]))
    raise Done(0, "wake %s: every seat is settled on the target; "
                  "close the panel (rule o)" % secretary)


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
        return d.code
    return 2  # unreachable: decide() always raises Done


if __name__ == "__main__":
    sys.exit(main(sys.argv))
