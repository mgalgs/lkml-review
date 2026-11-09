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
                   [FS_HOOK_STATUS_FILE]="$d/status.json"
                   [LKML_CAPACITY_PROMETHEUS]="$prom_url"
                   [LKML_CAPACITY_SELECTOR]='{instance=~"gpu-a:.*"}'
                   [FORK_SANDBOX_HOOKS_DIR]="$work/hooks-none")
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

# A real Prometheus stand-in on 127.0.0.1 for the capacity read on child
# threads. It answers /api/v1/query with instant-query JSON from
# $work/prom.json, which `prom` rewrites between cases, and logs each
# PromQL it receives to $work/prom.log, which `promql` reads back.
# prom.json is {"waiting": V, "preempt": V, "fail": MODE, "on": WHICH}:
# V is the value string answered; MODE, when set, replaces the answer
# for the query WHICH ("waiting", "preempt" or "all") with a failure.
cat > "$work/prom.py" <<'PROM'
import http.server, json, os, sys, time, urllib.parse
W = sys.argv[1]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(u.query).get("query", [""])[0]
        with open(os.path.join(W, "prom.log"), "a") as f:
            f.write(u.path + " " + q + "\n")
        with open(os.path.join(W, "prom.json")) as f:
            mode = json.load(f)
        which = "preempt" if "preemptions" in q else "waiting"
        fail = mode.get("fail") if mode.get("on") in ("all", which) else None
        vec = lambda r: json.dumps({"status": "success", "data": {
            "resultType": "vector", "result": r}}).encode()
        if fail == "500":
            return self.send(500, b"internal error", "text/plain")
        if fail == "hang":
            time.sleep(20)
            return self.send(200, vec([]))
        if fail == "nonjson":
            return self.send(200, b"<html>not json</html>", "text/html")
        if fail == "error":
            return self.send(400, json.dumps({"status": "error", "errorType":
                             "bad_data", "error": "parse error"}).encode())
        if fail == "error200":
            return self.send(200, json.dumps({"status": "error", "errorType":
                             "bad_data", "error": "parse error"}).encode())
        if fail == "empty":
            return self.send(200, vec([]))
        v = mode[which] if fail is None else fail.split(":", 1)[1]
        self.send(200, vec([{"metric": {}, "value": [1767225600.123, v]}]))

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
with open(os.path.join(W, "prom.port.tmp"), "w") as f:
    f.write(str(srv.server_address[1]))
os.rename(os.path.join(W, "prom.port.tmp"), os.path.join(W, "prom.port"))
srv.serve_forever()
PROM
prom() { printf '%s\n' "$1" > "$work/prom.json"; : > "$work/prom.log"; }
promql() { cat -- "$work/prom.log"; }
# Busy by default: a capacity read that leaks onto a main thread defers
# a wake there, and shows in prom.log.
prom '{"waiting": "5", "preempt": "5"}'
python3 "$work/prom.py" "$work" & prom_pid=$!
trap 'kill "$prom_pid" 2>/dev/null; cleanup' EXIT
for _ in $(seq 100); do [[ -s "$work/prom.port" ]] && break; sleep 0.05; done
[[ -s "$work/prom.port" ]] || { echo "the test Prometheus did not start" >&2; exit 1; }
prom_url="http://127.0.0.1:$(cat "$work/prom.port")"

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

printf '\n== advisory seats are never waited for ==\n'
# @second sits on the panel and the root names it Advisory; the gating
# seats @core, @tests and @docs answer, @second has not.
cat >> "$work/fx.py" <<'FX2'
ADV_BODY = ROOT_BODY.replace("@core, @tests, @docs", "@core, @tests, @docs, @second")

def adv(extra=(), advisory=True, cc=("@secretary",), tests="Reviewed-by: T"):
    body = ADV_BODY + ("\nAdvisory: @second" if advisory else "")
    return export([root(body=body), reviewed(2, "@core"),
                   msg(3, "@tests", tests, sha=A, ver=1),
                   reviewed(4, "@docs", cc=cc)] + list(extra))
FX2
gen advsilent <<'PY'
write(D, adv(), status())
PY
run advsilent FS_HOOK_MESSAGE=m004
expect "advisory seat silent, gating seats settled, Cc the secretary" 3 "i"
run advsilent FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "secretary: woken though the advisory seat is silent" 0 "o"
case "$ERR" in
    *@second*) no "secretary: the advisory seat is not named" "$ERR" ;;
    *) ok "secretary: the advisory seat is not named" ;;
esac

gen advsilentnocc <<'PY'
write(D, adv(cc=()), status())
PY
run advsilentnocc FS_HOOK_MESSAGE=m004
expect "advisory seat silent, gating seats settled, secretary missed: wake the author" 0 "f"

gen advblocked <<'PY'
write(D, adv(tests="Changes-requested: no."), status())
PY
run advblocked FS_HOOK_MESSAGE=m004
expect "advisory seat silent, a gating seat blocks: every gating seat answered, wake the author" 0 "f"
gen advblockedctl <<'PY'
write(D, adv(tests="Changes-requested: no.", advisory=False), status())
PY
run advblockedctl FS_HOOK_MESSAGE=m004
expect "control: the same seat gating is waited for" 1 "h" "@second (silent)"

gen advlate <<'PY'
write(D, adv(extra=[msg(5, "@second", "NAK", sha=A, ver=1, to=["@pr-author"])], cc=()), status())
PY
run advlate FS_HOOK_MESSAGE=m005
expect "an advisory seat's later reply still wakes the author under the usual rules" 0 "f"
run advlate FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m005
expect "secretary: an advisory NAK does not hold the panel open" 0 "o"

printf '\n== sub-panels: a relayed digest and a child thread ==\n'
cat >> "$work/fx.py" <<'FX3'
CHILD = "0123abcd-4567-89ef-0123-456789abcdef"

# The relay's post of a child digest into the main thread, To: the author.
def relayed(seq, frm="@relay", tagged=True, to=("@pr-author",)):
    h = [["X-Lkml-Sub-Panel", CHILD], ["X-Lkml-Digest-Of", "d0d0d0d0"]] if tagged else []
    return msg(seq, frm, "Findings:\n- blocking | @operability | x.py | fix it\n\n"
               "Digest-Blocking: 1", extra=h, to=list(to))

SUB_BODY = "\n".join([
    "Sub-panel review of the example change.",
    "",
    "Parent-Thread: " + CHILD,
    "Panel: @core, @tests, @docs",
    "Secretary: @secretary",
])

def sub_root():
    return msg(1, "@deploy-bot", SUB_BODY, sha=A, ver=1, set_target=A,
               subject="[PATCH v1] Fix the thing",
               extra=[["X-Lkml-Parent-Thread", CHILD]])

def sub_seat(seq, who, body):
    return msg(seq, who, body, sha=A, ver=1, to=["@deploy-bot"], cc=["@secretary"])
FX3
gen relaymid <<'PY'
write(D, export([root(), reviewed(2, "@core"), relayed(3), relayed(4, tagged=False)]), status())
PY
run relaymid FS_HOOK_MESSAGE=m003
expect "a sub-panel digest wakes the author mid-review" 0 "p" "m003"
run relaymid FS_HOOK_MESSAGE=m004
expect "the same sender untagged is gated as before" 0 "d"
gen relayconv <<'PY'
e = settled(extra=[trailer(5, sha=A), relayed(6), relayed(7, tagged=False)])
write(D, e, status())
PY
run relayconv FS_HOOK_MESSAGE=m006
expect "a sub-panel digest wakes the author after convergence" 0 "p"
run relayconv FS_HOOK_MESSAGE=m007
expect "after convergence the same sender untagged is gated as before" 0 "d"
gen relayseat <<'PY'
write(D, export([root(), reviewed(2, "@core"), relayed(3, frm="@tests")]), status())
PY
run relayseat FS_HOOK_MESSAGE=m003
expect "a panel seat cannot tag its way past the gate" 1 "h" "@docs (silent)"
gen relayother <<'PY'
write(D, export([root(), reviewed(2, "@core"), relayed(3, to=("@operator",))]), status())
PY
run relayother FS_HOOK_MESSAGE=m003
expect "a tagged message not To: the author is gated as before" 0 "d"

# A digest relayed mid-review must not be closed round: the panel settles
# with it unanswered, and the author, not the secretary, is woken.
gen relayopen <<'PY'
write(D, export([root(), reviewed(2, "@core"), relayed(3), reviewed(4, "@tests"),
                 reviewed(5, "@docs", cc=("@secretary",))]), status())
PY
run relayopen FS_HOOK_MESSAGE=m005
expect "an unanswered digest: the settling reply wakes the author, not rule i" 0 "f"
run relayopen FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m005
expect "an unanswered digest holds the secretary" 3 "q" "m003"
for ans in 'msg(6, "@pr-author", "Verdict on v1? Declined: x.py, not a bug.", to=["@secretary"])' \
           'msg(6, "@pr-author", "Declined: x.py, not a bug.", to=["@relay"])' \
           'cover(6, B, 2, "v2.\n\n## Sub-panel\n- x.py: taken")'; do
    gen relayans <<PY
write(D, export([root(), reviewed(2, "@core"), relayed(3), reviewed(4, "@tests"),
                 reviewed(5, "@docs", cc=("@secretary",)), $ans]), status())
PY
    run relayans FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m005
    case "$ERR" in
        *"(rule q)"*) no "an answered digest does not hold the secretary: ${ans%%,*}" "$ERR" ;;
        *) ok "an answered digest does not hold the secretary: ${ans%%,*}" ;;
    esac
done
gen relayans <<'PY'
write(D, export([root(), reviewed(2, "@core"), relayed(3), reviewed(4, "@tests"),
                 reviewed(5, "@docs", cc=("@secretary",)),
                 msg(6, "@pr-author", "Verdict on v1?", to=["@secretary"])]), status())
PY
run relayans FS_HOOK_MESSAGE=m005
expect "an answered digest: rule i skips the author as before" 3 "i"
gen relaynotans <<'PY'
write(D, export([root(), reviewed(2, "@core"),
                 msg(3, "@pr-author", "A reply to a reviewer.", to=["@core"]),
                 relayed(4), reviewed(5, "@tests"), reviewed(6, "@docs", cc=("@secretary",))]),
      status())
PY
run relaynotans FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m006
expect "an author message from before the digest does not answer it" 3 "q" "m004"
gen attached <<'PY'
r = root()
r["attachments"] = [{"name": "pr.md", "bytes": 9458},
                    {"name": "sub-panel-digest.md", "bytes": 2048}]
write(D, export([r, reviewed(2, "@core"), reviewed(3, "@tests"),
                 reviewed(4, "@docs", cc=("@secretary",))]), status())
PY
run attached FS_HOOK_MESSAGE=m004
expect "an attached digest: the settling reply wakes the author" 0 "f"
run attached FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "an attached digest holds the secretary" 3 "q" "m001"

check "main threads: no capacity read, with every variable set" "" "$(promql)"
gen childpart <<'PY'
write(D, export([sub_root(), sub_seat(2, "@core", "Changes-requested"),
                 sub_seat(3, "@tests", "Reviewed-by: T")]), status())
PY
run childpart FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m003
expect "child: the secretary waits while a seat has not replied" 3 "k" "@docs (silent)"
case "$ERR" in
    *@core*) no "child: a blocking seat has answered, and is not named" "$ERR" ;;
    *) ok "child: a blocking seat has answered, and is not named" ;;
esac
gen childall <<'PY'
write(D, export([sub_root(), sub_seat(2, "@core", "Changes-requested"),
                 sub_seat(3, "@tests", "Reviewed-by: T"), sub_seat(4, "@docs", "NAK")]),
      status())
PY
check "child: a rule k skip reads no capacity" "" "$(promql)"
prom '{"waiting": "0", "preempt": "0"}'
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "child: the secretary wakes once every seat has replied, whatever the verdicts" 0 "o"
gen childdone <<'PY'
d = msg(5, "@secretary", "Digest.\n\nDigest-Blocking: 1\nPanel-Version: 1\n"
        "Panel-Status: CONVERGED\nPanel-Verdict: SIGNED-OFF", sha=A, ver=1,
        to=["@deploy-bot"])
write(D, export([sub_root(), sub_seat(2, "@core", "Changes-requested"),
                 sub_seat(3, "@tests", "Reviewed-by: T"), sub_seat(4, "@docs", "NAK"), d,
                 sub_seat(6, "@docs", "NAK again")]), status())
PY
prom '{"waiting": "0", "preempt": "0"}'
run childdone FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m006
expect "child: one digest; a later reply does not wake the secretary again" 3 "n"
check "child: a skip reads no capacity" "" "$(promql)"
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004 FS_HOOK_AGENT=core
expect "child: a reviewer seat passes the rules by rule b" 0 "b"
# Rule h is the one rule that defers before the capacity read: an author
# seat on a child whose root wrongly names an Author.
gen childauthor <<'PY'
r = sub_root()
r["body"] = SUB_BODY + "\nAuthor: @pr-author"
write(D, export([r, sub_seat(2, "@core", "Reviewed-by: C")]), status())
PY
prom '{"waiting": "0", "preempt": "0"}'
run childauthor
expect "child: an Author seat waiting on reviewers defers by rule h" 1 "h" "@docs (silent)"
check "child: a rule h defer reads no capacity" "" "$(promql)"

printf '\n== child: a gate error defers ==\n'
# The postmaster wakes a seat whose gate exits 2; on a child that would
# spawn without a capacity check, so every gate error there defers.
GATE="$work/stub-exit1/lkml-wake-gate.py" run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "child: panel-state failing defers" 1 "" \
    "lkml-wake-gate: child: defer: gate error: lkml-panel-state.py exited 1" "boom"
GATE="$work/stub-exit1/lkml-wake-gate.py" run silent
expect "main: panel-state failing still errors" 2 "" "lkml-wake-gate: error: lkml-panel-state.py exited 1"
GATE="$work/stub-notjson/lkml-wake-gate.py" run childall FS_HOOK_AGENT=core FS_HOOK_MESSAGE=m004
expect "child: panel-state printing non-JSON defers" 1 "" "child: defer: gate error: " "unparsable"
for v in FS_HOOK_AGENT FS_HOOK_MESSAGE FS_HOOK_STATUS_FILE; do
    UNSET="$v" run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
    expect "child: $v unset defers" 1 "" "child: defer: gate error: $v"
done
UNSET=""
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m999
expect "child: a trigger not in the export defers" 1 "" "child: defer: gate error: " "m999"
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004 "FS_HOOK_EXPORT_FILE=$work/no-such.json"
expect "an unreadable export cannot be judged a child, and errors" 2 "" "lkml-wake-gate: error: "
check "child: no gate error reads capacity" "" "$(promql)"

printf '\n== child: a malformed X-Lkml-Parent-Thread is still a child ==\n'
gen childbad <<'PY'
r = sub_root()
r["headers"] = [h for h in r["headers"] if h[0] != "X-Lkml-Parent-Thread"] \
    + [["X-Lkml-Parent-Thread", "not a thread id"]]
write(D, export([r, sub_seat(2, "@core", "Changes-requested"),
                 sub_seat(3, "@tests", "Reviewed-by: T"), sub_seat(4, "@docs", "NAK")]),
      status())
PY
prom '{"waiting": "0", "preempt": "0"}'
run childbad FS_HOOK_AGENT=core FS_HOOK_MESSAGE=m004
expect "malformed child: idle, a reviewer seat wakes" 0 "b"
check "malformed child: the capacity read ran" 2 "$(promql | wc -l)"
prom '{"waiting": "3", "preempt": "0"}'
run childbad FS_HOOK_AGENT=core FS_HOOK_MESSAGE=m004
expect "malformed child: busy, a reviewer seat defers" 1 "b" "capacity: defer: 3 requests waiting"
run childbad FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "malformed child: busy, the secretary defers" 1 "o" "capacity: defer: "

printf '\n== capacity: child seats wake only when the model server has room ==\n'
# childall's secretary wakes by rule o; a reviewer seat there by rule b.
prom '{"waiting": "0", "preempt": "0"}'
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "capacity: idle, the secretary wakes" 0 "o"
check "capacity: the PromQL received, selector and window included" \
    '/api/v1/query sum(vllm:num_requests_waiting{instance=~"gpu-a:.*"})
/api/v1/query sum(increase(vllm:num_preemptions_total{instance=~"gpu-a:.*"}[5m]))' \
    "$(promql)"
prom '{"waiting": "2", "preempt": "1"}'
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004 \
    LKML_CAPACITY_MAX_WAITING=2 LKML_CAPACITY_MAX_PREEMPTIONS=1 \
    LKML_CAPACITY_WINDOW=90s LKML_CAPACITY_SELECTOR=
expect "capacity: at both thresholds, the secretary wakes" 0 "o"
check "capacity: no selector, window as set" \
    '/api/v1/query sum(vllm:num_requests_waiting)
/api/v1/query sum(increase(vllm:num_preemptions_total[90s]))' "$(promql)"
prom '{"waiting": "0", "preempt": "0"}'
run childall FS_HOOK_AGENT=core FS_HOOK_MESSAGE=m004
expect "capacity: idle, a reviewer seat wakes" 0 "b"

prom '{"waiting": "3", "preempt": "0"}'
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "capacity: requests waiting defer the secretary" 1 "o" \
    "capacity: defer: 3 requests waiting (max 0)"
check "capacity: a waiting defer skips the preemption query" 1 "$(promql | wc -l)"
run childall FS_HOOK_AGENT=core FS_HOOK_MESSAGE=m004
expect "capacity: requests waiting defer a reviewer seat" 1 "b" \
    "capacity: defer: 3 requests waiting (max 0)"
prom '{"waiting": "3", "preempt": "0"}'
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004 LKML_CAPACITY_MAX_WAITING=2
expect "capacity: over a raised waiting threshold defers" 1 "o" \
    "3 requests waiting (max 2)"
prom '{"waiting": "0", "preempt": "1.5"}'
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
expect "capacity: preemptions defer" 1 "o" "capacity: defer: 1.5 preemptions in 5m (max 0)"
prom '{"waiting": "0", "preempt": "2"}'
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004 LKML_CAPACITY_MAX_PREEMPTIONS=1
expect "capacity: over a raised preemption threshold defers" 1 "o" "(max 1)"

printf '\n== capacity: every failure to read defers ==\n'
cap_fail() { # cap_fail <label> <reason substring> [VAR=value ...]
    local label="$1" want="$2"; shift 2
    run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004 "$@"
    expect "capacity: $label defers" 1 "o" "capacity: defer: " "$want"
}
prom '{"waiting": "0", "preempt": "0"}'
cap_fail "unset URL" "LKML_CAPACITY_PROMETHEUS is unset" LKML_CAPACITY_PROMETHEUS=
check "capacity: unset URL, no request" "" "$(promql)"
cap_fail "a non-http URL" "not an http(s) URL" LKML_CAPACITY_PROMETHEUS=file:///etc/hosts
cap_fail "an unparsable URL" "is not a URL" "LKML_CAPACITY_PROMETHEUS=http://[::1"
dead_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
cap_fail "connection refused" "prometheus unreachable: " \
    "LKML_CAPACITY_PROMETHEUS=http://127.0.0.1:$dead_port"
for f in '500|prometheus HTTP 500' 'error|prometheus HTTP 400' \
         "error200|prometheus status 'error'" 'nonjson|non-JSON' \
         'empty|no series for sum(vllm:num_requests_waiting' \
         'nonnum:abc|non-numeric value' 'nonnum:NaN|non-finite value' \
         'nonnum:+Inf|non-finite value'; do
    mode="${f%%|*}"; want="${f#*|}"
    prom "{\"waiting\": \"0\", \"preempt\": \"0\", \"fail\": \"$mode\", \"on\": \"waiting\"}"
    cap_fail "the waiting query answering $mode" "$want"
done
prom '{"waiting": "0", "preempt": "0", "fail": "empty", "on": "preempt"}'
cap_fail "an empty preemption vector" "no series for sum(increase(vllm:num_preemptions_total"
prom '{"waiting": "0", "preempt": "0", "fail": "hang", "on": "waiting"}'
t0=$SECONDS
cap_fail "a hung waiting query" "prometheus timed out after 4.0 s"
check "capacity: a hung query is cut off within the gate's budget" yes \
    "$( (( SECONDS - t0 <= 7 )) && echo yes || echo "no, $(( SECONDS - t0 )) s")"
prom '{"waiting": "0", "preempt": "0", "fail": "hang", "on": "preempt"}'
t0=$SECONDS
cap_fail "a hung preemption query" "prometheus timed out after"
check "capacity: a hung second query is cut off within the gate's budget" yes \
    "$( (( SECONDS - t0 <= 11 )) && echo yes || echo "no, $(( SECONDS - t0 )) s")"
prom '{"waiting": "0", "preempt": "0"}'
cap_fail "a non-integer waiting threshold" "LKML_CAPACITY_MAX_WAITING '1.5' is not" \
    LKML_CAPACITY_MAX_WAITING=1.5
cap_fail "a negative preemption threshold" "LKML_CAPACITY_MAX_PREEMPTIONS '-1' is not" \
    LKML_CAPACITY_MAX_PREEMPTIONS=-1
cap_fail "a selector without braces" "LKML_CAPACITY_SELECTOR 'instance=\"x\"' is not" \
    'LKML_CAPACITY_SELECTOR=instance="x"'
cap_fail "a malformed window" "LKML_CAPACITY_WINDOW '5 minutes' is not" \
    "LKML_CAPACITY_WINDOW=5 minutes"
check "capacity: malformed configuration, no request" "" "$(promql)"

printf '\n== capacity: no proxy ==\n'
prom '{"waiting": "0", "preempt": "0"}'
run childall FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004 \
    "http_proxy=http://127.0.0.1:$dead_port" "HTTP_PROXY=http://127.0.0.1:$dead_port"
expect "capacity: a refusing http_proxy is not used" 0 "o"
check "capacity: the read reached the server past http_proxy" 2 "$(promql | wc -l)"

printf '\n== capacity: settings from lkml-capacity.env ==\n'
# The file is read from $FORK_SANDBOX_HOOKS_DIR, else beside the gate;
# the run above defaults the former to a directory holding none.
hooks="$work/hooks"; mkdir -p -- "$hooks"
cap_file() { printf '%s\n' "$@" > "$hooks/lkml-capacity.env"; chmod 0755 "$hooks/lkml-capacity.env"; }
cap_run() { # cap_run [VAR=value ...]: childall's secretary, settings unset in env
    local d="$work/case-childall" v
    local -a args=(FS_HOOK_EVENT=wake-when FS_HOOK_THREAD=t-example
                   FS_HOOK_AGENT=secretary FS_HOOK_MESSAGE=m004
                   "FS_HOOK_EXPORT_FILE=$d/export.json" "FS_HOOK_STATUS_FILE=$d/status.json"
                   "FORK_SANDBOX_HOOKS_DIR=$hooks")
    for v in "$@"; do args+=("$v"); done
    ERR="$(env -i PATH="$PATH" "${args[@]}" "${CAP_GATE:-$GATE}" 2>&1 >/dev/null)"; RC=$?
}
prom '{"waiting": "2", "preempt": "0"}'
cap_file "LKML_CAPACITY_PROMETHEUS=$prom_url" 'LKML_CAPACITY_SELECTOR={job="f"}' \
         LKML_CAPACITY_MAX_WAITING=2 LKML_CAPACITY_WINDOW=7m
cap_run
expect "file: settings from the file alone wake the secretary" 0 "o"
check "file: the PromQL built from the file's settings" \
    '/api/v1/query sum(vllm:num_requests_waiting{job="f"})
/api/v1/query sum(increase(vllm:num_preemptions_total{job="f"}[7m]))' "$(promql)"
cap_run LKML_CAPACITY_MAX_WAITING=1
expect "file: the environment overrides a file value" 1 "o" "2 requests waiting (max 1)"
cap_run LKML_CAPACITY_PROMETHEUS=
expect "file: a variable set empty in the environment still wins" 1 "o" \
    "LKML_CAPACITY_PROMETHEUS is unset"
rm -f -- "$hooks/lkml-capacity.env"
prom '{"waiting": "0", "preempt": "0"}'
cap_run
expect "file: missing, and nothing in the environment, defers a child" 1 "o" \
    "LKML_CAPACITY_PROMETHEUS is unset, in the environment and in $hooks/lkml-capacity.env"
check "file: missing, no request" "" "$(promql)"
prom '{"waiting": "1", "preempt": "0"}'
cap_file '' '  # LKML_CAPACITY_MAX_WAITING=9' "LKML_CAPACITY_PROMETHEUS = '$prom_url' " \
         'LKML_CAPACITY_SELECTOR="{job="q"}"' 'lkml_capacity_max_waiting=9' \
         'MAX_WAITING=9' 'LKML_CAPACITY_MAX_WAITING'
cap_run
expect "file: a comment, a stray key and a line without '=' set nothing" 1 "o" \
    "1 requests waiting (max 0)"
check "file: quotes stripped from a value" \
    '/api/v1/query sum(vllm:num_requests_waiting{job="q"})' "$(promql)"
cap_file "LKML_CAPACITY_PROMETHEUS=$prom_url" "LKML_CAPACITY_WINDOW=\$(touch $work/marker)" \
         "LKML_CAPACITY_X=\$(touch $work/marker)" "touch $work/marker"
cap_run
expect "file: a command substitution is a literal value" 1 "o" \
    "LKML_CAPACITY_WINDOW '\$(touch $work/marker)' is not a PromQL duration"
check "file: never executed" no "$([[ -e "$work/marker" ]] && echo yes || echo no)"
# Beside the gate, when FORK_SANDBOX_HOOKS_DIR is empty: through a
# symlink, the file sits beside the script it resolves to.
beside="$work/beside"; mkdir -p -- "$beside" "$work/linkdir"
cp -- "$gate_src" "$beside/lkml-wake-gate.py"
cp -- "$(dirname -- "$gate_src")/lkml-panel-state.py" "$beside/"
ln -sf -- "$beside/lkml-wake-gate.py" "$work/linkdir/lkml-wake-gate.py"
ln -sf -- "$beside/lkml-panel-state.py" "$work/linkdir/lkml-panel-state.py"
printf '%s\n' "LKML_CAPACITY_PROMETHEUS=$prom_url" > "$beside/lkml-capacity.env"
prom '{"waiting": "0", "preempt": "0"}'
CAP_GATE="$work/linkdir/lkml-wake-gate.py" cap_run FORK_SANDBOX_HOOKS_DIR=
expect "file: beside the gate, symlink followed, with no hooks dir" 0 "o"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
