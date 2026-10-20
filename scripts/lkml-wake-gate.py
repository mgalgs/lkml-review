#!/usr/bin/env python3
"""lkml-wake-gate.py — a wake-when gate for the PR panel's author seat.

Usage: FS_HOOK_AGENT=pr-author FS_HOOK_MESSAGE=<id> \\
       FS_HOOK_EXPORT_FILE=<f> FS_HOOK_STATUS_FILE=<f> lkml-wake-gate.py
       lkml-wake-gate.py -h|--help

Why this exists: reviewers reply To: the author seat, and the postmaster
wakes the author on EVERY reply. Most of those wakes are empty: the
author finds that not every reviewer has answered the current version
yet and goes back to sleep, having spent a spawn. This gate answers
"is it worth waking the author for this message?" before the spawn.

The contract (fork-sandbox's per-seat `wake-when: <suffix>` fleet key):
the postmaster runs $FORK_SANDBOX_HOOKS_DIR/wake-when.<suffix>
synchronously, with a 30 s timeout, before any spawn of that seat. It is
staged as wake-when.lkml-panel by lkml-wake-gate-install.sh, next to a
copy of lkml-panel-state.py. The environment it gets:

    FS_HOOK_EVENT         wake-when
    FS_HOOK_THREAD        the thread id
    FS_HOOK_AGENT         the seat about to be woken, as the bare fleet
                          name (pr-author); an '@' prefix is accepted too
    FS_HOOK_MESSAGE       id of the message that triggered the wake
    FS_HOOK_EXPORT_FILE   = `fork-sandbox mail export <thread> --json`
    FS_HOOK_STATUS_FILE   = `fork-sandbox postmaster status --thread
                            <thread> --json`

Exit codes: 0 wakes the seat. 1 defers: no spawn, no budget spent, and
the seat's next wake sees the whole thread; a thread that goes quiet
with a defer outstanding is flagged wake-deferred by the postmaster,
which lkml-panel-state.py already reports as NEEDS-OPERATOR. Any other
exit, or a timeout, wakes the seat and is logged as wake-gate-error.

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
and the status only for rule g's runs[] and retries[].

Rules, in order; the first match decides, and every path prints exactly
one "lkml-wake-gate: ..." line on stderr naming the decision and rule:

    a  roster.author is null                      -> exit 2
    b  the agent is not roster.author             -> exit 0
       (this gate judges the author seat only)
    c  the trigger has an X-Upstream-Head header  -> exit 0
       (the human author's push always wakes the author)
    d  the trigger's sender is not in the panel   -> exit 0
       (operator, CI, secretary and the root are not reviewer chatter;
       the panel is panel-state's effective roster, so a seat escalated in
       by an X-Lkml-Push-Mode: escalate push is a reviewer)
    e  no target, or the target has no sha        -> exit 0
       (nothing to wait for)
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
    if author is None:
        raise Done(2, "error: the roster names no author (rule a)")
    if agent != author:
        raise Done(0, "wake: %s is not the author seat %s (rule b)"
                   % (agent, author))
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
