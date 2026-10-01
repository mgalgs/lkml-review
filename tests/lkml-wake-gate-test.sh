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
        subject="Re: [PATCH v1] Fix the thing", extra=()):
    h = [["From", frm]]
    if sha:
        h.append(["X-Review-Target", "pr/example " + sha])
    if set_target:
        h.append(["X-Review-Target-Set", "pr/example " + set_target])
    if ver is not None:
        h.append(["X-Version", str(ver)])
    h.extend(list(x) for x in extra)
    return {"seq": seq, "id": "m%03d" % seq, "headers": h, "from": frm,
            "to": ["@panel"], "cc": [], "subject": subject,
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

def reviewed(seq, who, sha=A, ver=1):
    return msg(seq, who, "Reviewed-by: %s <%s@example.com>" % (who, who[1:]),
               sha=sha, ver=ver)

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
GATE="$gate_src"; UNSET=""
RC=0; ERR=""
run() {
    local d="$work/case-$1" v; shift
    local -A envs=([FS_HOOK_EVENT]=wake-when [FS_HOOK_THREAD]=t-example
                   [FS_HOOK_AGENT]=@pr-author [FS_HOOK_MESSAGE]=m002
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
run silent FS_HOOK_AGENT=@secretary
expect "agent is not the author" 0 "b"

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

printf '\n== rules f-g: the reviewers decide ==\n'
run silent
expect "one reviewer answered, two silent" 1 "g" \
    "defer @pr-author" "@tests (silent)" "@docs (silent)"
case "$ERR" in
    *@core*) no "the answered reviewer is not named as waited on" "$ERR" ;;
    *) ok "the answered reviewer is not named as waited on" ;;
esac

gen stale <<'PY'
write(D, export([root(), reviewed(2, "@core"), reviewed(3, "@tests"),
                 reviewed(4, "@docs", sha=B)]), status())
PY
run stale
expect "@docs only tagged an older target, @tests replied" 1 "g" \
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

printf '\n== --help ==\n'
HELP="$("$gate_src" --help 2>&1)"; HRC=$?
check "--help exits 0" "0" "$HRC"
contains "--help mentions wake-when" "$HELP" "wake-when"
check "-h prints the same text" "$HELP" "$("$gate_src" -h 2>&1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
