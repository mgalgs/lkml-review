#!/usr/bin/env bash
# lkml-wake-gate-test.sh — Exercise lkml-wake-gate.py.
#
# The gate's decision cases drive the REAL sibling lkml-panel-state.py:
# the point of the gate not copying that logic is that the two cannot
# disagree, and a stub there would test nothing. Fixtures are built by a
# small generated Python helper (fx.py) in the same shape as
# lkml-panel-state-test.sh's: invented ids, @core-style names, fake
# 40-hex shas. The failure cases (a sibling that exits 1 or prints
# non-JSON) copy the gate into a temp dir next to a stub sibling.
#
# Every case asserts the exit code, that stderr is exactly one
# "lkml-wake-gate:" line, and that the line names the expected rule.
#
# Usage: tests/lkml-wake-gate-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
gate_src="${LKML_WAKE_GATE:-$repo_dir/scripts/lkml-wake-gate.py}"

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}
contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}

work="$(mktemp -d)"; tmpdirs+=("$work")

cat > "$work/fx.py" <<'FX'
import json, os

def sha(c):
    return c * 40

A, B, C = sha("a"), sha("b"), sha("c")

ROOT_BODY = "\n".join([
    "Cover letter for the example series.",
    "",
    "Author: @pr-author",
    "Panel: @core, @tests, @docs",
    "Secretary: @secretary",
    "Version-Limit: 4",
    "Frozen-Head: " + "f" * 40,
])

def msg(seq, frm, body, sha=None, ver=None, set_target=None,
        subject="Re: [PATCH v1] Fix the thing", extra=(), to=None, cc=()):
    h = [["From", frm]]
    if sha:
        h.append(["X-Review-Target", "pr/example " + sha])
    if set_target:
        h.append(["X-Review-Target-Set", "pr/example " + set_target])
    if ver is not None:
        h.append(["X-Version", str(ver)])
    h.extend(list(x) for x in extra)
    return {"seq": seq, "id": "m%03d" % seq, "headers": h, "from": frm,
            "to": to if to is not None else ["@panel"], "cc": list(cc), "subject": subject,
            "date": "Mon, 02 Mar 2026 10:%02d:00 +0000" % (seq % 60),
            "in_reply_to": None, "body": body, "attachments": []}

def root(sha=A, ver=1, body=ROOT_BODY, set_target=True):
    return msg(1, "@pr-author", body, sha=sha, ver=ver,
               set_target=sha if set_target else None,
               subject="[PATCH v1] Fix the thing")

def export(msgs, thread="t-example"):
    return {"thread": thread, "messages": msgs, "senders": {}, "addressed": []}

def status(sha=A, ver=1, thread="t-example", target="default", **kw):
    st = {"thread": thread, "unrouted": 0, "flag": None, "grant": False,
          "review_target": None, "spawns": 0, "runs": [], "retries": [],
          "held": []}
    if target == "default":
        st["review_target"] = {"branch": "pr/example", "sha": sha,
                               "version": ver, "set_by": "@pr-author",
                               "set_at": "2026-03-02T10:00:00Z"}
    else:
        st["review_target"] = target
    st.update(kw)
    return st

def upstream(seq, head, mode=None, extra=(), to=None):
    # The postmaster's upstream-moved mail, with the X-Lkml-* push headers.
    h = [["X-Upstream-Head", "pr/example " + head]]
    if mode:
        h.append(["X-Lkml-Push-Mode", mode])
    h.extend(list(x) for x in extra)
    return msg(seq, "@postmaster", "The human author pushed a new head.",
               extra=h, to=to)

def cover(seq, target, ver, body):
    return msg(seq, "@pr-author", body, sha=target, ver=ver, set_target=target,
               subject="Re: [PATCH v%d 0/0] Fix the thing" % ver)

def reviewed(seq, who, sha=A, ver=1, cc=(), to=None):
    return msg(seq, who, "Reviewed-by: %s <%s@example.com>" % (who, who[1:]),
               sha=sha, ver=ver, cc=cc, to=to)

def trailer(seq, status="CONVERGED", verdict="SIGNED-OFF", sha=A, ver=1):
    lines = ["Summary.", "", "Panel-Version: %d" % ver, "Panel-Status: " + status]
    if verdict:
        lines.append("Panel-Verdict: " + verdict)
    return msg(seq, "@secretary", "\n".join(lines), sha=sha, ver=ver,
               to=["@operator"])

# Every seat positive on the target; the last verdict (m004) Cc's the
# secretary, as a reviewer's verdict reply does when the root names one.
def settled(cc=("@secretary",), to=None, extra=()):
    return export([root(), reviewed(2, "@core"), reviewed(3, "@tests"),
                   reviewed(4, "@docs", cc=cc, to=to)] + list(extra))

def run_rec(agent, rid, sha=A, replies=0, state="harvested",
            at="2026-03-02T10:30:00Z", trigger="m003"):
    # One postmaster status runs[] entry: agent is the bare fleet name.
    live = state == "live"
    return {"run_id": rid, "agent": agent, "state": state,
            "run_dir": "/runs/" + rid, "resumed": None, "trigger": trigger,
            "review_target_sha": sha, "review_target_version": 1,
            "harvested_at": None if live else at,
            "replies": None if live else replies,
            "reply_files": None if live else max(replies, 1),
            "outcome": None if live else "clean", "retry_of": None}

def retry_rec(agent, state="pending", reason="malformed"):
    return {"agent": agent, "state": state, "attempt": 0, "due_s": 0,
            "reason": reason}

# core reviewed, tests requested changes (m003), docs has not answered.
def objecting(verdict="Changes-requested: the loop leaks."):
    return export([root(), reviewed(2, "@core"),
                   msg(3, "@tests", verdict, sha=A, ver=1)])

def write(d, exp, st):
    with open(os.path.join(d, "export.json"), "w") as f:
        json.dump(exp, f)
    with open(os.path.join(d, "status.json"), "w") as f:
        json.dump(st, f)
FX

# gen <name>: run a python snippet (stdin) with fx in scope and $D set to
# the case directory; the snippet writes export.json/status.json there.
gen() {
    local d="$work/case-$1"; mkdir -p -- "$d"
    PYTHONPATH="$work" D="$d" python3 -c '
import os, sys
from fx import *
D = os.environ["D"]
exec(sys.stdin.read())
'
}

# run <case> [VAR=value ...]: the gate with a complete, valid env for the
# case (author seat, trigger m002), overridden by the extra assignments.
# GATE picks the script under test; UNSET names one var to remove.
# FS_HOOK_AGENT defaults to the BARE fleet name, as the postmaster passes
# it; the roster's addresses carry the '@'.
GATE="$gate_src"; UNSET=""
RC=0; ERR=""
run() {
    local d="$work/case-$1" v; shift
    local -A envs=([FS_HOOK_EVENT]=wake-when [FS_HOOK_THREAD]=t-example
                   [FS_HOOK_AGENT]=pr-author [FS_HOOK_MESSAGE]=m002
                   [FS_HOOK_EXPORT_FILE]="$d/export.json"
                   [FS_HOOK_STATUS_FILE]="$d/status.json")
    local args=()
    for v in "$@"; do envs["${v%%=*}"]="${v#*=}"; done
    [[ -n "$UNSET" ]] && unset "envs[$UNSET]"
    for v in "${!envs[@]}"; do args+=("$v=${envs[$v]}"); done
    ERR="$(env -i PATH="$PATH" "${args[@]}" "$GATE" 2>&1 >/dev/null)"; RC=$?
}

# expect <label> <rc> <rule-or-""> [substring...]: assert the last run.
expect() {
    local label="$1" rc="$2" rule="$3"; shift 3
    check "$label: exit $rc" "$rc" "$RC"
    check "$label: one lkml-wake-gate: line" "1/1" \
        "$(grep -c '^lkml-wake-gate: ' <<<"$ERR")/$(wc -l <<<"$ERR" | tr -d ' ')"
    local want
    [[ -n "$rule" ]] && contains "$label: names rule $rule" "$ERR" "(rule $rule)"
    for want in "$@"; do contains "$label: stderr has '$want'" "$ERR" "$want"; done
}

[[ -x "$gate_src" ]] || { echo "not executable: $gate_src" >&2; exit 1; }

# The standard panel is @core, @tests, @docs; the trigger is m002.
gen silent <<'PY'
write(D, export([root(), reviewed(2, "@core")]), status())
PY

printf '\n== required env ==\n'
for v in FS_HOOK_AGENT FS_HOOK_MESSAGE FS_HOOK_EXPORT_FILE FS_HOOK_STATUS_FILE; do
    UNSET="$v" run silent
    expect "$v unset" 2 "" "$v"
    UNSET="" run silent "$v="
    expect "$v empty" 2 "" "$v"
done

printf '\n== trigger and sibling failures ==\n'
UNSET="" run silent FS_HOOK_MESSAGE=m999
expect "trigger id not in the export" 2 "" "m999"

gen noauthor <<'PY'
write(D, export([root(body=ROOT_BODY.replace("Author: @pr-author\n", "")),
                 reviewed(2, "@core")]), status())
PY
run noauthor
expect "roster without an author" 2 "a"
run noauthor FS_HOOK_AGENT=secretary
expect "roster without an author, secretary seat" 2 "a"

# A root naming no Author, Panel or Secretary is not a PR panel: the
# secretary invoked solo there (series review, To: @secretary) wakes.
gen solo <<'PY'
write(D, export([msg(1, "@operator", "Summarize the series review, please.",
                     subject="[PATCH 0/2] Example series", to=["@secretary"]),
                 msg(2, "@operator", "Please summarize now.",
                     to=["@secretary"])]), status(target=None))
PY
run solo FS_HOOK_AGENT=secretary
expect "secretary solo on a non-panel thread wakes, no error" 0 "b"
run solo FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m001
expect "secretary solo, the root itself as trigger" 0 "b"

stub_case() { # stub_case <name> <stub script body>: gate beside a stub sibling
    local dir="$work/stub-$1"; mkdir -p -- "$dir"
    cp -- "$gate_src" "$dir/lkml-wake-gate.py"
    printf '%s\n' "#!/usr/bin/env python3" "$2" > "$dir/lkml-panel-state.py"
    chmod +x "$dir/lkml-wake-gate.py" "$dir/lkml-panel-state.py"
}
stub_case exit1 'import sys; sys.stderr.write("Error: boom\n"); sys.exit(1)'
GATE="$work/stub-exit1/lkml-wake-gate.py" run silent
expect "sibling exits 1" 2 "" "exited 1" "boom"
stub_case notjson 'print("this is not json")'
GATE="$work/stub-notjson/lkml-wake-gate.py" run silent
expect "sibling prints non-JSON" 2 "" "unparsable"
stub_case schema 'print("{\"schema\": \"lkml-panel-state/9\"}")'
GATE="$work/stub-schema/lkml-wake-gate.py" run silent
expect "sibling answers another schema" 2 "" "schema"
GATE="$gate_src"

printf '\n== rules b-e: always wake ==\n'
run silent FS_HOOK_AGENT=core
expect "agent is neither the author nor the secretary" 0 "b"
run silent FS_HOOK_AGENT=@core
expect "agent is neither the author nor the secretary, '@' form" 0 "b"

gen nosecretary <<'PY'
write(D, export([root(body=ROOT_BODY.replace("Secretary: @secretary\n", "")),
                 reviewed(2, "@core")]), status())
PY
run nosecretary FS_HOOK_AGENT=secretary
expect "the root names no Secretary: that seat is not gated" 0 "b"

gen upstream <<'PY'
write(D, export([root(), msg(2, "@core", "Reviewed-by: C", sha=A, ver=1,
                             extra=[["x-upstream-head", "pr/example " + C]])]),
      status())
PY
run upstream
expect "trigger carries X-Upstream-Head, seats silent" 0 "c"

gen secretary <<'PY'
write(D, export([root(), msg(2, "@secretary", "Panel-Version: 1\nPanel-Status: IN-PROGRESS",
                             sha=A, ver=1)]), status())
PY
run secretary
expect "trigger from the secretary, seats silent" 0 "d"

gen operator <<'PY'
write(D, export([root(), msg(2, "operator@example.com", "Please look again.",
                             sha=A, ver=1)]), status())
PY
run operator
expect "trigger from an operator address, seats silent" 0 "d"

gen roottrigger <<'PY'
write(D, export([root(), reviewed(2, "@core")]), status())
PY
run roottrigger FS_HOOK_MESSAGE=m001
expect "trigger is the root, seats silent" 0 "d"

gen notarget <<'PY'
write(D, export([root(set_target=False), reviewed(2, "@core")]), status(target=None))
PY
run notarget
expect "no target" 0 "e"

gen notargetsha <<'PY'
write(D, export([root(set_target=False), reviewed(2, "@core")]),
      status(target={"branch": "pr/example", "sha": None, "version": None,
                     "set_by": None, "set_at": None}))
PY
run notargetsha
expect "target without a sha" 0 "e"

printf '\n== rules f and h: the reviewers decide ==\n'
run silent
expect "one reviewer answered, two silent" 1 "h" \
    "defer @pr-author" "@tests (silent)" "@docs (silent)"
case "$ERR" in
    *@core*) no "the answered reviewer is not named as waited on" "$ERR" ;;
    *) ok "the answered reviewer is not named as waited on" ;;
esac
run silent FS_HOOK_AGENT=@pr-author
expect "author seat given in '@' form also defers" 1 "h" "defer @pr-author"

gen stale <<'PY'
write(D, export([root(), reviewed(2, "@core"), reviewed(3, "@tests"),
                 reviewed(4, "@docs", sha=B)]), status())
PY
run stale
expect "@docs only tagged an older target, @tests replied" 1 "h" \
    "@docs (stale)"
case "$ERR" in
    *@tests*) no "the answered @tests is not named" "$ERR" ;;
    *) ok "the answered @tests is not named" ;;
esac

gen mixed <<'PY'
write(D, export([root(), reviewed(2, "@core"),
                 msg(3, "@tests", "Changes-requested: the loop leaks.", sha=A, ver=1),
                 msg(4, "@docs", "Question: why a new flag?", sha=A, ver=1)]),
      status())
PY
run mixed
expect "all three on target: reviewed, changes-requested, question" 0 "f"
run mixed FS_HOOK_MESSAGE=m003
expect "same, triggered by the blocking reviewer" 0 "f"

gen overruled <<'PY'
write(D, export([root(), msg(2, "@tests", "Changes-requested", sha=A, ver=1),
                 msg(3, "@core", "Overrule: m002\n\nReviewed-by: C", sha=A, ver=1),
                 reviewed(4, "@docs")]),
      status())
PY
run overruled FS_HOOK_MESSAGE=m003
expect "@core's ruling overrules @tests: every seat answered" 0 "f"

printf '\n== rule g: a silent waiting seat does not strand the author ==\n'
gen gsilent <<'PY'
write(D, objecting(), status(runs=[run_rec("docs", "r-docs")]))
PY
run gsilent FS_HOOK_MESSAGE=m003
expect "a seat blocks, the waiting seat's run at the target posted nothing" 0 "g" \
    "@docs (run r-docs)"
# The re-gate after a zero-reply harvest passes the deferred message.
run gsilent FS_HOOK_MESSAGE=m002
expect "same, re-gated with an earlier deferred message" 0 "g"

gen gquestion <<'PY'
write(D, objecting("Question: why a new flag?"),
      status(runs=[run_rec("docs", "r-docs")]))
PY
run gquestion FS_HOOK_MESSAGE=m003
expect "a question counts as an objection" 0 "g"

gen gatform <<'PY'
write(D, objecting(), status(runs=[run_rec("@docs", "r-docs")]))
PY
run gatform FS_HOOK_MESSAGE=m003
expect "a runs[] agent given in '@' form still matches" 0 "g"

gen gnorun <<'PY'
write(D, objecting(), status(runs=[run_rec("core", "r-core", replies=1)]))
PY
run gnorun FS_HOOK_MESSAGE=m003
expect "the waiting seat has no run at all: keep waiting" 1 "h" "@docs (silent)"

gen goldsha <<'PY'
write(D, objecting(), status(runs=[run_rec("docs", "r-docs", sha=B)]))
PY
run goldsha FS_HOOK_MESSAGE=m003
expect "the silent run was on an older target: keep waiting" 1 "h"

gen glive <<'PY'
write(D, objecting(), status(runs=[
    run_rec("docs", "r-docs-1", at="2026-03-02T10:30:00Z"),
    run_rec("docs", "r-docs-2", state="live")]))
PY
run glive FS_HOOK_MESSAGE=m003
expect "a live run at the target may still reply: keep waiting" 1 "h"

gen gnewest <<'PY'
write(D, objecting(), status(runs=[
    run_rec("docs", "r-docs-2", replies=1, at="2026-03-02T10:40:00Z"),
    run_rec("docs", "r-docs-1", replies=0, at="2026-03-02T10:30:00Z")]))
PY
run gnewest FS_HOOK_MESSAGE=m003
expect "the newest run replied (to no verdict): keep waiting" 1 "h"

gen gnewestsilent <<'PY'
write(D, objecting(), status(runs=[
    run_rec("docs", "r-docs-1", replies=1, at="2026-03-02T10:30:00Z"),
    run_rec("docs", "r-docs-2", replies=0, at="2026-03-02T10:40:00Z")]))
PY
run gnewestsilent FS_HOOK_MESSAGE=m003
expect "the newest run is the silent one" 0 "g" "@docs (run r-docs-2)"

gen gprehistory <<'PY'
r = run_rec("docs", "r-docs")
r.update(harvested_at=None, replies=None, reply_files=None, outcome=None)
write(D, objecting(), status(runs=[r]))
PY
run gprehistory FS_HOOK_MESSAGE=m003
expect "a record from before replies existed proves nothing: keep waiting" 1 "h"

gen gretry <<'PY'
write(D, objecting(), status(runs=[run_rec("docs", "r-docs")],
                             retries=[retry_rec("docs")]))
PY
run gretry FS_HOOK_MESSAGE=m003
expect "a pending retry will run the seat again: keep waiting" 1 "h"

gen gretrydone <<'PY'
write(D, objecting(), status(runs=[run_rec("docs", "r-docs")],
                             retries=[retry_rec("docs", state="exhausted", reason="failed"),
                                      retry_rec("core")]))
PY
run gretrydone FS_HOOK_MESSAGE=m003
expect "an exhausted retry, or another seat's, does not hold the author" 0 "g"

gen gtwo <<'PY'
e = export([root(), msg(2, "@tests", "Changes-requested: the loop leaks.", sha=A, ver=1)])
write(D, e, status(runs=[run_rec("docs", "r-docs")]))
PY
run gtwo
expect "one waiting seat silent, the other never ran: keep waiting" 1 "h" \
    "@core (silent)" "@docs (silent)"

gen gpositive <<'PY'
e = export([root(), reviewed(2, "@core"), reviewed(3, "@tests")])
write(D, e, status(runs=[run_rec("docs", "r-docs")]))
PY
run gpositive FS_HOOK_MESSAGE=m003
expect "no seat objects: the author has nothing to answer, keep waiting" 1 "h"

printf '\n== escalate: the effective roster ==\n'
gen esc <<'PY'
# The root's panel is core/tests/docs; the human's push escalated in
# @security. @security replies (m003) while the other three are silent.
D1 = sha("1")
write(D, export([root(), upstream(2, D1, mode="escalate",
                                  extra=[["X-Lkml-Tier", "full"], ["X-Lkml-Add-Seats", "security"]]),
                 reviewed(3, "@security")]),
      status())
PY
run esc FS_HOOK_MESSAGE=m003
expect "an escalated-in seat's reply is reviewer chatter, not rule d" 1 "h" \
    "@core (silent)" "@tests (silent)" "@docs (silent)"

printf '\n== carry and recheck versions ==\n'
gen re <<'PY'
# v1 converged at F with all three seats positive; the human's push H asks
# for a recheck of @core only; the author posted v2 on H. @core has only a
# stale v1 verdict (nothing carries); @tests and @docs carry from v1.
F, D1 = sha("f"), sha("1")
e = [root(sha=F, body=ROOT_BODY.replace("f" * 40, F)),
     reviewed(2, "@core", sha=F), reviewed(3, "@tests", sha=F), reviewed(4, "@docs", sha=F),
     upstream(30, D1, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "core"]]),
     cover(31, D1, 2, "Small delta.\n\nFrozen-Head: " + D1),
     reviewed(40, "@docs", sha=D1, ver=2)]
write(D, export(e), status(sha=D1, ver=2))
PY
run re FS_HOOK_MESSAGE=m040
expect "recheck version: only the listed seat is waited on" 1 "h" "@core (stale)"
case "$ERR" in
    *@tests*|*@docs*) no "carried seats are not named as waited on" "$ERR" ;;
    *) ok "carried seats are not named as waited on" ;;
esac

gen re2 <<'PY'
F, D1 = sha("f"), sha("1")
e = [root(sha=F, body=ROOT_BODY.replace("f" * 40, F)),
     reviewed(2, "@core", sha=F), reviewed(3, "@tests", sha=F), reviewed(4, "@docs", sha=F),
     upstream(30, D1, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "core"]]),
     cover(31, D1, 2, "Small delta.\n\nFrozen-Head: " + D1),
     reviewed(40, "@core", sha=D1, ver=2)]
write(D, export(e), status(sha=D1, ver=2))
PY
run re2 FS_HOOK_MESSAGE=m040
expect "recheck version: the listed seat answered, carried seats count" 0 "f"

gen carry <<'PY'
# A carry version: every seat carries, so nobody is outstanding when a late
# panel reply arrives.
F, D1 = sha("f"), sha("1")
e = [root(sha=F, body=ROOT_BODY.replace("f" * 40, F)),
     reviewed(2, "@core", sha=F), reviewed(3, "@tests", sha=F), reviewed(4, "@docs", sha=F),
     upstream(30, D1, mode="carry", to=["@operator"]),
     reviewed(31, "@core", sha=F)]
write(D, export(e), status(sha=F, ver=1))
PY
run carry FS_HOOK_MESSAGE=m031
expect "carry version: every seat carried, a late reply wakes the author" 0 "f"


printf '\n== rule i: the author skips what the secretary is woken on ==\n'
gen allsettled <<'PY'
write(D, settled(), status())
PY
run allsettled FS_HOOK_MESSAGE=m004
expect "every seat positive, the trigger Cc's the secretary" 3 "i" \
    "skip @pr-author" "@secretary"

gen allsettledto <<'PY'
write(D, settled(cc=(), to=["@pr-author", "@secretary"]), status())
PY
run allsettledto FS_HOOK_MESSAGE=m004
expect "every seat positive, the trigger is To: the secretary" 3 "i"

gen allsettlednocc <<'PY'
write(D, settled(cc=()), status())
PY
run allsettlednocc FS_HOOK_MESSAGE=m004
expect "every seat positive, the trigger missed the secretary: wake the author" 0 "f"

gen settledoverruled <<'PY'
write(D, export([root(), msg(2, "@tests", "Changes-requested", sha=A, ver=1),
                 msg(3, "@core", "Overrule: m002\n\nReviewed-by: C", sha=A, ver=1),
                 reviewed(4, "@docs", cc=["@secretary"])]), status())
PY
run settledoverruled FS_HOOK_MESSAGE=m004
expect "an overruled seat counts as settled" 3 "i"

# None / some / all of the seats settled, each trigger Cc'ing the secretary.
gen nonesettled <<'PY'
write(D, export([root(),
                 msg(2, "@core", "Changes-requested: no.", sha=A, ver=1),
                 msg(3, "@tests", "Changes-requested: no.", sha=A, ver=1),
                 msg(4, "@docs", "Question: why?", sha=A, ver=1, cc=["@secretary"])]),
      status())
PY
run nonesettled FS_HOOK_MESSAGE=m004
expect "no seat settled, every seat answered, Cc the secretary" 0 "f"
gen somesettled <<'PY'
write(D, export([root(), reviewed(2, "@core"),
                 msg(3, "@tests", "Changes-requested: no.", sha=A, ver=1),
                 reviewed(4, "@docs", cc=["@secretary"])]), status())
PY
run somesettled FS_HOOK_MESSAGE=m004
expect "some seats settled, one blocks, Cc the secretary" 0 "f"

gen settledpush <<'PY'
D1 = sha("1")
write(D, settled(extra=[upstream(5, D1), reviewed(6, "@core", cc=["@secretary"])]),
      status())
PY
run settledpush FS_HOOK_MESSAGE=m006
expect "every seat positive but a push is unanswered: wake the author" 0 "f"
run settledpush FS_HOOK_MESSAGE=m005
expect "the push itself still wakes the author" 0 "c"

gen settledpushcc <<'PY'
D1 = sha("1")
write(D, settled(extra=[upstream(5, D1, to=["@pr-author"])]), status())
PY
run settledpushcc FS_HOOK_MESSAGE=m004
expect "the Cc'd verdict before an unanswered push wakes the author" 0 "f"

gen settledsecdone <<'PY'
write(D, settled(extra=[trailer(5)]), status())
PY
run settledsecdone FS_HOOK_MESSAGE=m004
expect "the secretary already reported on the target: it will skip, so wake the author" 0 "f"

gen settledseclive <<'PY'
write(D, settled(), status(runs=[run_rec("secretary", "r-sec", state="live")]))
PY
run settledseclive FS_HOOK_MESSAGE=m004
expect "a secretary run is live: it will skip, so wake the author" 0 "f"

gen settledsecwoken <<'PY'
write(D, settled(), status(runs=[run_rec("secretary", "r-sec", state="live",
                                         trigger="m004")]))
PY
run settledsecwoken FS_HOOK_MESSAGE=m004
expect "the secretary's live run was woken on this trigger: skip the author" 3 "i"
run settledsecwoken FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: its own run on this trigger is live" 3 "m" "r-sec"

gen mixedcc <<'PY'
write(D, export([root(), reviewed(2, "@core"),
                 msg(3, "@tests", "Changes-requested: the loop leaks.", sha=A, ver=1),
                 msg(4, "@docs", "Question: why a new flag?", sha=A, ver=1,
                     cc=["@secretary"])]),
      status())
PY
run mixedcc FS_HOOK_MESSAGE=m004
expect "a question Cc'ing the secretary still wakes the author" 0 "f"

printf '\n== rules j-o: the secretary seat ==\n'
run allsettled FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: every seat settled" 0 "o" "wake @secretary"
run allsettled FS_HOOK_AGENT=@secretary FS_HOOK_MESSAGE=m004
expect "secretary: every seat settled, '@' form" 0 "o"
run settledoverruled FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: an overruled seat counts as settled" 0 "o"
run allsettlednocc FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: the gate does not read the trigger's addressing" 0 "o"

# None / some / all settled.
run nonesettled FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: no seat settled" 3 "k" "skip @secretary" \
    "@core (blocking)" "@tests (blocking)" "@docs (question)"
run somesettled FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: some seats settled, one blocks" 3 "k" "@tests (blocking)"
case "$ERR" in
    *@core*|*@docs*) no "secretary: settled seats are not named" "$ERR" ;;
    *) ok "secretary: settled seats are not named" ;;
esac
run silent FS_HOOK_AGENT=secretary
expect "secretary: two seats silent" 3 "k" "@tests (silent)" "@docs (silent)"
run stale FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: a stale seat is not settled" 3 "k" "@docs (stale)"
run notarget FS_HOOK_AGENT=secretary
expect "secretary: no target, nothing is settled on it" 3 "k"

run settledpush FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m006
expect "secretary: a push is unanswered" 3 "l"

gen carrysec <<'PY'
# A carry version with every seat carried and no secretary trailer yet.
F, D1 = sha("f"), sha("1")
e = [root(sha=F, body=ROOT_BODY.replace("f" * 40, F)),
     reviewed(2, "@core", sha=F), reviewed(3, "@tests", sha=F), reviewed(4, "@docs", sha=F),
     upstream(30, D1, mode="carry", to=["@operator"]),
     reviewed(31, "@core", sha=F, cc=["@secretary"])]
write(D, export(e), status(sha=F, ver=1))
PY
run carrysec FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m031
expect "secretary: a carry push is answered by the carry" 0 "o"

# A secretary run live / pending a retry / neither.
gen seclive <<'PY'
write(D, settled(), status(runs=[run_rec("secretary", "r-sec", state="live")]))
PY
run seclive FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: a secretary run is live" 3 "m" "r-sec"
gen secliveat <<'PY'
write(D, settled(), status(runs=[run_rec("@secretary", "r-sec", state="live")]))
PY
run secliveat FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: a live run's agent in '@' form still matches" 3 "m"
gen secretry <<'PY'
write(D, settled(), status(runs=[run_rec("secretary", "r-sec")],
                           retries=[retry_rec("secretary")]))
PY
run secretry FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: a secretary retry is pending" 3 "m" "retry"
gen secidle <<'PY'
write(D, settled(), status(runs=[run_rec("secretary", "r-sec"),
                                 run_rec("core", "r-core", state="live")],
                           retries=[retry_rec("secretary", state="exhausted"),
                                    retry_rec("docs")]))
PY
run secidle FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: a harvested run, an exhausted retry, other seats' runs do not hold it" 0 "o"

# The secretary has posted on the target / on an older one.
run settledsecdone FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: already posted on the target" 3 "n" "m005"
gen secinprogress <<'PY'
write(D, settled(extra=[trailer(5, status="IN-PROGRESS", verdict=None)]), status())
PY
run secinprogress FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: an IN-PROGRESS on the target is a post on it" 3 "n"
gen secoldtarget <<'PY'
write(D, settled(extra=[trailer(5, sha=B)]), status())
PY
run secoldtarget FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: a post on an older target does not count" 0 "o"

# The author's or the operator's request always wakes the secretary.
gen secask <<'PY'
write(D, export([root(), reviewed(2, "@core"),
                 msg(3, "@tests", "Changes-requested: no.", sha=A, ver=1),
                 msg(4, "@pr-author", "Version-Limit reached; @tests still blocks.",
                     sha=A, ver=1, to=["@secretary"]),
                 msg(5, "@operator", "Please summarize.", sha=A, ver=1,
                     to=["@secretary"]),
                 trailer(6, status="IN-PROGRESS", verdict=None)]),
      status(runs=[run_rec("secretary", "r-sec", state="live")]))
PY
run secask FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: the author's request wakes it regardless" 0 "j" "@pr-author"
run secask FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m005
expect "secretary: the operator's request wakes it regardless" 0 "j" "@operator"
run secask FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m003
expect "secretary: the same thread, a reviewer's trigger, skips" 3 "k"

printf '\n== --help ==\n'
HELP="$("$gate_src" --help 2>&1)"; HRC=$?
check "--help exits 0" "0" "$HRC"
contains "--help mentions wake-when" "$HELP" "wake-when"
contains "--help says a carried verdict counts as answered" "$HELP" "carried"
contains "--help documents exit 3" "$HELP" "3 skips"
check "-h prints the same text" "$HELP" "$("$gate_src" -h 2>&1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
