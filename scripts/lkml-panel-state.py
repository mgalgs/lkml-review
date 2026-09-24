#!/usr/bin/env python3
"""lkml-panel-state.py — where does a fleet-transport review panel stand,
as one machine-readable JSON object.

Usage: lkml-panel-state.py <thread-id> [--remote]
       lkml-panel-state.py --export-file <f> --status-file <f>
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

An address must match ^@[a-z0-9][a-z0-9-]*$; a malformed one is dropped
with a reason (and, being a reason, blocks CONVERGED: a seat silently
dropped from the panel is a seat nobody waits for). A missing or empty
Panel means the roster is unusable.

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
               another target exists
    silent     no tagged message from the seat at all

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

Status -- precedence top to bottom, first match wins:

    NEEDS-OPERATOR  the thread is flagged
    CONVERGED       usable roster; a current target; every panel seat
                    positive; the secretary's message on target,
                    well-formed and saying CONVERGED; quiescent; the
                    target sources agree; no other reason. verdict is
                    the secretary's Panel-Verdict -- but SIGNED-OFF on a
                    target version above 1, or RESPIN on version 1, is a
                    contradiction and not CONVERGED
    STALLED         quiescent but not converged: nobody will wake, the
                    operator must look
    IN-PROGRESS     otherwise

A secretary saying CONVERGED while the facts disagree is a named reason
("secretary says CONVERGED but @tests is blocking"): that is the false
green this script exists to catch.

Output (null, never an omitted key, for what is unknown):

    {"schema": "lkml-panel-state/1", "thread", "subject",
     "status", "verdict",          # verdict only when CONVERGED
     "target": {"branch","sha","version","set_by","set_at","source"},
     "roster": {"author","panel","secretary","version_limit","frozen_head"},
     "seats": [{"seat","state","verdict","message_id","version","sha"}],
     "secretary": {"message_id","version","status","verdict",
                   "on_target","malformed"},
     "postmaster": {"quiescent","flagged","flag_reason","live_runs",
                    "pending_retries","held","unrouted"},
     "bundle": {"base","tip","branch"},   # RESPIN + a Frozen-Head only
     "reasons": [...]}                    # empty only for CONVERGED
"""

import json
import re
import subprocess
import sys

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
ROSTER_KEYS = ("Author", "Panel", "Secretary", "Version-Limit", "Frozen-Head")
ROSTER_LINE_RE = re.compile(r"^(" + "|".join(ROSTER_KEYS) + r"):(.*)$")
PANEL_LINE_RE = re.compile(r"^Panel-[A-Za-z]+:")
PANEL_KNOWN_RE = re.compile(r"^Panel-(?:Version|Status|Verdict):")
SECRETARY_KEYS = ("Panel-Version", "Panel-Status", "Panel-Verdict")

USAGE = """\
Usage: lkml-panel-state.py <thread-id> [--remote]
       lkml-panel-state.py --export-file <f> --status-file <f>
       lkml-panel-state.py -h|--help"""


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
    return int(v) if re.fullmatch(r"[0-9]+", v) else None


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
         "sha": None, "version": None, "tags": []}
    if "error" in raw:
        return m
    if not (isinstance(raw.get("from"), str) and isinstance(raw.get("body"), str)
            and isinstance(raw.get("headers"), list)):
        return m
    m.update(ok=True, id=raw.get("id"), body=raw["body"],
             headers=raw["headers"], date=raw.get("date"),
             subject=raw.get("subject"))
    m["from"] = raw["from"].strip()
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


def parse_roster(root):
    """The roster from the thread root -> (roster, reasons)."""
    roster = {"author": None, "panel": [], "secretary": None,
              "version_limit": None, "frozen_head": None}
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
        if re.fullmatch(r"[0-9]+", seen["Version-Limit"]):
            roster["version_limit"] = int(seen["Version-Limit"])
        else:
            reasons.append(
                f"roster: malformed Version-Limit {seen['Version-Limit']!r} dropped")
    if "Frozen-Head" in seen:
        if FROZEN_HEAD_RE.match(seen["Frozen-Head"]):
            roster["frozen_head"] = seen["Frozen-Head"].lower()
        else:
            reasons.append(
                f"roster: malformed Frozen-Head {seen['Frozen-Head']!r} dropped")
    if not roster["panel"]:
        reasons.append("no panel roster on the thread root")
    return roster, reasons


def opt_int(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        return int(value)
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
        if mail is not None and mail["sha"] != pm["sha"]:
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


def judge_seat(seat, msgs, target):
    """-> (seat entry, reason|None) for one panel seat."""
    tsha = target["sha"] if target else None
    mine = [m for m in msgs if m["ok"] and m["from"] == seat]
    tagged = [m for m in mine if m["tags"]]
    on = [m for m in tagged if tsha is not None and m["sha"] == tsha]
    entry = {"seat": seat, "state": "silent", "verdict": None,
             "message_id": None, "version": None, "sha": None}
    if on:
        m = on[-1]
        tag = pick_tag(m["tags"])
        entry.update(state=seat_state_of(tag), verdict=tag,
                     message_id=m["id"], version=m["version"], sha=m["sha"])
        if entry["state"] == "positive":
            return entry, None
        where = f"v{target['version']}" if target["version"] is not None \
            else f"({target['sha'][:8]})"
        what = "unanswered Question" if tag == "Question" else tag
        return entry, f"{seat}: {what} on {where}"
    if tagged:
        m = tagged[-1]
        entry.update(state="stale", verdict=pick_tag(m["tags"]),
                     message_id=m["id"], version=m["version"], sha=m["sha"])
        seen = target_label({"sha": m["sha"], "version": m["version"]}) \
            if m["sha"] else "a message with no usable X-Review-Target"
        return entry, (f"{seat}: verdict is on {seen}, none on "
                       f"{target_label(target)}")
    return entry, f"{seat}: no verdict on {target_label(target)}"


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
    if not re.fullmatch(r"[0-9]+", vals[0]):
        return None, f"Panel-Version {vals[0]!r} is not a number"
    fields["version"] = int(vals[0])
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


def verdict_contradiction(verdict, target):
    v = target["version"] if target else None
    if v is None:
        return None
    if verdict == "SIGNED-OFF" and v > 1:
        return (f"secretary verdict SIGNED-OFF contradicts target v{v} "
                f"(SIGNED-OFF is only possible on v1)")
    if verdict == "RESPIN" and v == 1:
        return "secretary verdict RESPIN contradicts target v1 (nothing to respin yet)"
    return None


def judge_secretary(msgs, roster, target):
    """-> (secretary entry|None, reasons)."""
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
             "verdict": None, "on_target": False, "malformed": bad}
    if bad:
        return entry, [f"secretary {sec} message {m['id']}: malformed trailer: {bad}"]
    entry.update(fields)
    reasons = []
    tsha = target["sha"] if target else None
    tver = target["version"] if target else None
    entry["on_target"] = (tsha is not None and m["sha"] == tsha
                          and tver is not None and fields["version"] == tver)
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
    return facts, reasons


def build_state(export, status):
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

    bad = [str(m["seq"]) for m in msgs if not m["ok"]]
    if bad:
        reasons.append(f"{len(bad)} unreadable message(s) in the export "
                       f"(seq {', '.join(bad)})")

    target, target_reasons = resolve_target(status, msgs)
    reasons += target_reasons

    seats = []
    for seat in roster["panel"]:
        entry, why = judge_seat(seat, msgs, target)
        seats.append(entry)
        if why:
            reasons.append(why)

    secretary, sec_reasons = judge_secretary(msgs, roster, target)
    reasons += sec_reasons

    pm, pm_reasons = postmaster_facts(status)
    reasons += pm_reasons

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
        contradiction = verdict_contradiction(secretary["verdict"], target)
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
    if verdict == "RESPIN" and roster["frozen_head"]:
        bundle = {"base": roster["frozen_head"], "tip": target["sha"],
                  "branch": target["branch"]}

    return {
        "schema": SCHEMA,
        "thread": export["thread"],
        "subject": opt_str(root["subject"]) if root and root["ok"] else None,
        "status": status_word,
        "verdict": verdict,
        "target": target,
        "roster": roster,
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


def parse_args(argv):
    opts = {"thread": None, "remote": False, "export": None, "status": None,
            "help": False}
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
        state = build_state(export, status)
    except InputError as e:
        sys.stderr.write("Error: " + " ".join(str(e).split()) + "\n")
        return 1
    sys.stdout.write(json.dumps(state, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
