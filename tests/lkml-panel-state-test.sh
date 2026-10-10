#!/usr/bin/env bash
# lkml-panel-state-test.sh — Exercise lkml-panel-state.py.
#
# The script's inputs are two JSON documents (fork-sandbox's `mail export
# --json` and `postmaster status --json`), so nearly everything here
# drives the --export-file/--status-file form with fixtures built in this
# test: a small generated Python helper (fx.py) assembles messages with
# invented ids, @core-style names and 40-hex fake shas, and jq reads the
# answer back. The <thread-id> form is driven through a stub
# `fork-sandbox` on PATH that prints canned JSON and records its argv.
#
# One section feeds the same message bodies through
# lkml-fleet-status.sh (the tag rules' reference implementation) and
# through this script's parser and compares the resulting latest tag per
# sender, so the two cannot drift apart.
#
# Usage: tests/lkml-panel-state-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ps="${LKML_PANEL_STATE:-$repo_dir/scripts/lkml-panel-state.py}"
fleet_status="$repo_dir/scripts/lkml-fleet-status.sh"

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

# The fixture builder. One message is what the export documents:
# headers as [name, value] pairs, the store-stamped X-Review-Target on
# replies, X-Review-Target-Set only on a message that set the target.
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
        subject="Re: [PATCH v1] Fix the thing", extra=(), to=None):
    h = [["From", frm]]
    if sha:
        h.append(["X-Review-Target", "pr/example " + sha])
    if set_target:
        h.append(["X-Review-Target-Set", "pr/example " + set_target])
    if ver is not None:
        h.append(["X-Version", str(ver)])
    h.extend(list(x) for x in extra)
    return {"seq": seq, "id": "m%03d" % seq, "headers": h, "from": frm,
            "to": to if to is not None else ["@panel"], "cc": [], "subject": subject,
            "date": "Mon, 02 Mar 2026 10:%02d:00 +0000" % (seq % 60),
            "in_reply_to": None, "body": body, "attachments": []}

def root(sha=A, ver=1, body=ROOT_BODY, set_target=True, extra=()):
    return msg(1, "@pr-author", body, sha=sha, ver=ver,
               set_target=sha if set_target else None,
               subject="[PATCH v1] Fix the thing", extra=extra)

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

def panel_positive(sha=A, ver=1, start=2, who=("@core", "@tests", "@docs")):
    return [msg(start + i, w, "Reviewed-by: %s <%s@example.com>" % (w, w[1:]),
                sha=sha, ver=ver) for i, w in enumerate(who)]

def sec(seq=20, status="CONVERGED", pver=1, verdict="SIGNED-OFF", sha=A, ver=1,
        prose="All in.", body=None):
    if body is None:
        lines = [prose, "", "Panel-Version: %s" % pver, "Panel-Status: %s" % status]
        if verdict:
            lines.append("Panel-Verdict: %s" % verdict)
        body = "\n".join(lines)
    return msg(seq, "@secretary", body, sha=sha, ver=ver)

def green(sha=A, ver=1, verdict=None):
    # v1 is the human's own head, so the root's Frozen-Head is v1's sha;
    # a later version is a re-roll on top of the root's (fff...) head.
    if verdict is None:
        verdict = "SIGNED-OFF" if ver == 1 else "RESPIN"
    body = ROOT_BODY.replace("f" * 40, sha) if ver == 1 else ROOT_BODY
    return ([root(sha=sha, ver=ver, body=body)] + panel_positive(sha=sha, ver=ver)
            + [sec(20, "CONVERGED", ver, verdict, sha, ver)])

def suite_case(tests_body, suite_lines=("Suite: pytest -q", "Suite-Seats: @tests"),
               panel="@core, @tests, @docs", older=None):
    # A v1 panel that is otherwise converged; @tests' verdict message is
    # tests_body, @docs' and @core's are plain Reviewed-by.
    body = ROOT_BODY.replace("f" * 40, A).replace("@core, @tests, @docs", panel)
    body = "\n".join([body] + list(suite_lines))
    m = [root(body=body)]
    if older:
        m.append(msg(2, "@tests", older, sha=B, ver=1))
    m += [msg(3, "@core", "Reviewed-by: C", sha=A, ver=1),
          msg(4, "@tests", tests_body, sha=A, ver=1),
          msg(5, "@docs", "Reviewed-by: D", sha=A, ver=1),
          sec(20)]
    return m

def run(rid, state, agent="@core"):
    return {"run_id": rid, "agent": agent, "state": state,
            "run_dir": "/run/" + rid, "resumed": False}

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

OUT=""; RC=0; cases_run=()
run_case() {
    local d="$work/case-$1"
    cases_run+=("$1")
    OUT="$("$ps" --export-file "$d/export.json" --status-file "$d/status.json" "${@:2}" 2>"$work/err")"; RC=$?
}
j() { jq -c "$1" <<<"$OUT"; }
jr() { jq -r "$1" <<<"$OUT"; }
# reason_has <label> <substring>: some reason contains the substring.
reason_has() {
    if jq -e --arg s "$2" 'any(.reasons[]; contains($s))' <<<"$OUT" >/dev/null; then ok "$1"
    else no "$1" "no reason contains '$2'; reasons: $(j .reasons)"; fi
}
reason_lacks() {
    if jq -e --arg s "$2" 'any(.reasons[]; contains($s))' <<<"$OUT" >/dev/null; then
        no "$1" "a reason contains '$2'; reasons: $(j .reasons)"
    else ok "$1"; fi
}
seat() { jr ".seats[] | select(.seat == \"$1\") | .$2"; }

[[ -x "$ps" ]] || { echo "not executable: $ps" >&2; exit 1; }

printf '\n== all-positive baseline: shape and roster ==\n'
gen base <<'PY'
write(D, export([root()] + panel_positive()), status())
PY
run_case base
check "exits 0" "0" "$RC"
check "output is one line (compact JSON + newline)" "1" "$(wc -l <<<"$OUT" | tr -d ' ')"
check "schema" "lkml-panel-state/1" "$(jr .schema)"
check "thread" "t-example" "$(jr .thread)"
check "subject is the root's" "[PATCH v1] Fix the thing" "$(jr .subject)"
check "roster author" "@pr-author" "$(jr .roster.author)"
check "roster panel in order" '["@core","@tests","@docs"]' "$(j .roster.panel)"
check "roster secretary" "@secretary" "$(jr .roster.secretary)"
check "roster version_limit" "4" "$(jr .roster.version_limit)"
check "roster frozen_head" "$(printf 'f%.0s' $(seq 40))" "$(jr .roster.frozen_head)"
check "target sha" "$(printf 'a%.0s' $(seq 40))" "$(jr .target.sha)"
check "target source" "postmaster" "$(jr .target.source)"
check "target branch/version" '"pr/example" 1' "$(jr '"\"" + .target.branch + "\" " + (.target.version|tostring)')"
check "seats in roster order" '["@core","@tests","@docs"]' "$(j '[.seats[].seat]')"
for s in @core @tests @docs; do
    check "$s is positive" "positive" "$(seat $s state)"
done
check "positive seat carries its tag" "Reviewed-by" "$(seat @core verdict)"
check "positive seat carries message id, version, sha" \
    "m002 1 $(printf 'a%.0s' $(seq 40))" \
    "$(seat @core message_id) $(seat @core version) $(seat @core sha)"

printf '\n== roster parsing ==\n'
gen roster1 <<'PY'
body = "\n".join([
    "Some prose first.",
    "   Panel:   @core ,@tests,   @docs   ",
    "Panel: @ignored-second-one",
    "panel: @lowercase-key-ignored",
    "Author: @pr-author",
    "Author: @second-author-loses",
    "Secretary:@secretary",
    "Version-Limit: 3",
    "Frozen-Head: " + "AB" * 20,
])
write(D, export([root(body=body)]), status())
PY
run_case roster1
check "whitespace around lines and after commas is ignored" '["@core","@tests","@docs"]' "$(j .roster.panel)"
check "first occurrence of a key wins" "@pr-author" "$(jr .roster.author)"
check "no space after the colon is fine" "@secretary" "$(jr .roster.secretary)"
check "version limit" "3" "$(jr .roster.version_limit)"
check "frozen head is lowercased" "$(printf 'ab%.0s' $(seq 20))" "$(jr .roster.frozen_head)"

gen roster2 <<'PY'
body = "Panel: @core, core, @Bad, @tests extra, @-lead, @ok-1\nAuthor: pr-author\nFrozen-Head: 12345\nVersion-Limit: four\n"
write(D, export([root(body=body)]), status())
PY
run_case roster2
check "malformed panel addresses are dropped, valid ones kept" '["@core","@ok-1"]' "$(j .roster.panel)"
reason_has "dropped 'core' is named" "'core'"
reason_has "dropped '@Bad' is named" "'@Bad'"
reason_has "dropped '@tests extra' is named" "'@tests extra'"
reason_has "dropped '@-lead' is named" "'@-lead'"
check "malformed author is null" "null" "$(j .roster.author)"
reason_has "malformed author is a reason" "malformed Author"
check "malformed frozen head is null" "null" "$(j .roster.frozen_head)"
reason_has "malformed frozen head is a reason" "Frozen-Head"
check "malformed version limit is null" "null" "$(j .roster.version_limit)"
reason_has "malformed version limit is a reason" "Version-Limit"

gen roster3 <<'PY'
write(D, export([root(body="Just a cover letter, no roster lines.\n")]), status())
PY
run_case roster3
check "no Panel line: empty panel" "[]" "$(j .roster.panel)"
reason_has "no Panel line: the named reason" "no panel roster on the thread root"
check "no Panel line: every roster key is still present" "true" \
    "$(jq '.roster | has("author") and has("secretary") and has("version_limit") and has("frozen_head")' <<<"$OUT")"

gen roster4 <<'PY'
write(D, export([root(body="Panel:\nPanel: @core, @tests\n")]), status())
PY
run_case roster4
check "an empty first Panel line wins over a later one" "[]" "$(j .roster.panel)"
reason_has "empty Panel: the named reason" "no panel roster on the thread root"

gen roster5 <<'PY'
write(D, export([msg(3, "@core", "Panel: @impostor", sha=A, ver=1), msg(9, "@tests", "Reviewed-by: T", sha=A, ver=1), root()]), status())
PY
run_case roster5
check "the root is the LOWEST seq, not the first in the array" '["@core","@tests","@docs"]' "$(j .roster.panel)"

gen roster6 <<'PY'
write(D, export([{"seq": 1, "error": "cannot parse", "file": "001-x.msg"},
                 msg(2, "@core", "Reviewed-by: C", sha=A, ver=1)]), status())
PY
run_case roster6
check "an unreadable root: exit 0" "0" "$RC"
check "an unreadable root: no panel" "[]" "$(j .roster.panel)"
check "an unreadable root: subject null" "null" "$(j .subject)"
reason_has "an unreadable root is a named reason" "thread root is unreadable"

printf '\n== current target ==\n'
gen tgt1 <<'PY'
write(D, export([root()] + panel_positive()), status(target=None))
PY
run_case tgt1
check "no postmaster target: falls back to mail" "mail" "$(jr .target.source)"
check "fallback sha is the setter message's" "$(printf 'a%.0s' $(seq 40))" "$(jr .target.sha)"
check "fallback carries branch, version, set_by" '"pr/example" 1 "@pr-author"' \
    "$(jr '"\"" + .target.branch + "\" " + (.target.version|tostring) + " \"" + .target.set_by + "\""')"
reason_has "fallback is a reason" "postmaster has no review target"
check "seats still judged against the fallback" "positive" "$(seat @core state)"

gen tgt2 <<'PY'
d = root(); d["headers"] = [h for h in d["headers"] if h[0] != "X-Review-Target-Set"]
write(D, export([d]), status(target=None))
PY
run_case tgt2
check "no target anywhere: target null" "null" "$(j .target)"
reason_has "no target anywhere: named reason" "no review target"
check "no target anywhere: seats are silent, not positive" "silent" "$(seat @core state)"

gen tgt3 <<'PY'
rr = msg(6, "@pr-author", "v2 with changes", sha=B, ver=2, set_target=B, subject="[PATCH v2] Fix the thing")
write(D, export([root(), msg(2, "@core", "Reviewed-by: C", sha=A, ver=1), rr]), status(sha=A, ver=1))
PY
run_case tgt3
check "postmaster wins over the newer mail target" "$(printf 'a%.0s' $(seq 40))" "$(jr .target.sha)"
check "disagreement keeps source postmaster" "postmaster" "$(jr .target.source)"
reason_has "sha disagreement is a reason" "disagrees"

gen tgt4 <<'PY'
rr = msg(6, "@pr-author", "v2 with changes", sha=B, ver=2, set_target=B, subject="[PATCH v2] Fix the thing")
write(D, export([root(), rr]), status(sha=B, ver=2))
PY
run_case tgt4
check "the newest X-Review-Target-Set agreeing with the postmaster: no target reason" "0" \
    "$(jq '[.reasons[] | select(test("target|disagree"))] | length' <<<"$OUT")"

gen tgt5 <<'PY'
rr = msg(6, "@pr-author", "v2", sha=A, ver=2, set_target=A, subject="[PATCH v2] Fix the thing")
write(D, export([root(), rr]), status(sha=A, ver=3))
PY
run_case tgt5
reason_has "same sha, different version between the sources is a reason" "v3 but the newest"

gen tgt6 <<'PY'
bad = root(); bad["headers"] = [h if h[0] != "X-Review-Target-Set" else ["X-Review-Target-Set", "not-a-target"] for h in bad["headers"]]
write(D, export([bad]), status(target=None))
PY
run_case tgt6
reason_has "an unparseable X-Review-Target-Set is a reason" "unparseable X-Review-Target-Set"
check "and yields no target" "null" "$(j .target)"

gen tgt7 <<'PY'
write(D, export([root()]), status(target={"branch": "", "sha": "", "version": None, "set_by": "", "set_at": ""}))
PY
run_case tgt7
reason_has "a postmaster target with no sha is a reason" "no usable sha"
check "and falls back to the mail witness" "mail" "$(jr .target.source)"

printf '\n== per-seat verdicts ==\n'
gen seat1 <<'PY'
m = [root(),
     msg(2, "@core", "Reviewed-by: Core <c@example.com>", sha=A, ver=1),
     msg(3, "@tests", "Chatty reply with no tag at all.", sha=A, ver=1)]
write(D, export(m), status())
PY
run_case seat1
check "an untagged on-target message is silent" "silent" "$(seat @tests state)"
check "a seat that never wrote is silent" "silent" "$(seat @docs state)"
check "silent seat: verdict null" "null" "$(seat @docs verdict)"
check "silent seat: all detail fields null" '[null,null,null]' "$(j '.seats[2] | [.message_id, .version, .sha]')"
reason_has "silent seat reason names seat, version, sha8" "@docs: no verdict on v1 (aaaaaaaa)"
reason_has "untagged seat reason" "@tests: no verdict on v1"

gen seat2 <<'PY'
m = [root(sha=B, ver=2),
     msg(2, "@core", "Reviewed-by: Core", sha=A, ver=1),
     msg(3, "@tests", "Reviewed-by: Tests", sha=B, ver=2),
     msg(4, "@docs", "Reviewed-by: Docs", sha=B, ver=2)]
write(D, export(m), status(sha=B, ver=2))
PY
run_case seat2
check "positive only on an OLD target: stale" "stale" "$(seat @core state)"
check "stale seat reports the old message's tag" "Reviewed-by" "$(seat @core verdict)"
check "stale seat reports the old version and sha" \
    "1 $(printf 'a%.0s' $(seq 40))" "$(seat @core version) $(seat @core sha)"
check "stale seat reports the old message id" "m002" "$(seat @core message_id)"
reason_has "stale reason names both targets" "@core: verdict is on v1 (aaaaaaaa), none on v2 (bbbbbbbb)"
check "other seats on the new target are positive" "positive positive" "$(seat @tests state) $(seat @docs state)"

gen seat3 <<'PY'
m = [root(),
     msg(2, "@core", "NAK\nThis breaks the frobnicator.", sha=A, ver=1),
     msg(3, "@tests", "Changes-requested\nAdd a test.", sha=A, ver=1),
     msg(4, "@docs", "Is this documented?\nQuestion", sha=A, ver=1)]
write(D, export(m), status())
PY
run_case seat3
check "NAK is blocking" "blocking NAK" "$(seat @core state) $(seat @core verdict)"
check "Changes-requested is blocking" "blocking Changes-requested" "$(seat @tests state) $(seat @tests verdict)"
check "Question is question" "question Question" "$(seat @docs state) $(seat @docs verdict)"
reason_has "NAK reason" "@core: NAK on v1"
reason_has "Changes-requested reason" "@tests: Changes-requested on v1"
reason_has "Question reason" "@docs: unanswered Question on v1"

gen seat4 <<'PY'
m = [root(),
     msg(2, "@core", "Changes-requested\nfix X", sha=A, ver=1),
     msg(3, "@core", "Reviewed-by: Core", sha=A, ver=1),
     msg(4, "@tests", "Reviewed-by: Tests", sha=A, ver=1),
     msg(5, "@tests", "NAK\nnow I see a problem", sha=A, ver=1),
     msg(6, "@docs", "Acked-by: Docs", sha=A, ver=1),
     msg(7, "@docs", "Thanks, just chatting.", sha=A, ver=1),
     msg(8, "@docs", "Late NAK about the OLD target", sha=B, ver=0)]
m[-1]["body"] = "NAK"
write(D, export(m), status())
PY
run_case seat4
check "a later Reviewed-by supersedes an earlier Changes-requested" "positive" "$(seat @core state)"
check "a later NAK supersedes an earlier Reviewed-by" "blocking" "$(seat @tests state)"
check "a later untagged message does not erase a tag" "positive Acked-by" "$(seat @docs state) $(seat @docs verdict)"
check "a later NAK on another target does not overrule the on-target tag" "m006" "$(seat @docs message_id)"

gen seat5 <<'PY'
m = [root(),
     msg(2, "@stranger", "NAK", sha=A, ver=1),
     msg(3, "@pr-author", "NAK from the author is not a panel seat", sha=A, ver=1),
     msg(4, "@core", "Reviewed-by: Core", sha=A, ver=1)]
write(D, export(m), status())
PY
run_case seat5
check "messages from non-panel senders never enter the seats" '["@core","@tests","@docs"]' "$(j '[.seats[].seat]')"
check "and do not change a seat's state" "positive" "$(seat @core state)"

gen seat6 <<'PY'
both = msg(2, "@core", "Reviewed-by: Core\nOn reflection:\nNAK", sha=A, ver=1)
write(D, export([root(), both]), status())
PY
run_case seat6
check "one message with a trailer and a NAK: the most severe wins" "blocking NAK" "$(seat @core state) $(seat @core verdict)"

gen seat7 <<'PY'
noheader = msg(2, "@core", "Reviewed-by: Core", sha=None)
dupe = msg(3, "@tests", "Reviewed-by: Tests", sha=A, ver=1, extra=[["X-Review-Target", "pr/example " + B]])
junk = msg(4, "@docs", "Reviewed-by: Docs", sha=None, extra=[["X-Review-Target", "garbage"]])
write(D, export([root(), noheader, dupe, junk]), status())
PY
run_case seat7
check "a tagged message with no X-Review-Target is not on target" "stale" "$(seat @core state)"
check "a message stamping two different targets is not on target" "stale" "$(seat @tests state)"
check "an unparseable X-Review-Target is not on target" "stale" "$(seat @docs state)"
reason_has "stale-with-no-target reason says so" "@core: verdict is on a message with no usable X-Review-Target"

gen seat8 <<'PY'
hdr = msg(2, "@core", "Reviewed-by: Core", sha=A, ver=1)
hdr["headers"] = [["x-review-target", "pr/example " + A], ["X-VERSION", "1"]]
write(D, export([root(), hdr]), status())
PY
run_case seat8
check "header names compare case-insensitively" "positive" "$(seat @core state)"

printf '\n== tag rules ==\n'
gen tags1 <<'PY'
m = [root(),
     msg(2, "@core", "> Reviewed-by: Quoted Person\n> NAK", sha=A, ver=1),
     msg(3, "@tests", "Reviewed-by: Tests\n\nLooks good.\nNAK\nWait, no: the NAK above is a joke.\nThanks.", sha=A, ver=1),
     msg(4, "@docs", "Reviewed-by\nTested-by from ci, security and me, Acked-by from docs, Acked-by from", sha=A, ver=1)]
write(D, export(m), status())
PY
run_case tags1
check "a tag in a quoted line is ignored" "silent" "$(seat @core state)"
check "a bare NAK mid-body is ignored" "positive Reviewed-by" "$(seat @tests state) $(seat @tests verdict)"
check "a -by tag without its colon is prose, not a tag" "silent" "$(seat @docs state)"

gen tags2 <<'PY'
m = [root(),
     msg(2, "@core", "Reviewed-by: Core\n> NAK\n> quoted", sha=A, ver=1),
     msg(3, "@tests", "> NAK\n\nQuestion: is X ok?", sha=A, ver=1),
     msg(4, "@docs", "  NAK\n  Reviewed-by: Indented", sha=A, ver=1)]
write(D, export(m), status())
PY
run_case tags2
check "a quoted verdict at the end does not count against a real trailer" "positive" "$(seat @core state)"
check "a bare verdict after quoted lines is the first non-quoted line" "question" "$(seat @tests state)"
check "indented tags do not count (line start means line start)" "silent" "$(seat @docs state)"

printf '\n== a malformed export entry is tolerated ==\n'
gen bad1 <<'PY'
m = [root(),
     {"seq": 2, "error": "cannot parse message", "file": "002-x.msg"},
     msg(3, "@core", "Reviewed-by: Core", sha=A, ver=1)]
write(D, export(m), status())
PY
run_case bad1
check "an error entry: still exit 0 with an object" "0" "$RC"
check "the rest of the thread is still judged" "positive" "$(seat @core state)"
reason_has "the unreadable message is a named reason (with its seq)" "1 unreadable message(s) in the export (seq 2)"

gen bad2 <<'PY'
m = [root(), {"seq": 2, "id": "m002", "from": 12, "body": None, "headers": "nope"},
     msg(3, "@core", "Reviewed-by: Core", sha=A, ver=1)]
write(D, export(m), status())
PY
run_case bad2
check "an entry with unusable fields is treated as unreadable, not fatal" "0" "$RC"
reason_has "and is named" "unreadable message(s)"

printf '\n== exit codes ==\n'
gen ok <<'PY'
write(D, export([root()] + panel_positive()), status())
PY
d="$work/case-ok"
printf '{not json' > "$work/garbage.json"
OUT="$("$ps" --export-file "$work/garbage.json" --status-file "$d/status.json" 2>"$work/err")"; RC=$?
check "unparsable export: exit 1" "1" "$RC"
check "unparsable export: nothing on stdout" "" "$OUT"
contains "unparsable export: one-line Error on stderr" "$(cat "$work/err")" "Error: mail export is not valid JSON"
check "unparsable export: stderr is a single line" "1" "$(wc -l < "$work/err" | tr -d ' ')"
OUT="$("$ps" --export-file "$d/export.json" --status-file "$work/garbage.json" 2>"$work/err")"; RC=$?
check "unparsable status: exit 1" "1" "$RC"
contains "unparsable status: names it" "$(cat "$work/err")" "postmaster status is not valid JSON"
OUT="$("$ps" --export-file "$work/nonexistent.json" --status-file "$d/status.json" 2>"$work/err")"; RC=$?
check "missing file: exit 1" "1" "$RC"
contains "missing file: names the path" "$(cat "$work/err")" "nonexistent.json"

gen mismatch <<'PY'
write(D, export([root()], thread="t-example"), status(thread="t-other"))
PY
d="$work/case-mismatch"
OUT="$("$ps" --export-file "$d/export.json" --status-file "$d/status.json" 2>"$work/err")"; RC=$?
check "thread ids disagree: exit 1" "1" "$RC"
check "thread ids disagree: nothing on stdout" "" "$OUT"
contains "thread ids disagree: names both" "$(cat "$work/err")" "t-example"
contains "thread ids disagree: names both (2)" "$(cat "$work/err")" "t-other"

printf '[1,2]' > "$work/array.json"
OUT="$("$ps" --export-file "$work/array.json" --status-file "$d/status.json" 2>"$work/err")"; RC=$?
check "export of the wrong shape: exit 1" "1" "$RC"
gen nokey <<'PY'
st = status()
del st["flag"]
write(D, export([root()]), st)
PY
d="$work/case-nokey"
OUT="$("$ps" --export-file "$d/export.json" --status-file "$d/status.json" 2>"$work/err")"; RC=$?
check "status missing a required key: exit 1" "1" "$RC"
contains "status missing a required key: names it" "$(cat "$work/err")" "'flag'"

d="$work/case-ok"
OUT="$("$ps" --export-file - --status-file "$d/status.json" < "$d/export.json" 2>"$work/err")"; RC=$?
check "export on stdin: exit 0" "0" "$RC"
check "export on stdin: judged" "positive" "$(seat @core state)"
OUT="$("$ps" --export-file "$d/export.json" --status-file - < "$d/status.json" 2>"$work/err")"; RC=$?
check "status on stdin: exit 0" "0" "$RC"

usage_case() {
    local label="$1"; shift
    OUT="$("$ps" "$@" 2>"$work/err" </dev/null)"; RC=$?
    check "usage: $label: exit 2" "2" "$RC"
    check "usage: $label: nothing on stdout" "" "$OUT"
    contains "usage: $label: an Error line" "$(cat "$work/err")" "Error:"
}
usage_case "no arguments"
usage_case "export without status" --export-file "$d/export.json"
usage_case "status without export" --status-file "$d/status.json"
usage_case "thread id together with files" t-example --export-file "$d/export.json" --status-file "$d/status.json"
usage_case "unknown option" --frobnicate
usage_case "two thread ids" t-one t-two
usage_case "both inputs from stdin" --export-file - --status-file -
usage_case "--remote with the file form" --remote --export-file "$d/export.json" --status-file "$d/status.json"
usage_case "an option missing its value" --export-file
usage_case "--remote alone" --remote

OUT="$("$ps" --help 2>&1)"; RC=$?
check "--help exits 0" "0" "$RC"
contains "--help prints the usage" "$OUT" "Usage: lkml-panel-state.py <thread-id> [--remote]"
contains "--help prints the rationale" "$OUT" "FALSE GREEN"
contains "--help documents the tier header" "$OUT" "X-Lkml-Tier"
OUT="$("$ps" -h 2>&1)"; RC=$?
check "-h exits 0" "0" "$RC"

printf '\n== the <thread-id> form runs fork-sandbox with --remote in the right place ==\n'
stub_bin="$work/stub"; mkdir -p -- "$stub_bin"
cat > "$stub_bin/fork-sandbox" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
[[ -n "${STUB_FAIL:-}" ]] && { echo "boom: the store is unreachable" >&2; exit 3; }
case "${1-} ${2-} ${3-}" in
    "mail export "*|"mail --remote export") cat "$STUB_DIR/export.json" ;;
    "postmaster status "*|"postmaster --remote status") cat "$STUB_DIR/status.json" ;;
    *) echo "unexpected: $*" >&2; exit 9 ;;
esac
STUB
chmod +x -- "$stub_bin/fork-sandbox"
export STUB_LOG="$work/stub.log" STUB_DIR="$work/case-ok"

: > "$STUB_LOG"
OUT="$(PATH="$stub_bin:$PATH" "$ps" t-example 2>"$work/err")"; RC=$?
check "<tid> form: exit 0" "0" "$RC"
check "<tid> form: judged" "positive" "$(seat @core state)"
check "<tid> form: the two commands, in order, no --remote" \
    "mail export t-example --json|postmaster status --thread t-example --json" \
    "$(paste -sd'|' "$STUB_LOG")"

: > "$STUB_LOG"
OUT="$(PATH="$stub_bin:$PATH" "$ps" --remote t-example 2>"$work/err")"; RC=$?
check "--remote before the thread id: exit 0" "0" "$RC"
check "--remote goes right after mail / postmaster" \
    "mail --remote export t-example --json|postmaster --remote status --thread t-example --json" \
    "$(paste -sd'|' "$STUB_LOG")"
: > "$STUB_LOG"
OUT="$(PATH="$stub_bin:$PATH" "$ps" t-example --remote 2>"$work/err")"; RC=$?
check "--remote after the thread id: same argv" \
    "mail --remote export t-example --json|postmaster --remote status --thread t-example --json" \
    "$(paste -sd'|' "$STUB_LOG")"

# shellcheck disable=SC2016  # the literal $( ) is the point
odd='t-odd $(touch PWNED); x'
: > "$STUB_LOG"
( cd "$work" && PATH="$stub_bin:$PATH" "$ps" "$odd" >/dev/null 2>&1 )
check "a hostile thread id reaches fork-sandbox as one argv word (no shell)" \
    "mail export $odd --json" "$(head -n1 "$STUB_LOG")"
check "and no shell ran it" "no" "$([[ -e "$work/PWNED" ]] && echo yes || echo no)"

OUT="$(STUB_FAIL=1 PATH="$stub_bin:$PATH" "$ps" t-example 2>"$work/err")"; RC=$?
check "a failing fork-sandbox: exit 1" "1" "$RC"
check "a failing fork-sandbox: nothing on stdout" "" "$OUT"
contains "a failing fork-sandbox: the Error line carries its exit and message" \
    "$(cat "$work/err")" "failed (exit 3): boom: the store is unreachable"

bare_bin="$work/bare"; mkdir -p -- "$bare_bin"
ln -sf "$(command -v python3)" "$bare_bin/python3"
ln -sf "$(command -v env)" "$bare_bin/env"
OUT="$(PATH="$bare_bin" "$ps" t-example 2>"$work/err")"; RC=$?
check "fork-sandbox not on PATH: exit 1" "1" "$RC"
contains "fork-sandbox not on PATH: says so" "$(cat "$work/err")" "fork-sandbox"

printf '\n== cross-check: the tag rules match lkml-fleet-status.sh ==\n'
# The same bodies go through the reference implementation (as messages
# in a fleet store) and through this script's parser; the latest tag set
# per sender must be identical. A sender may write several messages: a
# later untagged one leaves the earlier tags standing, a later tagged
# one replaces them -- the screen's own rule.
xroot="$work/xstore"; xt="99999999-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
mkdir -p -- "$xroot/threads/$xt"
xstub="$work/xstub"; mkdir -p -- "$xstub"
cat > "$xstub/fork-sandbox" <<'STUB'
#!/usr/bin/env bash
[[ "${1-}" == fleet && "${2-}" == expand ]] && { printf '%s\n' "${3-}"; exit 0; }
exit 1
STUB
chmod +x -- "$xstub/fork-sandbox"

CORPUS="$work/corpus.json"
python3 - "$xroot/threads/$xt" "$CORPUS" <<'PY'
import json, sys
d, out = sys.argv[1], sys.argv[2]
corpus = [
    ("@x-plain",   ["Reviewed-by: A <a@example.com>"]),
    ("@x-prose",   ["Tested-by from ci, security and me, Acked-by from docs, Acked-by from"]),
    ("@x-bare",    ["Reviewed-by"]),
    ("@x-mixed",   ["Reviewed-by: Mixed Signal\nTested-by looks solid too"]),
    ("@x-quoted",  ["> Reviewed-by: Quoted Person"]),
    ("@x-nak",     ["NAK\nExplanation of the NAK follows."]),
    ("@x-middle",  ["Looks fine overall.\nNAK\nbut then again fine.\nThanks."]),
    ("@x-last",    ["Is the lock order documented?\nQuestion"]),
    ("@x-multi",   ["Reviewed-by: X\nAcked-by: Y\nTested-by: Z\nChanges-requested"]),
    ("@x-nakdot",  ["NAK."]),
    ("@x-nakcolon", ["NAK: no"]),
    ("@x-naked",   ["NAKed for now"]),
    ("@x-qmark",   ["Question?"]),
    ("@x-chreq",   ["Changes-requested, see below\nfoo"]),
    ("@x-indent",  ["  Reviewed-by: Indented\n  NAK"]),
    ("@x-qthen",   ["> quoted stuff\n\nNAK\n\n> more quoted"]),
    ("@x-blanks",  ["\n\n\nNAK\n\n\n"]),
    ("@x-wspace",  ["  \t \nQuestion\n \t "]),
    ("@x-cr",      ["Question\r"]),
    ("@x-empty",   ["Tested-by:"]),
    ("@x-single",  ["NAK"]),
    ("@x-lower",   ["reviewed-by: lower\nnak"]),
    ("@x-both",    ["Acked-by: A\nMiddle\nNAK\nEnd."]),
    ("@x-untagged", ["Nothing to see here."]),
    ("@x-keep",    ["Reviewed-by: First", "Just chatting."]),
    ("@x-replace", ["Changes-requested\nfix it", "Reviewed-by: Second"]),
    ("@x-flip",    ["Reviewed-by: First", "NAK"]),
    ("@x-uni",     ["NAK now"]),
]
n = 0
seq = []
for sender, bodies in corpus:
    for body in bodies:
        n += 1
        hdr = "Message-ID: x%04d\nThread-ID: %s\nDate: Mon, 02 Mar 2026 10:%02d:00 +0000\nFrom: %s\nTo: @x-root\nSubject: Re: xcheck\nX-Hops: 1\n" % (n, d.rsplit("/", 1)[1], n % 60, sender)
        with open("%s/%03d-x%04d.msg" % (d, n, n), "w", encoding="utf-8") as f:
            f.write(hdr + "\n" + body + "\n")
        seq.append([sender, body])
json.dump(seq, open(out, "w"))
PY
xout="$(PATH="$xstub:$PATH" "$fleet_status" "$xt" --mail-root "$xroot" 2>&1)"
check "fleet-status reads the corpus" "0" "$?"
while IFS=$'\t' read -r sender ours; do
    theirs="$(grep -F "$sender  sent" <<<"$xout" | sed -n 's/.*tags: //p')"
    [[ "$theirs" == "-" ]] && theirs=""
    if [[ "$theirs" == "$ours" ]]; then ok "cross-check $sender: '${ours:--}'"
    else no "cross-check $sender" "fleet-status says '$theirs', lkml-panel-state.py says '$ours'"; fi
done < <(python3 - "$ps" "$CORPUS" <<'PY'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("lkml_panel_state", sys.argv[1])
spec = importlib.util.spec_from_loader("lkml_panel_state", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
latest = {}
for sender, body in json.load(open(sys.argv[2])):
    tags = mod.body_tags(body)
    latest.setdefault(sender, "")
    if tags:
        latest[sender] = " ".join(tags)
for sender in sorted(latest):
    print("%s\t%s" % (sender, latest[sender]))
PY
)
check "cross-check: every sender in the corpus compared" "28" \
    "$(python3 -c 'import json,sys; print(len({s for s,_ in json.load(open(sys.argv[1]))}))' "$CORPUS")"

# And end to end: the CLI's verdict for a single-tag body is the tag the
# screen reports (the screen lists every tag, the CLI picks one; for one
# tag they are the same word).
gen xcli <<'PY'
m = [root(),
     msg(2, "@core", "> Reviewed-by: Quoted Person", sha=A, ver=1),
     msg(3, "@tests", "NAK\nExplanation follows.", sha=A, ver=1),
     msg(4, "@docs", "Is the lock order documented?\nQuestion", sha=A, ver=1)]
write(D, export(m), status())
PY
run_case xcli
check "end to end: quoted trailer -> silent" "silent" "$(seat @core state)"
check "end to end: NAK first line -> NAK" "NAK" "$(seat @tests verdict)"
check "end to end: Question last line -> Question" "Question" "$(seat @docs verdict)"

printf '\n== status: CONVERGED needs every fact ==\n'
gen g1 <<'PY'
write(D, export(green()), status())
PY
run_case g1
check "all-positive + secretary CONVERGED + quiescent: CONVERGED" "CONVERGED" "$(jr .status)"
check "v1: verdict SIGNED-OFF" "SIGNED-OFF" "$(jr .verdict)"
check "CONVERGED: no reasons" "[]" "$(j .reasons)"
check "v1 SIGNED-OFF: no bundle" "null" "$(j .bundle)"
check "secretary object on target, well-formed" \
    '{"message_id":"m020","version":1,"status":"CONVERGED","verdict":"SIGNED-OFF","on_target":true,"malformed":null,"carried":false}' \
    "$(j .secretary)"
check "postmaster facts of a quiet thread" \
    '{"quiescent":true,"flagged":false,"flag_reason":null,"live_runs":0,"pending_retries":0,"held":0,"unrouted":0}' \
    "$(j .postmaster)"

gen g3 <<'PY'
write(D, export(green(sha=B, ver=3)), status(sha=B, ver=3))
PY
run_case g3
check "v3 RESPIN: CONVERGED" "CONVERGED" "$(jr .status)"
check "v3: verdict RESPIN" "RESPIN" "$(jr .verdict)"
check "v3 RESPIN + Frozen-Head: bundle base/tip/branch" \
    "{\"base\":\"$(printf 'f%.0s' $(seq 40))\",\"tip\":\"$(printf 'b%.0s' $(seq 40))\",\"branch\":\"pr/example\"}" \
    "$(j .bundle)"
check "v3: no reasons" "[]" "$(j .reasons)"

gen g3nf <<'PY'
body = ROOT_BODY.replace("Frozen-Head: " + "f" * 40, "")
e = green(sha=B, ver=3)
e[0] = root(sha=B, ver=3, body=body)
write(D, export(e), status(sha=B, ver=3))
PY
run_case g3nf
check "RESPIN without a Frozen-Head: still CONVERGED" "CONVERGED" "$(jr .status)"
check "RESPIN without a Frozen-Head: bundle null" "null" "$(j .bundle)"

gen g2r <<'PY'
write(D, export(green(sha=B, ver=2)), status(sha=B, ver=2))
PY
run_case g2r
check "v2 RESPIN: CONVERGED" "CONVERGED" "$(jr .status)"
check "v2 RESPIN: the bundle is for the respin" "bbbbbbbb" "$(jr '.bundle.tip[:8]')"

gen g1nf <<'PY'
e = green()
e[0] = root(body=ROOT_BODY.replace("Frozen-Head: " + "f" * 40, ""))
write(D, export(e), status())
PY
run_case g1nf
check "a v1 sign-off never carries a bundle" "null" "$(j .bundle)"

gen gnewest <<'PY'
older = sec(20, "IN-PROGRESS", 1, None)
newer = sec(21, "CONVERGED", 1, "SIGNED-OFF")
write(D, export(green()[:-1] + [older, newer]), status())
PY
run_case gnewest
check "the newest secretary message counts (IN-PROGRESS then CONVERGED)" "CONVERGED" "$(jr .status)"
check "and it is the newest one" "m021" "$(jr .secretary.message_id)"

printf '\n== status: a quiet seat is not an agreeing seat ==\n'
gen q1 <<'PY'
e = green()
e = [m for m in e if m["from"] != "@docs"]
write(D, export(e), status())
PY
run_case q1
check "one seat silent + secretary CONVERGED + quiescent: not CONVERGED" "STALLED" "$(jr .status)"
check "verdict is null when not CONVERGED" "null" "$(j .verdict)"
check "the silent seat's state" "silent" "$(seat @docs state)"
reason_has "the silent seat's reason" "@docs: no verdict on v1 (aaaaaaaa)"
reason_has "the false green is named" "secretary says CONVERGED but @docs is silent"

gen q2 <<'PY'
e = green()
e = [m for m in e if m["from"] != "@docs"]
write(D, export(e), status(runs=[run("r1", "live", "@docs")]))
PY
run_case q2
check "one seat silent, a run still live: IN-PROGRESS" "IN-PROGRESS" "$(jr .status)"
reason_has "the silent seat is still named" "@docs: no verdict on v1"
reason_has "the live run is named" "1 live run"

gen q3 <<'PY'
e = [m for m in green() if m["from"] not in ("@core", "@tests", "@docs")]
write(D, export(e), status())
PY
run_case q3
check "ALL seats silent, secretary CONVERGED, quiescent: not CONVERGED" "STALLED" "$(jr .status)"
check "all three seats silent" "silent silent silent" "$(seat @core state) $(seat @tests state) $(seat @docs state)"
reason_has "the secretary's claim is contradicted by name" "secretary says CONVERGED but @core is silent"

gen q4 <<'PY'
e = [m for m in green() if m["from"] != "@secretary"]
write(D, export(e), status())
PY
run_case q4
check "every seat positive but no secretary message: not CONVERGED" "STALLED" "$(jr .status)"
check "secretary object null when it never reported" "null" "$(j .secretary)"
reason_has "the missing report is a reason" "@secretary has not reported"

gen q5 <<'PY'
body = "\n".join(l for l in ROOT_BODY.split("\n") if not l.startswith("Secretary:"))
e = green()
e[0] = root(body=body)
write(D, export(e), status())
PY
run_case q5
check "no Secretary on the roster: not CONVERGED" "STALLED" "$(jr .status)"
check "no Secretary on the roster: secretary null" "null" "$(j .secretary)"
reason_has "no Secretary on the roster: named" "roster has no usable Secretary"

printf '\n== status: stale, blocking, and the secretary contradicting the facts ==\n'
gen s1 <<'PY'
m = [root(sha=B, ver=2),
     msg(2, "@core", "Reviewed-by: Core", sha=A, ver=1),
     msg(3, "@tests", "Reviewed-by: Tests", sha=B, ver=2),
     msg(4, "@docs", "Reviewed-by: Docs", sha=B, ver=2),
     sec(20, "CONVERGED", 2, "RESPIN", B, 2)]
write(D, export(m), status(sha=B, ver=2))
PY
run_case s1
check "a seat positive only on an OLD target is stale" "stale" "$(seat @core state)"
check "so the panel is not CONVERGED" "STALLED" "$(jr .status)"
reason_has "the stale seat is named with both targets" "@core: verdict is on v1 (aaaaaaaa), none on v2 (bbbbbbbb)"
reason_has "the secretary is caught claiming CONVERGED over a stale seat" "secretary says CONVERGED but @core is stale"

gen s2 <<'PY'
e = green()
e[2] = msg(3, "@tests", "Changes-requested\nAdd a test for the error path.", sha=A, ver=1)
write(D, export(e), status(runs=[run("r7", "live", "@tests")]))
PY
run_case s2
check "secretary CONVERGED while a seat is blocking, work in flight: IN-PROGRESS" "IN-PROGRESS" "$(jr .status)"
reason_has "the contradiction is named" "secretary says CONVERGED but @tests is blocking"
reason_has "the blocking verdict is itself a reason" "@tests: Changes-requested on v1"
check "verdict null" "null" "$(j .verdict)"

gen s2q <<'PY'
e = green()
e[2] = msg(3, "@tests", "Changes-requested\nAdd a test for the error path.", sha=A, ver=1)
write(D, export(e), status())
PY
run_case s2q
check "the same, but nobody is going to wake: STALLED" "STALLED" "$(jr .status)"
reason_has "the contradiction is named (quiescent)" "secretary says CONVERGED but @tests is blocking"

gen s3 <<'PY'
e = green()
e[1] = msg(2, "@core", "NAK\nThis cannot work.", sha=A, ver=1)
e[3] = msg(4, "@docs", "Is this documented anywhere?\nQuestion", sha=A, ver=1)
write(D, export(e), status())
PY
run_case s3
reason_has "a NAK under a CONVERGED secretary" "secretary says CONVERGED but @core is blocking"
reason_has "an open Question under a CONVERGED secretary" "secretary says CONVERGED but @docs has an open Question"
check "a seat with a Question is not positive" "question" "$(seat @docs state)"

gen s4 <<'PY'
write(D, export(green()[:-1] + [sec(20, "IN-PROGRESS", 1, None)]), status())
PY
run_case s4
check "every seat positive but the secretary says IN-PROGRESS: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "the secretary's IN-PROGRESS is a reason" "secretary says IN-PROGRESS"
check "an IN-PROGRESS secretary is well-formed and on target" "true null" \
    "$(jr '[.secretary.on_target, .secretary.malformed] | map(tostring) | join(" ")')"
reason_lacks "no false-green contradiction against an honest secretary" "secretary says CONVERGED"

gen s5 <<'PY'
write(D, export(green()[:-1] + [sec(20, "IN-PROGRESS", 1, None)]), status(runs=[run("r1", "live")]))
PY
run_case s5
check "secretary IN-PROGRESS and a live run: IN-PROGRESS" "IN-PROGRESS" "$(jr .status)"

printf '\n== status: NEEDS-OPERATOR, STALLED and IN-PROGRESS precedence ==\n'
gen f1 <<'PY'
write(D, export(green()), status(flag={"reason": "spawn budget exhausted", "events": 2}))
PY
run_case f1
check "flagged wins even over an all-green thread" "NEEDS-OPERATOR" "$(jr .status)"
check "flagged: verdict null" "null" "$(j .verdict)"
check "flagged: postmaster.flagged" "true" "$(jr .postmaster.flagged)"
check "flagged: postmaster.flag_reason" "spawn budget exhausted" "$(jr .postmaster.flag_reason)"
reason_has "flagged: the reason carries the flag's own text" "flagged for the operator: spawn budget exhausted"
reason_has "flagged: the secretary is caught claiming CONVERGED" "secretary says CONVERGED but the thread is flagged"

gen f2 <<'PY'
e = [root()]
write(D, export(e), status(flag={"reason": "loop guard", "events": 1}, runs=[run("r1", "live")]))
PY
run_case f2
check "flagged wins over IN-PROGRESS" "NEEDS-OPERATOR" "$(jr .status)"

gen f3 <<'PY'
e = [root()]
write(D, export(e), status())
PY
run_case f3
check "quiescent + not converged: STALLED" "STALLED" "$(jr .status)"
check "STALLED: postmaster.quiescent true" "true" "$(jr .postmaster.quiescent)"

gen f4 <<'PY'
write(D, export([root()]), status(runs=[run("r1", "live")]))
PY
run_case f4
check "not quiescent + not converged: IN-PROGRESS" "IN-PROGRESS" "$(jr .status)"

gen f5 <<'PY'
write(D, export(green()), status(flag={"reason": None, "events": 0}))
PY
run_case f5
check "a flag with no reason text is still a flag" "NEEDS-OPERATOR" "$(jr .status)"
check "and its flag_reason is null" "null" "$(j .postmaster.flag_reason)"

printf '\n== status: roster and target damage never converges ==\n'
gen r1 <<'PY'
body = "\n".join(l for l in ROOT_BODY.split("\n") if not l.startswith("Panel:"))
e = green()
e[0] = root(body=body)
write(D, export(e), status())
PY
run_case r1
check "no Panel line: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "no Panel line: the named reason" "no panel roster on the thread root"
check "no Panel line: no seats" "[]" "$(j .seats)"

gen r2 <<'PY'
body = ROOT_BODY.replace("Panel: @core, @tests, @docs", "Panel: @core, @tests, @docs, docs-two")
write(D, export([root(body=body)] + green()[1:]), status())
PY
run_case r2
check "a dropped malformed seat keeps the panel from CONVERGED" "STALLED" "$(jr .status)"
reason_has "the dropped seat is named" "'docs-two'"

gen t1 <<'PY'
rr = msg(30, "@pr-author", "re-roll", sha=B, ver=2, set_target=B, subject="[PATCH v2] Fix the thing")
write(D, export(green() + [rr]), status())
PY
run_case t1
check "postmaster and mail targets disagree: not CONVERGED" "STALLED" "$(jr .status)"
check "the postmaster's target is kept" "postmaster $(printf 'a%.0s' $(seq 40))" "$(jr '.target.source + " " + .target.sha')"
reason_has "the disagreement is a reason" "disagrees with the newest X-Review-Target-Set in mail"

gen t2 <<'PY'
write(D, export(green()), status(target=None))
PY
run_case t2
check "mail-only target (postmaster has none): not CONVERGED" "STALLED" "$(jr .status)"
check "the fallback target is used for the seats" "positive" "$(seat @core state)"
reason_has "the fallback is a reason" "postmaster has no review target"

gen t3 <<'PY'
e = green()[:-1]
e[0] = root()
e[0]["headers"] = [h for h in e[0]["headers"] if h[0] != "X-Review-Target-Set"]
write(D, export(e), status(target=None))
PY
run_case t3
check "no target anywhere: not CONVERGED" "STALLED" "$(jr .status)"
check "no target anywhere: target null" "null" "$(j .target)"
check "no target anywhere: bundle null" "null" "$(j .bundle)"

gen t4 <<'PY'
write(D, export(green(sha=B, ver=2)), status(sha=B, ver=2, runs=[run("r1", "harvested")]))
PY
run_case t4
check "a harvested run alone does not block CONVERGED" "CONVERGED" "$(jr .status)"

printf '\n== the secretary: malformed trailers never converge ==\n'
mal_names=(order unknown-status unknown-verdict verdict-under-inprogress no-verdict
           bad-version prose-after quoted-after panel-line-midbody extra-key duplicate)
mal_bodies=(
    $'Panel-Status: CONVERGED\nPanel-Version: 1\nPanel-Verdict: SIGNED-OFF'
    $'Panel-Version: 1\nPanel-Status: DONE\nPanel-Verdict: SIGNED-OFF'
    $'Panel-Version: 1\nPanel-Status: CONVERGED\nPanel-Verdict: APPROVED'
    $'Panel-Version: 1\nPanel-Status: IN-PROGRESS\nPanel-Verdict: SIGNED-OFF'
    $'Panel-Version: 1\nPanel-Status: CONVERGED'
    $'Panel-Version: one\nPanel-Status: CONVERGED\nPanel-Verdict: SIGNED-OFF'
    $'Panel-Version: 1\nPanel-Status: CONVERGED\nPanel-Verdict: SIGNED-OFF\nThanks everyone.'
    $'Panel-Version: 1\nPanel-Status: CONVERGED\nPanel-Verdict: SIGNED-OFF\n> Panel-Status: IN-PROGRESS'
    $'Panel-Status: IN-PROGRESS\nsome discussion\nPanel-Version: 1\nPanel-Status: CONVERGED\nPanel-Verdict: SIGNED-OFF'
    $'Panel-Version: 1\nPanel-Status: CONVERGED\nPanel-Verdict: SIGNED-OFF\nPanel-Extra: x'
    $'Panel-Version: 1\nPanel-Version: 1\nPanel-Status: CONVERGED\nPanel-Verdict: SIGNED-OFF'
)
for i in "${!mal_names[@]}"; do
    n="${mal_names[$i]}"
    SECBODY="${mal_bodies[$i]}" gen "mal-$n" <<'PY'
write(D, export(green()[:-1] + [sec(body=os.environ["SECBODY"])]), status())
PY
    run_case "mal-$n"
    check "malformed ($n): not CONVERGED" "STALLED" "$(jr .status)"
    check "malformed ($n): secretary.malformed is set" "true" "$(jr '.secretary.malformed != null')"
    check "malformed ($n): never on target" "false" "$(jr .secretary.on_target)"
    check "malformed ($n): version/status/verdict are null" '[null,null,null]' "$(j '.secretary | [.version, .status, .verdict]')"
    reason_has "malformed ($n): a reason says so" "malformed trailer"
    check "malformed ($n): verdict null" "null" "$(j .verdict)"
done

gen mal-fallback <<'PY'
good = sec(20, "CONVERGED", 1, "SIGNED-OFF")
bad = sec(21, body="Panel-Version: 1\nPanel-Status: CONVERGED")
write(D, export(green()[:-1] + [good, bad]), status())
PY
run_case mal-fallback
check "a newer malformed trailer is not skipped for an older good one" "STALLED" "$(jr .status)"
check "the malformed one is the one reported" "m021" "$(jr .secretary.message_id)"

gen mal-prose <<'PY'
body = "I think we are done.\nPanel-Version: 1 is what I am reading from.\nThanks."
write(D, export(green()[:-1] + [sec(body=body)]), status())
PY
run_case mal-prose
check "prose that merely starts with 'Panel-Version:' but is not a trailer block: never CONVERGED" "STALLED" "$(jr .status)"

gen sec-nopanel <<'PY'
write(D, export(green()[:-1] + [sec(body="Looks good to me. CONVERGED, signed off.")]), status())
PY
run_case sec-nopanel
check "a secretary message with no Panel-* line is not a report" "null" "$(j .secretary)"
check "so the panel is not CONVERGED" "STALLED" "$(jr .status)"

printf '\n== the secretary: on target, and verdict vs version ==\n'
gen o1 <<'PY'
m = [root(sha=B, ver=2)] + panel_positive(sha=B, ver=2) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", A, 1)]
write(D, export(m), status(sha=B, ver=2))
PY
run_case o1
check "a secretary report about the OLD target: not on target" "false" "$(jr .secretary.on_target)"
check "and the panel is not CONVERGED" "STALLED" "$(jr .status)"
reason_has "the off-target report is a reason" "secretary's Panel-Status is for v1 (aaaaaaaa), not the current target v2 (bbbbbbbb)"

gen o2 <<'PY'
m = [root(sha=B, ver=2)] + panel_positive(sha=B, ver=2) + [sec(20, "CONVERGED", 1, "RESPIN", B, 2)]
write(D, export(m), status(sha=B, ver=2))
PY
run_case o2
check "right sha, wrong Panel-Version: not on target" "false" "$(jr .secretary.on_target)"
check "right sha, wrong Panel-Version: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "right sha, wrong Panel-Version: named" "secretary's Panel-Status is for v1 (bbbbbbbb)"

gen o3 <<'PY'
m = [root(sha=B, ver=2)] + panel_positive(sha=B, ver=2) + [sec(20, "CONVERGED", 2, "RESPIN", A, 1)]
write(D, export(m), status(sha=B, ver=2))
PY
run_case o3
check "right Panel-Version, wrong sha: not on target" "false" "$(jr .secretary.on_target)"
check "right Panel-Version, wrong sha: not CONVERGED" "STALLED" "$(jr .status)"

gen v1 <<'PY'
write(D, export(green(sha=B, ver=2, verdict="SIGNED-OFF")), status(sha=B, ver=2))
PY
run_case v1
check "SIGNED-OFF on a v2 target: not CONVERGED" "STALLED" "$(jr .status)"
check "SIGNED-OFF on v2: verdict null" "null" "$(j .verdict)"
check "SIGNED-OFF on v2: the secretary object still shows what it said" "SIGNED-OFF" "$(jr .secretary.verdict)"
reason_has "SIGNED-OFF on v2: the contradiction is named" "SIGNED-OFF contradicts target v2"

gen v2 <<'PY'
e = green(sha=A, ver=1, verdict="RESPIN")
e[0] = root(body=ROOT_BODY.replace("Frozen-Head: " + "f" * 40, ""))
write(D, export(e), status())
PY
run_case v2
check "RESPIN on a v1 target, no frozen head known: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "RESPIN on v1, no frozen head known: the contradiction is named" "RESPIN contradicts target v1"
check "RESPIN on v1: no bundle" "null" "$(j .bundle)"

gen v3 <<'PY'
write(D, export(green(sha=C, ver=4)), status(sha=C, ver=4))
PY
run_case v3
check "v4 RESPIN: CONVERGED" "CONVERGED" "$(jr .status)"

printf '\n== per-version frozen head ==\n'
# F is the root's Frozen-Head, H the human author's pushed head, T2/T4 the
# author persona's re-rolls. UP is the postmaster's upstream-moved mail.
cat >> "$work/fx.py" <<'FX2'
F = sha("f")
H, T2, T4 = sha("1"), sha("2"), sha("4")

def frozen_root(head=F):
    return root(sha=F, ver=1, body=ROOT_BODY.replace("f" * 40, head))

def upstream(seq, head=H, frm="@postmaster", mode=None, extra=(), to=None):
    # The postmaster's upstream-moved mail; mode and extra add the
    # X-Lkml-* push headers the CI side stamps on it.
    h = [["X-Upstream-Head", "pr/example " + head]]
    if mode:
        h.append(["X-Lkml-Push-Mode", mode])
    h.extend(list(x) for x in extra)
    return msg(seq, frm, "The human author pushed a new head.", extra=h, to=to)

def tier_root(tier="standard", head=A):
    return root(sha=head, body=ROOT_BODY.replace("f" * 40, head),
                extra=[["X-Lkml-Tier", tier],
                       ["X-Lkml-Tier-Reason", "two subsystems"]])

def cover(seq, target, ver, body, frm="@pr-author"):
    return msg(seq, frm, body, sha=target, ver=ver, set_target=target,
               subject="Re: [PATCH v%d 0/0] Fix the thing" % ver)

def human_thread(seq_up=2, seq_cover=3, cover_head=H, up_head=H, verdict="SIGNED-OFF",
                 pver=3, target=H, ver=3, with_up=True):
    m = [frozen_root()]
    if with_up:
        m.append(upstream(seq_up, up_head))
    m.append(cover(seq_cover, target, ver, "Human integration.\n\nFrozen-Head: " + cover_head))
    m += panel_positive(sha=target, ver=ver, start=10)
    m.append(sec(20, "CONVERGED", pver, verdict, target, ver))
    return m
FX2

# The CI gate's fixtures: a root that opts in (`X-Lkml-Suite-Source: ci`,
# still carrying its Suite lines, which the gate must not read), and the
# CI side's result mail.
cat >> "$work/fx.py" <<'FX3'
def ci_root(head=A, extra=(), body=None):
    if body is None:
        body = "\n".join([ROOT_BODY.replace("f" * 40, head),
                          "Suite: pytest -q", "Suite-Seats: @tests"])
    return root(sha=A, body=body,
                extra=[["X-Lkml-Suite-Source", "ci"]] + [list(x) for x in extra])

def ci_mail(seq, status, head=A, frm="@operator", url=None, extra=(),
            head_value=None):
    h = [["X-Lkml-CI-Status", status],
         ["X-Lkml-CI-Head", head_value or ("pr/example " + head)]]
    if url:
        h.append(["X-Lkml-CI-Url", url])
    h.extend(list(x) for x in extra)
    return msg(seq, frm, "CI result: %s." % status, extra=h, to=["@operator"])

# Operator-question fixtures. question() is a seat's message; qthread() is
# a v1 panel at head A (the root's Frozen-Head) in which @core's message is
# core_body at seq 2, @tests and @docs are positive on A, and the secretary
# says CONVERGED SIGNED-OFF v1 at seq 20. Message dates are 10:<seq> on
# 2026-03-02, so ages are exact arithmetic.
Q = "Question: which tests cover the retry path?"

def question(seq, frm, body, sha=A, ver=1, to=("@pr-author", "@operator")):
    return msg(seq, frm, body, sha=sha, ver=ver, to=list(to))

def timeout_root(hours="2h", head=A, extra=()):
    hs = [] if hours is None else ([hours] if isinstance(hours, str) else list(hours))
    return root(sha=head, body=ROOT_BODY.replace("f" * 40, head),
                extra=[["X-Lkml-Question-Timeout", h] for h in hs] + [list(x) for x in extra])

def qthread(core_body, hours="2h", to=("@pr-author", "@operator")):
    return [timeout_root(hours), question(2, "@core", core_body, to=to),
            msg(3, "@tests", "Reviewed-by: T", sha=A, ver=1),
            msg(4, "@docs", "Reviewed-by: D", sha=A, ver=1), sec(20)]
FX3

gen fh_a <<'PY'
e = [frozen_root()] + panel_positive(sha=F, ver=1) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
write(D, export(e), status(sha=F, ver=1))
PY
run_case fh_a
check "(a) root Frozen-Head == v1 target: CONVERGED" "CONVERGED" "$(jr .status)"
check "(a) SIGNED-OFF" "SIGNED-OFF" "$(jr .verdict)"
check "(a) frozen_head is the root's" "{\"sha\":\"$(printf "f%.0s" $(seq 40))\",\"source\":\"root\"}" "$(j .frozen_head)"

gen fh_b <<'PY'
e = [frozen_root(), cover(2, T2, 2, "Re-roll after review.")]
e += panel_positive(sha=T2, ver=2, start=10) + [sec(20, "CONVERGED", 2, "RESPIN", T2, 2)]
write(D, export(e), status(sha=T2, ver=2))
PY
run_case fh_b
check "(b) author re-roll, no Frozen-Head line: CONVERGED" "CONVERGED" "$(jr .status)"
check "(b) RESPIN" "RESPIN" "$(jr .verdict)"
check "(b) bundle base is the root's frozen head" "$(printf "f%.0s" $(seq 40))" "$(jr .bundle.base)"
check "(b) frozen_head falls back to the root" "{\"sha\":\"$(printf "f%.0s" $(seq 40))\",\"source\":\"root\"}" "$(j .frozen_head)"

gen fh_c <<'PY'
write(D, export(human_thread()), status(sha=H, ver=3))
PY
run_case fh_c
check "(c) human integration signed off: CONVERGED" "CONVERGED" "$(jr .status)"
check "(c) SIGNED-OFF at v3" "SIGNED-OFF" "$(jr .verdict)"
check "(c) frozen_head is the vouched upstream head" "{\"sha\":\"$(printf "1%.0s" $(seq 40))\",\"source\":\"upstream\"}" "$(j .frozen_head)"
check "(c) no bundle" "null" "$(j .bundle)"
check "(c) roster.frozen_head stays the root's" "$(printf "f%.0s" $(seq 40))" "$(jr .roster.frozen_head)"
check "(c) no reasons" "[]" "$(j .reasons)"

gen fh_d <<'PY'
write(D, export(human_thread(verdict="RESPIN")), status(sha=H, ver=3))
PY
run_case fh_d
check "(d) RESPIN on the frozen head: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "(d) the contradiction is named" "RESPIN contradicts target v3 (11111111)"
reason_has "(d) and names the frozen head" "frozen head (11111111)"

gen fh_e <<'PY'
write(D, export(human_thread(with_up=False)), status(sha=H, ver=3))
PY
run_case fh_e
check "(e) no X-Upstream-Head anywhere: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "(e) the unvouched Frozen-Head is a reason" "cover Frozen-Head 11111111 is not a stamped X-Upstream-Head on this thread"
check "(e) frozen_head falls back to the root" "{\"sha\":\"$(printf "f%.0s" $(seq 40))\",\"source\":\"root\"}" "$(j .frozen_head)"
reason_has "(e) SIGNED-OFF contradicts (H != F)" "SIGNED-OFF contradicts target v3 (11111111)"
reason_has "(e) and names the root's frozen head" "frozen head (ffffffff)"

gen fh_f <<'PY'
write(D, export(human_thread(seq_up=5, seq_cover=3)), status(sha=H, ver=3))
PY
run_case fh_f
check "(f) X-Upstream-Head AFTER the cover: not CONVERGED" "STALLED" "$(jr .status)"
check "(f) frozen_head falls back to the root" "{\"sha\":\"$(printf "f%.0s" $(seq 40))\",\"source\":\"root\"}" "$(j .frozen_head)"
reason_has "(f) the unvouched Frozen-Head is a reason" "is not a stamped X-Upstream-Head"

gen fh_g <<'PY'
write(D, export(human_thread(up_head=T2)), status(sha=H, ver=3))
PY
run_case fh_g
check "(g) X-Upstream-Head names another sha: not CONVERGED" "STALLED" "$(jr .status)"
check "(g) frozen_head falls back to the root" "{\"sha\":\"$(printf "f%.0s" $(seq 40))\",\"source\":\"root\"}" "$(j .frozen_head)"
reason_has "(g) the unvouched Frozen-Head is a reason" "is not a stamped X-Upstream-Head"

gen fh_h <<'PY'
e = [frozen_root(), upstream(2), cover(3, H, 3, "Human integration.\n\nFrozen-Head: " + H),
     cover(4, T4, 4, "Re-roll.\n\nFrozen-Head: " + H)]
e += panel_positive(sha=T4, ver=4, start=10) + [sec(20, "CONVERGED", 4, "RESPIN", T4, 4)]
write(D, export(e), status(sha=T4, ver=4))
PY
run_case fh_h
check "(h) re-roll on the human's head: CONVERGED" "CONVERGED" "$(jr .status)"
check "(h) RESPIN" "RESPIN" "$(jr .verdict)"
check "(h) bundle base is the human's head" "$(printf "1%.0s" $(seq 40))" "$(jr .bundle.base)"
check "(h) frozen_head is upstream" "{\"sha\":\"$(printf "1%.0s" $(seq 40))\",\"source\":\"upstream\"}" "$(j .frozen_head)"

gen fh_h2 <<'PY'
e = [frozen_root(), upstream(2), cover(3, H, 3, "Human integration.\n\nFrozen-Head: " + H),
     cover(4, T4, 4, "Re-roll.\n\nFrozen-Head: " + H)]
e += panel_positive(sha=T4, ver=4, start=10) + [sec(20, "CONVERGED", 4, "SIGNED-OFF", T4, 4)]
write(D, export(e), status(sha=T4, ver=4))
PY
run_case fh_h2
check "(h) SIGNED-OFF on the author's re-roll: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "(h) the contradiction names both shas" "SIGNED-OFF contradicts target v4 (44444444)"

gen fh_i <<'PY'
e = [frozen_root(), cover(2, T2, 2, "Re-roll.\n\nFrozen-Head: 1234")]
e += panel_positive(sha=T2, ver=2, start=10) + [sec(20, "CONVERGED", 2, "RESPIN", T2, 2)]
write(D, export(e), status(sha=T2, ver=2))
PY
run_case fh_i
check "(i) malformed cover Frozen-Head: root fallback" "{\"sha\":\"$(printf "f%.0s" $(seq 40))\",\"source\":\"root\"}" "$(j .frozen_head)"
reason_has "(i) and it is a reason" "cover seq 2: malformed Frozen-Head"
check "(i) so the panel is not CONVERGED" "STALLED" "$(jr .status)"

gen fh_j <<'PY'
e = human_thread()
e.insert(3, msg(6, "@core", "Frozen-Head: " + T2 + "\nReviewed-by: C", sha=H, ver=3))
e.insert(3, msg(7, "@secretary", "Frozen-Head: " + T2, sha=H, ver=3))
q = [msg(8, "@docs", "Frozen-Head: " + T2, sha=H, ver=3, set_target=H)]
write(D, export(e + q), status(sha=H, ver=3))
PY
run_case fh_j
check "(j) Frozen-Head lines from non-Author messages change nothing" "{\"sha\":\"$(printf "1%.0s" $(seq 40))\",\"source\":\"upstream\"}" "$(j .frozen_head)"
check "(j) still CONVERGED" "CONVERGED" "$(jr .status)"

gen fh_k <<'PY'
e = human_thread()
e[2] = cover(3, H, 3, "Human integration.\n\n   Frozen-Head: " + H + "  \nFrozen-Head: " + T2)
write(D, export(e), status(sha=H, ver=3))
PY
run_case fh_k
check "the first Frozen-Head line wins, whitespace trimmed" "{\"sha\":\"$(printf "1%.0s" $(seq 40))\",\"source\":\"upstream\"}" "$(j .frozen_head)"

gen fh_n <<'PY'
# A second push lands after the panel signed off on the first; the author's
# only reply is a mismatch report to the operator.
H2 = sha("5")
e = human_thread()
e.append(upstream(30, H2))
e.append(msg(31, "@pr-author", "Expected upstream 55555555, found none.", sha=H, ver=3))
write(D, export(e), status(sha=H, ver=3))
PY
run_case fh_n
check "(n) an unanswered second push: not CONVERGED" "STALLED" "$(jr .status)"
check "(n) no verdict is reported" "null" "$(j .verdict)"
reason_has "(n) the unanswered push is named" "the human author's newest push 55555555 (seq 30) is not the frozen head of the current target (11111111)"

gen fh_o <<'PY'
# The push after the sign-off was answered: a later version whose cover
# carries it as Frozen-Head, so the newest push IS the frozen head.
H2 = sha("5")
e = human_thread()
e.append(upstream(30, H2))
e.append(cover(31, H2, 4, "Human integration.\n\nFrozen-Head: " + H2))
e += panel_positive(sha=H2, ver=4, start=40) + [sec(50, "CONVERGED", 4, "SIGNED-OFF", H2, 4)]
write(D, export(e), status(sha=H2, ver=4))
PY
run_case fh_o
check "(o) the newest push answered by a version: CONVERGED" "CONVERGED" "$(jr .status)"
check "(o) SIGNED-OFF" "SIGNED-OFF" "$(jr .verdict)"

gen fh_q <<'PY'
# A push on a v1 thread whose panel already signed off, with no cover yet.
e = [frozen_root()] + panel_positive(sha=F, ver=1) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H))
write(D, export(e), status(sha=F, ver=1))
PY
run_case fh_q
check "(q) a push after a v1 sign-off, unanswered: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "(q) the unanswered push is named" "the human author's newest push 11111111 (seq 30)"

gen fh_m <<'PY'
e = [root(body=ROOT_BODY.replace("Frozen-Head: " + "f" * 40, ""))] + panel_positive()
write(D, export(e), status())
PY
run_case fh_m
check "no frozen head anywhere (no root value, no cover line): null" "null" "$(j .frozen_head)"

printf '\n== postmaster facts: what counts as live and pending ==\n'
gen p1 <<'PY'
write(D, export(green()), status(runs=[run("r1", "live"), run("r2", "harvested"), run("r3", "live", "@docs")]))
PY
run_case p1
check "two live runs, one harvested: IN-PROGRESS" "IN-PROGRESS" "$(jr .status)"
check "live_runs counts only live" "2" "$(jr .postmaster.live_runs)"
check "not quiescent" "false" "$(jr .postmaster.quiescent)"
reason_has "'2 live runs' is a reason" "2 live runs"
reason_has "the secretary is caught claiming CONVERGED on a busy thread" "secretary says CONVERGED but the thread is not quiescent"

gen p2 <<'PY'
write(D, export(green()), status(runs=[run("r1", "weird")]))
PY
run_case p2
check "an unrecognized run state is treated as live" "1" "$(jr .postmaster.live_runs)"
reason_has "and says so" "run r1: unrecognized state 'weird', treated as live"
check "so the thread is not converged" "IN-PROGRESS" "$(jr .status)"

gen p2n <<'PY'
write(D, export(green()), status(runs=[run("r1", None)]))
PY
run_case p2n
check "a run with no state is treated as live" "1" "$(jr .postmaster.live_runs)"

gen p3 <<'PY'
retries = [{"agent": "@core", "state": "pending", "attempt": 1, "due_s": 30},
           {"agent": "@tests", "state": "exhausted", "attempt": 3, "due_s": 0},
           {"agent": "@docs", "state": "recovered", "attempt": 2, "due_s": 0},
           {"agent": "@docs", "state": None, "attempt": 1, "due_s": 0}]
write(D, export(green()), status(retries=retries))
PY
run_case p3
check "only a pending retry is pending" "1" "$(jr .postmaster.pending_retries)"
reason_has "'1 pending retry' is a reason" "1 pending retry"
reason_lacks "a known state raises no 'unrecognized' reason" "unrecognized"
check "a pending retry: IN-PROGRESS" "IN-PROGRESS" "$(jr .status)"

gen p3h <<'PY'
retries = [{"agent": "@tests", "state": "exhausted", "attempt": 3, "due_s": 0},
           {"agent": "@docs", "state": "recovered", "attempt": 2, "due_s": 0},
           {"agent": "@docs", "state": None, "attempt": 1, "due_s": 0}]
write(D, export(green()), status(retries=retries))
PY
run_case p3h
check "exhausted / recovered / stateless retries are history: CONVERGED" "CONVERGED" "$(jr .status)"
check "history retries: pending_retries 0" "0" "$(jr .postmaster.pending_retries)"

gen p4 <<'PY'
write(D, export(green()), status(retries=[{"agent": "@core", "state": "backoff", "attempt": 1, "due_s": 5}]))
PY
run_case p4
check "an unrecognized retry state is treated as pending" "1" "$(jr .postmaster.pending_retries)"
reason_has "and says so" "retry for @core: unrecognized state 'backoff', treated as pending"

gen p5 <<'PY'
held = [{"agent": "@core", "trigger": "reply", "age_s": 40}, {"agent": "@docs", "trigger": "reply", "age_s": 9}]
write(D, export(green()), status(held=held, unrouted=3))
PY
run_case p5
check "held seats and unrouted mail: not quiescent" "false" "$(jr .postmaster.quiescent)"
check "held count" "2" "$(jr .postmaster.held)"
check "unrouted count" "3" "$(jr .postmaster.unrouted)"
reason_has "'2 held seats' is a reason" "2 held seats"
reason_has "'3 unrouted messages' is a reason" "3 unrouted messages"
check "so IN-PROGRESS" "IN-PROGRESS" "$(jr .status)"

gen p5h <<'PY'
write(D, export(green()), status(held=[{"agent": "@core", "trigger": "reply", "age_s": 40}]))
PY
run_case p5h
check "a single held seat alone blocks CONVERGED" "IN-PROGRESS" "$(jr .status)"
reason_has "'1 held seat' (singular)" "1 held seat"

gen p5u <<'PY'
write(D, export(green()), status(unrouted=1))
PY
run_case p5u
check "one unrouted message alone blocks CONVERGED" "IN-PROGRESS" "$(jr .status)"
reason_has "'1 unrouted message' (singular)" "1 unrouted message"

gen p6 <<'PY'
write(D, export(green()), status(unrouted=None))
PY
run_case p6
check "an unreadable unrouted count is not quiescent" "false" "$(jr .postmaster.quiescent)"
reason_has "an unreadable unrouted count is a reason" "unrouted count is unreadable"
check "and is not CONVERGED" "IN-PROGRESS" "$(jr .status)"

printf '\n== a newer tagged message with no usable target ==\n'
gen nohdr <<'PY'
m = [root(), msg(2, "@core", "Reviewed-by: C", sha=A, ver=1),
     msg(3, "@tests", "Reviewed-by: T", sha=A, ver=1),
     msg(4, "@docs", "Reviewed-by: D", sha=A, ver=1),
     msg(5, "@core", "NAK", sha=None), sec(20)]
write(D, export(m), status())
PY
run_case nohdr
check "a header-less NAK after an on-target Reviewed-by: not CONVERGED (quiescent, so STALLED)" "STALLED" "$(jr .status)"
check "the seat is stale, not positive" "stale" "$(seat @core state)"
check "the seat reports the newer message" "NAK m005" "$(seat @core verdict) $(seat @core message_id)"
reason_has "the reason names the unstamped message" "@core: newer message m005 carries NAK with no usable X-Review-Target"
reason_has "the secretary's CONVERGED is called out" "secretary says CONVERGED but @core is stale"
check "verdict is null" "null" "$(j .verdict)"

gen nohdr2 <<'PY'
m = [root(), msg(2, "@core", "Reviewed-by: C", sha=A, ver=1),
     msg(3, "@tests", "Reviewed-by: T", sha=A, ver=1),
     msg(4, "@docs", "Reviewed-by: D", sha=A, ver=1),
     msg(5, "@core", "NAK", extra=[["X-Review-Target", "garbage"]]), sec(20)]
write(D, export(m), status())
PY
run_case nohdr2
check "an unparseable X-Review-Target NAK: not CONVERGED" "STALLED" "$(jr .status)"

gen nohdr3 <<'PY'
m = [root(body=ROOT_BODY.replace("f" * 40, A)), msg(2, "@core", "NAK", sha=None),
     msg(3, "@core", "Reviewed-by: C", sha=A, ver=1),
     msg(4, "@tests", "Reviewed-by: T", sha=A, ver=1),
     msg(5, "@docs", "Reviewed-by: D", sha=A, ver=1), sec(20)]
write(D, export(m), status())
PY
run_case nohdr3
check "a header-less NAK BEFORE the on-target Reviewed-by does not block" "CONVERGED" "$(jr .status)"

printf '\n== oversized digit strings are input, not a crash ==\n'
gen bigint <<'PY'
big = "9" * 5000
body = ROOT_BODY.replace("Version-Limit: 4", "Version-Limit: " + big)
m = [root(body=body), msg(2, "@core", "Reviewed-by: C", sha=A, extra=[["X-Version", big]]),
     msg(3, "@tests", "Reviewed-by: T", sha=A, ver=1),
     msg(4, "@docs", "Reviewed-by: D", sha=A, ver=1),
     sec(20, pver=big)]
st = status(); st["review_target"]["version"] = big
write(D, export(m), st)
PY
run_case bigint
check "huge digit strings: exit 0, an object" "0" "$RC"
if grep -q Traceback "$work/err"; then no "huge digit strings: no traceback" "$(cat "$work/err")"; else ok "huge digit strings: no traceback"; fi
check "huge Version-Limit is null" "null" "$(j .roster.version_limit)"
reason_has "huge Version-Limit is a clipped reason" "malformed Version-Limit"
check "huge target version is null" "null" "$(j .target.version)"
check "huge X-Version is null on the seat" "null" "$(seat @core version)"
reason_has "huge Panel-Version is a malformed trailer" "is not a number"
check "and it is not CONVERGED" "STALLED" "$(jr .status)"

printf '\n== suite run: the roster lines and the Suite-Run claim ==\n'
gen suite0 <<'PY'
write(D, export(green()), status())
PY
run_case suite0
check "no Suite on the root: still CONVERGED" "CONVERGED" "$(jr .status)"
check "no Suite: roster.suite is null" "null" "$(j .roster.suite)"
check "no Suite: roster.suite_seats is []" "[]" "$(j .roster.suite_seats)"
check "no Suite: every suite_run is null" "[null,null,null]" "$(j '[.seats[].suite_run]')"

gen suite1 <<'PY'
write(D, export(suite_case("Suite-Run: 12 passed, 0 failed\nReviewed-by: T")), status())
PY
run_case suite1
check "clean suite run on the verdict message: CONVERGED" "CONVERGED" "$(jr .status)"
check "roster.suite is the command" "pytest -q" "$(jr .roster.suite)"
check "roster.suite_seats" '["@tests"]' "$(j .roster.suite_seats)"
check "the suite seat's suite_run is clean" \
    '{"status":"clean","passed":12,"failed":0,"detail":null}' "$(j '.seats[] | select(.seat == "@tests") | .suite_run')"
check "a non-suite seat's suite_run is null" "null" "$(j '.seats[] | select(.seat == "@docs") | .suite_run')"

gen suite2 <<'PY'
write(D, export(suite_case("Suite-Run: could-not-run ModuleNotFoundError: No module named 'requests'\nReviewed-by: T")), status())
PY
run_case suite2
check "could-not-run on a positive suite seat: STALLED (quiescent)" "STALLED" "$(jr .status)"
reason_has "the reason names the seat" "@tests signed off without a clean suite run"
reason_has "the reason names could-not-run and the error" "could-not-run: ModuleNotFoundError: No module named 'requests'"
check "the seat's state stays positive" "positive" "$(seat @tests state)"
check "suite_run status" "could-not-run" "$(seat @tests suite_run.status)"
check "suite_run detail is the first error line" "ModuleNotFoundError: No module named 'requests'" "$(seat @tests suite_run.detail)"

gen suite2b <<'PY'
write(D, export(suite_case("Suite-Run: could-not-run ModuleNotFoundError\nReviewed-by: T")), status(runs=[run("r1", "live")]))
PY
run_case suite2b
check "could-not-run while a run is live: IN-PROGRESS, not STALLED" "IN-PROGRESS" "$(jr .status)"

gen suite3 <<'PY'
write(D, export(suite_case("Suite-Run: 3 passed, 1 failed\nReviewed-by: T")), status())
PY
run_case suite3
check "failed suite run: not CONVERGED" "STALLED" "$(jr .status)"
check "failed: status, counts" "failed 3 1" "$(seat @tests suite_run.status) $(seat @tests suite_run.passed) $(seat @tests suite_run.failed)"
reason_has "failed: the reason says so" "failed: 3 passed, 1 failed"

gen suite4 <<'PY'
write(D, export(suite_case("Suite-Run: 0 passed, 0 failed\nReviewed-by: T")), status())
PY
run_case suite4
check "0 passed, 0 failed: not CONVERGED" "STALLED" "$(jr .status)"
check "no-tests status" "no-tests" "$(seat @tests suite_run.status)"
reason_has "no-tests: the reason says so" "no-tests"

gen suite5 <<'PY'
write(D, export(suite_case("Reviewed-by: T")), status())
PY
run_case suite5
check "no Suite-Run line: not CONVERGED" "STALLED" "$(jr .status)"
check "missing status" "missing" "$(seat @tests suite_run.status)"
reason_has "missing: the reason says so" "missing"

gen suite6 <<'PY'
write(D, export(suite_case("Suite-Run: lots passed\nReviewed-by: T")), status())
PY
run_case suite6
check "malformed Suite-Run: not CONVERGED" "STALLED" "$(jr .status)"
check "malformed status" "malformed" "$(seat @tests suite_run.status)"
check "malformed detail is the offending line" "Suite-Run: lots passed" "$(seat @tests suite_run.detail)"

gen suite6b <<'PY'
bodies = ["Suite-Run: 5 passed, 0 failed extra", "Suite-Run: 5 passed, 0 failed.", "Suite-Run: 5 passed,  0 failed",
          "suite-run: 5 passed, 0 failed", "Suite-Run: could-not-runX", "Suite-Run:", "Suite-Run: -1 passed, 0 failed",
          "Suite-Run: " + "9" * 19 + " passed, 0 failed"]
for i, b in enumerate(bodies):
    os.makedirs(D + "-%d" % i, exist_ok=True)
    write(D + "-%d" % i, export(suite_case(b + "\nReviewed-by: T")), status())
PY
for i in 0 1 2 3 4 5 6 7; do
    gen_dir="$work/case-suite6b-$i"; cases_run+=("suite6b-$i")
    OUT="$("$ps" --export-file "$gen_dir/export.json" --status-file "$gen_dir/status.json" 2>/dev/null)"
    want=malformed; [[ "$i" == 3 ]] && want=missing   # variant 3 is not a Suite-Run line at all
    check "grammar is exact: variant $i is $want" "$want" "$(seat @tests suite_run.status)"
    check "grammar is exact: variant $i is not CONVERGED" "STALLED" "$(jr .status)"
done

gen suite7 <<'PY'
write(D, export(suite_case("> Suite-Run: 5 passed, 0 failed\n  Suite-Run: 5 passed, 0 failed\nReviewed-by: T")), status())
PY
run_case suite7
check "quoted or indented Suite-Run does not count: missing" "missing" "$(seat @tests suite_run.status)"
check "and it is not CONVERGED" "STALLED" "$(jr .status)"

gen suite8 <<'PY'
write(D, export(suite_case("Reviewed-by: T", older="Suite-Run: 5 passed, 0 failed\nReviewed-by: T")), status())
PY
run_case suite8
check "a clean run on an OLDER target message does not count: missing" "missing" "$(seat @tests suite_run.status)"
check "and it is not CONVERGED" "STALLED" "$(jr .status)"

gen suite9 <<'PY'
write(D, export(suite_case("Suite-Run: 5 passed, 0 failed\nSuite-Run: could-not-run no network\nReviewed-by: T")), status())
PY
run_case suite9
check "two Suite-Run lines: the last counts (clean then could-not-run)" "could-not-run" "$(seat @tests suite_run.status)"
check "and it is not CONVERGED" "STALLED" "$(jr .status)"

gen suite9b <<'PY'
write(D, export(suite_case("Suite-Run: could-not-run no network\nSuite-Run: 5 passed, 0 failed\nReviewed-by: T")), status())
PY
run_case suite9b
check "two Suite-Run lines: could-not-run then clean is clean" "CONVERGED" "$(jr .status)"

gen suite9c <<'PY'
write(D, export(suite_case("Suite-Run: could-not-run\nReviewed-by: T")), status())
PY
run_case suite9c
check "bare could-not-run: status" "could-not-run" "$(seat @tests suite_run.status)"
check "bare could-not-run: detail null" "null" "$(seat @tests suite_run.detail)"

gen suite10 <<'PY'
write(D, export(suite_case("Suite-Run: 4 passed, 0 failed\nReviewed-by: T", suite_lines=["Suite: pytest -q"])), status())
PY
run_case suite10
check "Suite without Suite-Seats, @tests on the panel: defaults to @tests" '["@tests"]' "$(j .roster.suite_seats)"
check "and it converges with a clean run" "CONVERGED" "$(jr .status)"

gen suite11 <<'PY'
write(D, export(suite_case("Reviewed-by: T", suite_lines=["Suite: pytest -q"], panel="@core, @qa, @docs")), status())
PY
run_case suite11
check "Suite without Suite-Seats and no @tests: no suite seats" "[]" "$(j .roster.suite_seats)"
reason_has "that is a reason" "Suite: set but no Suite-Seats and @tests is not on the panel"
check "and not CONVERGED" "STALLED" "$(jr .status)"

gen suite12 <<'PY'
write(D, export(suite_case("Suite-Run: 4 passed, 0 failed\nReviewed-by: T", suite_lines=["Suite: pytest -q", "Suite-Seats: @tests, @ghost"])), status())
PY
run_case suite12
reason_has "a Suite-Seats entry not on the panel is a reason" "@ghost"
check "and is dropped" '["@tests"]' "$(j .roster.suite_seats)"
check "and the thread is not CONVERGED" "STALLED" "$(jr .status)"

gen suite12b <<'PY'
write(D, export(suite_case("Reviewed-by: T", suite_lines=["Suite: pytest -q", "Suite-Seats: @ghost, tests"])), status())
PY
run_case suite12b
reason_has "a malformed Suite-Seats address is a reason" "malformed Suite-Seats address 'tests'"
reason_has "a Suite-Seats line that leaves no seat is a reason" "names no seat on the panel"
check "and no seat is a suite seat" "[null,null,null]" "$(j '[.seats[].suite_run]')"

gen suite13 <<'PY'
write(D, export(suite_case("Reviewed-by: T", suite_lines=["Suite-Seats: @tests"])), status())
PY
run_case suite13
reason_has "Suite-Seats without Suite is a reason" "Suite-Seats without a Suite"
check "and there is no Suite" "null" "$(j .roster.suite)"
check "and no suite seats" "[]" "$(j .roster.suite_seats)"
check "and not CONVERGED" "STALLED" "$(jr .status)"

gen suite14 <<'PY'
write(D, export(suite_case("Reviewed-by: T", suite_lines=["Suite:   ", "Suite-Seats: @tests"])), status())
PY
run_case suite14
reason_has "an empty Suite is a reason" "empty Suite"
check "an empty Suite reads as no Suite" "null" "$(j .roster.suite)"
check "an empty Suite never satisfies: not CONVERGED" "STALLED" "$(jr .status)"

gen suite14b <<'PY'
write(D, export(suite_case("Reviewed-by: T", suite_lines=["Suite:", "Suite: pytest -q", "Suite-Seats: @tests"])), status())
PY
run_case suite14b
check "an empty first Suite wins over a later one" "null" "$(j .roster.suite)"

gen suite15 <<'PY'
write(D, export(suite_case("Suite-Run: 4 passed, 0 failed\nReviewed-by: T", suite_lines=["Suite: pytest -q", "Suite-Seats: @tests"])), status())
PY
run_case suite15
check "a non-suite seat with no Suite-Run line, positive: no reason from it" "0" \
    "$(jq '[.reasons[] | select(contains("@docs") or contains("@core"))] | length' <<<"$OUT")"
check "and its suite_run is null" "null" "$(seat @docs suite_run)"

gen suite16 <<'PY'
m = suite_case("Changes-requested\nSuite-Run: could-not-run no network")
write(D, export(m), status())
PY
run_case suite16
check "a blocking suite seat has its suite_run filled in" "could-not-run" "$(seat @tests suite_run.status)"
check "a blocking suite seat: state stays blocking" "blocking" "$(seat @tests state)"
reason_lacks "a blocking suite seat needs no 'signed off' reason" "signed off without"

gen suite17 <<'PY'
m = [x for x in suite_case("Reviewed-by: T") if x["from"] != "@tests"]
write(D, export(m), status())
PY
run_case suite17
check "a silent suite seat: suite_run is missing" "missing" "$(seat @tests suite_run.status)"
check "a silent suite seat: state is silent" "silent" "$(seat @tests state)"
reason_lacks "a silent suite seat needs no 'signed off' reason" "signed off without"

gen suite18 <<'PY'
m = suite_case("Suite-Run: could-not-run no database\nAcked-by: T")
write(D, export(m), status())
PY
run_case suite18
check "wake-gate's view: a suite seat with could-not-run keeps state positive" "positive" "$(seat @tests state)"
check "and keeps its verdict" "Acked-by" "$(seat @tests verdict)"

gen suite19 <<'PY'
m = suite_case("Suite-Run: 5 passed, 0 failed\nReviewed-by: T")
m.insert(-1, msg(6, "@tests", "Changes-requested", sha=None))
write(D, export(m), status())
PY
run_case suite19
check "a stale override moves the seat to the newer message" "stale m006" "$(seat @tests state) $(seat @tests message_id)"
check "and suite_run is missing, not the older message's clean run" "missing" "$(seat @tests suite_run.status)"
check "and its counts are null" "null null" "$(seat @tests suite_run.passed) $(seat @tests suite_run.failed)"
check "and the thread is not CONVERGED" "STALLED" "$(jr .status)"

printf '\n== tier: the root'"'"'s X-Lkml-Tier and X-Lkml-Tier-Reason ==\n'
# Hand-worked: a v1 green panel at head A (root Frozen-Head A, three
# positives, secretary CONVERGED SIGNED-OFF v1, postmaster quiet) is
# CONVERGED regardless of tier headers; the headers only populate "tier".
gen base_tier <<'PY'
write(D, export([root()] + panel_positive()), status())
PY
run_case base_tier
check "no tier headers: tier is all null" '{"name":null,"reason":null,"source":null,"message_id":null}' "$(j .tier)"
check "no tier headers: panel is the root's panel" '["@core","@tests","@docs"]' "$(j .panel)"
check "no tier headers: every seat is carried=false" "true" "$(jr '[.seats[].carried] | all(. == false)')"

gen tier1 <<'PY'
e = green()
e[0] = root(body=ROOT_BODY.replace("f" * 40, A),
            extra=[["X-Lkml-Tier", "standard"],
                   ["X-Lkml-Tier-Reason", "touches two subsystems"]])
write(D, export(e), status())
PY
run_case tier1
check "tier on root: CONVERGED" "CONVERGED" "$(jr .status)"
check "tier on root: name, reason, source and message" \
    '{"name":"standard","reason":"touches two subsystems","source":"root","message_id":"m001"}' "$(j .tier)"
check "tier on root: carried is false on the secretary" "false" "$(jr .secretary.carried)"

gen tier2 <<'PY'
e = green()
e[0] = root(body=ROOT_BODY.replace("f" * 40, A),
            extra=[["X-Lkml-Tier", "full"],
                   ["X-Lkml-Tier-Reason", "x" * 250 + "\nsecond line"]])
write(D, export(e), status())
PY
run_case tier2
check "a long multi-line reason is clipped to its first 200 chars" "200" "$(jr '.tier.reason | length')"
check "a clipped reason is display text, not a reason: CONVERGED" "CONVERGED" "$(jr .status)"

gen tier3 <<'PY'
e = green()
e[0] = root(body=ROOT_BODY.replace("f" * 40, A),
            extra=[["X-Lkml-Tier", "huge"], ["X-Lkml-Tier-Reason", "why"]])
write(D, export(e), status())
PY
run_case tier3
check "unknown tier value: name null, reason kept" '{"name":null,"reason":"why","source":null,"message_id":null}' "$(j .tier)"
reason_has "unknown tier value is a reason" "root X-Lkml-Tier 'huge' is not quick, standard or full"
check "unknown tier value blocks CONVERGED" "STALLED" "$(jr .status)"

gen tier4 <<'PY'
e = green()
e[0] = root(body=ROOT_BODY.replace("f" * 40, A),
            extra=[["X-Lkml-Tier", "quick"], ["X-Lkml-Tier", "full"]])
write(D, export(e), status())
PY
run_case tier4
check "two different tier values: name null" "null" "$(j .tier.name)"
reason_has "two different tier values is a reason" "is not quick, standard or full"

printf '\n== push modes: escalate grows the roster and ratchets the tier ==\n'
# Shared shape: a standard-tier thread, v1 at head A (the root's Frozen-Head)
# with @core, @tests, @docs positive on A and the secretary CONVERGED
# SIGNED-OFF v1, then the human pushes H and the postmaster's mail says what
# to do about it (an upstream-moved mail, seq 30). The author's v2 is seq 31.
gen esc1 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20)]
e.append(upstream(30, H, mode="escalate",
                  extra=[["X-Lkml-Tier", "full"], ["X-Lkml-Add-Seats", "security"]]))
write(D, export(e), status())
PY
run_case esc1
# Hand-worked: the valid escalate sets the tier to full (source escalate, at
# m030, root's reason kept) and seats @security; @security has said nothing
# (silent). The push H is not the frozen head A, so it is unanswered; the
# secretary's CONVERGED is contradicted by the silent seat. Nothing is
# quiescent-blocked, so STALLED.
check "(esc1) tier ratchets to full, source escalate, reason kept" \
    '{"name":"full","reason":"two subsystems","source":"escalate","message_id":"m030"}' "$(j .tier)"
check "(esc1) the effective panel gains @security" '["@core","@tests","@docs","@security"]' "$(j .panel)"
check "(esc1) roster.panel stays the root's" '["@core","@tests","@docs"]' "$(j .roster.panel)"
check "(esc1) @security has a seat entry and is silent" "silent" "$(seat @security state)"
check "(esc1) the push is an escalate adding @security, not yet answered" \
    '{"seq":30,"message_id":"m030","sha":"1111111111111111111111111111111111111111","branch":"pr/example","mode":"escalate","seats":["@security"],"tier":"full","malformed":null,"answered":false}' "$(j .push)"
reason_has "(esc1) the unanswered push is a reason" "the human author's newest push 11111111 (seq 30)"
reason_has "(esc1) the new seat's silence is a reason" "@security: no verdict on v1 (aaaaaaaa)"
reason_has "(esc1) the secretary's CONVERGED is caught" "secretary says CONVERGED but @security is silent"
check "(esc1) STALLED" "STALLED" "$(jr .status)"

gen esc2 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20)]
e.append(upstream(30, H, mode="escalate",
                  extra=[["X-Lkml-Tier", "full"], ["X-Lkml-Add-Seats", "security"]]))
e.append(cover(31, H, 2, "Human integration.\n\nFrozen-Head: " + H))
e += panel_positive(sha=H, ver=2, start=40, who=("@core", "@tests", "@docs", "@security"))
e.append(sec(50, "CONVERGED", 2, "SIGNED-OFF", H, 2))
write(D, export(e), status(sha=H, ver=2))
PY
run_case esc2
# Hand-worked: the cover's Frozen-Head H is vouched by push seq 30 (< 31), so
# the frozen head is H (upstream) and target H == frozen head: SIGNED-OFF is
# valid. All four seats of the effective panel are positive on H v2; the
# secretary is on target (H, v2) and says CONVERGED; no push is unanswered.
check "(esc2) CONVERGED" "CONVERGED" "$(jr .status)"
check "(esc2) SIGNED-OFF at H" "SIGNED-OFF" "$(jr .verdict)"
check "(esc2) four seats" "4" "$(jr '.seats | length')"
check "(esc2) every seat carried=false" "true" "$(jr '[.seats[].carried] | all(. == false)')"
check "(esc2) the push is answered" "true" "$(jr .push.answered)"
check "(esc2) tier full" "full" "$(jr .tier.name)"

gen esc3 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20)]
e.append(upstream(30, H, mode="escalate",
                  extra=[["X-Lkml-Tier", "full"], ["X-Lkml-Add-Seats", "@security"]]))
e.append(cover(31, H, 2, "Human integration.\n\nFrozen-Head: " + H))
e += panel_positive(sha=H, ver=2, start=40)
e.append(sec(50, "CONVERGED", 2, "SIGNED-OFF", H, 2))
write(D, export(e), status(sha=H, ver=2))
PY
run_case esc3
# Hand-worked: as esc2, but the escalated-in @security never answers v2: it
# owes a verdict, so the secretary's CONVERGED is a false green.
check "(esc3) @security silent: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "(esc3) the silent escalated-in seat is named" "@security: no verdict on v2 (11111111)"
reason_has "(esc3) the secretary is caught" "secretary says CONVERGED but @security is silent"

gen esc4 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20)]
e.append(upstream(30, H, mode="escalate",
                  extra=[["X-Lkml-Tier", "quick"], ["X-Lkml-Add-Seats", "security"]]))
write(D, export(e), status())
PY
run_case esc4
# Hand-worked: quick is below the standard in force, so the escalate is
# malformed: treated as absent. Tier stays standard/root, the roster does not
# grow, the push has no mode, and the malformed text is a reason.
check "(esc4) tier stays standard from the root" '"standard" "root"' "$(jr '"\"" + .tier.name + "\" \"" + .tier.source + "\""')"
check "(esc4) the roster does not grow" '["@core","@tests","@docs"]' "$(j .panel)"
check "(esc4) push.mode is null" "null" "$(j .push.mode)"
check "(esc4) no seats from the ignored mail" "[]" "$(j .push.seats)"
reason_has "(esc4) the lower tier is reported" "push seq 30 (m030): X-Lkml-Push-Mode escalate names tier 'quick' below the current 'standard'; ignored as malformed, treated as absent"
check "(esc4) push.malformed carries the text" "true" "$(jr '.push.malformed | contains("below the current")')"

gen esc4b <<'PY'
e = [tier_root()] + panel_positive(sha=A) + [sec(20)]
e.append(upstream(30, H, mode="escalate",
                  extra=[["X-Lkml-Tier", "quick"], ["X-Lkml-Add-Seats", "security"]]))
e.append(cover(31, H, 2, "Human integration.\n\nFrozen-Head: " + H))
e += panel_positive(sha=H, ver=2, start=40)
e.append(sec(50, "CONVERGED", 2, "SIGNED-OFF", H, 2))
write(D, export(e), status(sha=H, ver=2))
PY
run_case esc4b
# Hand-worked: after the ignored escalate the author's v2 is judged as an
# ordinary push: three fresh positives on H, secretary on target. The only
# thing standing in the way is the malformed mail's own reason (A malformed
# input is a reason and blocks CONVERGED).
check "(esc4b) an ignored escalate still blocks CONVERGED, with exactly its reason" "1" "$(jr '.reasons | length')"
check "(esc4b) STALLED" "STALLED" "$(jr .status)"
check "(esc4b) seats are judged fresh on v2, none carried" "true" "$(jr '[.seats[] | .state == "positive" and .carried == false] | all')"

gen esc5 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20)]
e.append(upstream(30, H, mode="escalate", extra=[["X-Lkml-Add-Seats", "security"]]))
write(D, export(e), status())
PY
run_case esc5
# Hand-worked: an escalate with no X-Lkml-Tier names nothing to raise to.
check "(esc5) an escalate with no tier: roster does not grow" '["@core","@tests","@docs"]' "$(j .panel)"
check "(esc5) push.mode is null" "null" "$(j .push.mode)"
reason_has "(esc5) reported as naming no usable tier" "escalate names no usable X-Lkml-Tier (none); ignored as malformed"

gen esc5b <<'PY'
e = [tier_root()] + panel_positive() + [sec(20)]
e.append(upstream(30, H, mode="escalate", extra=[["X-Lkml-Tier", "huge"]]))
write(D, export(e), status())
PY
run_case esc5b
check "(esc5b) an unknown escalate tier: push.mode null" "null" "$(j .push.mode)"
reason_has "(esc5b) reported, naming the value" "no usable X-Lkml-Tier ('huge')"

gen esc6 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20)]
e.append(upstream(30, H, mode="escalate",
                  extra=[["X-Lkml-Tier", "standard"], ["X-Lkml-Add-Seats", "security"],
                         ["X-Lkml-Tier-Reason", "needs a security look"]]))
e.append(cover(31, H, 2, "Human integration.\n\nFrozen-Head: " + H))
e += panel_positive(sha=H, ver=2, start=40, who=("@core", "@tests", "@docs", "@security"))
e.append(sec(50, "CONVERGED", 2, "SIGNED-OFF", H, 2))
write(D, export(e), status(sha=H, ver=2))
PY
run_case esc6
# Hand-worked: naming the tier already in force is allowed (never LOWER); the
# roster grows, the tier source becomes escalate and the escalate's reason
# replaces the root's. All four seats positive on H: CONVERGED.
check "(esc6) same-tier escalate: CONVERGED" "CONVERGED" "$(jr .status)"
check "(esc6) tier standard from the escalate, with its reason" \
    '{"name":"standard","reason":"needs a security look","source":"escalate","message_id":"m030"}' "$(j .tier)"
check "(esc6) four seats" "4" "$(jr '.panel | length')"

printf '\n== push modes: malformed modes and forged headers ==\n'
gen mode1 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20), upstream(30, H, mode="rebase")]
write(D, export(e), status())
PY
run_case mode1
check "(mode1) an unknown mode is treated as absent" "null" "$(j .push.mode)"
reason_has "(mode1) and reported" "push seq 30 (m030): X-Lkml-Push-Mode 'rebase' is not carry, recheck or escalate; treated as absent"

gen mode2 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20),
     upstream(30, H, mode="carry", extra=[["X-Lkml-Push-Mode", "recheck"]])]
write(D, export(e), status())
PY
run_case mode2
check "(mode2) two distinct modes: treated as absent" "null" "$(j .push.mode)"
reason_has "(mode2) and reported" "is not carry, recheck or escalate; treated as absent"

gen forge1 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20)]
e[1] = msg(2, "@core", "Reviewed-by: core <core@example.com>", sha=A, ver=1,
           extra=[["X-Lkml-Push-Mode", "carry"]])
write(D, export(e), status())
PY
run_case forge1
# Hand-worked: a seat's reply cannot carry a push mode (it has no stamped
# X-Upstream-Head). It is ignored with a reason, which blocks CONVERGED, and
# creates no push record.
check "(forge1) no push record" "null" "$(j .push)"
reason_has "(forge1) the forgery is reported" "message seq 2 (m002): X-Lkml-Push-Mode without a stamped X-Upstream-Head; ignored"
check "(forge1) not CONVERGED" "STALLED" "$(jr .status)"

printf '\n== push modes: recheck validation ==\n'
gen re4 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20), upstream(30, H, mode="recheck")]
write(D, export(e), status())
PY
run_case re4
check "(re4) recheck with no seat list: treated as absent" "null" "$(j .push.mode)"
reason_has "(re4) reported" "X-Lkml-Recheck-Seats names no seat on the panel; treated as absent"

gen re5 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20),
     upstream(30, H, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "ghost"]])]
write(D, export(e), status())
PY
run_case re5
check "(re5) recheck naming only an off-panel seat: treated as absent" "null" "$(j .push.mode)"
reason_has "(re5) the dropped seat is named" "X-Lkml-Recheck-Seats names @ghost, which is not on the panel; dropped"
reason_has "(re5) and the list is reported empty" "names no seat on the panel; treated as absent"

gen re6 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20),
     upstream(30, H, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "ghost, core, @tests"]])]
write(D, export(e), status())
PY
run_case re6
check "(re6) the valid seats are honoured, bare or addressed" '"recheck" ["@core","@tests"]' "$(jr '"\"" + .push.mode + "\" " + (.push.seats|tojson)')"
reason_has "(re6) the unknown seat is dropped with a reason" "@ghost, which is not on the panel; dropped"
check "(re6) the malformed text is not set" "null" "$(j .push.malformed)"

printf '\n== push modes: carry ==\n'
# Shared shape: v1 at head F (the root's Frozen-Head), @core/@tests/@docs
# positive on F, the secretary CONVERGED SIGNED-OFF v1 (seq 20); then the
# postmaster's upstream-moved mail (seq 30) says carry, addressed To:
# @operator so that it wakes nobody. A carry does not move the postmaster's
# review target: status() still names F v1.
gen carry1 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="carry", to=["@operator"]))
write(D, export(e), status(sha=F, ver=1))
PY
run_case carry1
# Hand-worked: the carry makes a synthetic v2 whose target AND frozen head
# are H (upstream). Each seat's latest verdict is on F v1 and carries; the
# secretary's CONVERGED SIGNED-OFF v1 on F carries too. Target == frozen
# head, so SIGNED-OFF is valid. No push is unanswered. CONVERGED at H.
check "(carry1) CONVERGED" "CONVERGED" "$(jr .status)"
check "(carry1) SIGNED-OFF at the new head" "SIGNED-OFF" "$(jr .verdict)"
check "(carry1) target is the pushed head as version 2, source carry, set by the push's sender" \
    '{"branch":"pr/example","sha":"1111111111111111111111111111111111111111","version":2,"set_by":"@postmaster","set_at":"Mon, 02 Mar 2026 10:30:00 +0000","source":"carry"}' "$(j .target)"
check "(carry1) frozen head is the pushed head, upstream" '{"sha":"1111111111111111111111111111111111111111","source":"upstream"}' "$(j .frozen_head)"
check "(carry1) every seat carried, positive, from v1 at F" "true" \
    "$(jr '[.seats[] | .carried == true and .version == 1 and .state == "positive" and (.sha | startswith("ffff"))] | all')"
check "(carry1) the secretary carried" "true" "$(jr .secretary.carried)"
check "(carry1) the push is answered" "true" "$(jr .push.answered)"
check "(carry1) no reasons" "[]" "$(j .reasons)"
check "(carry1) no bundle" "null" "$(j .bundle)"
# A mail addressed To: @operator and carrying a push mode is not a question
# to the operator and flags nothing: the carry is identified by its header.
check "(carry1) not NEEDS-OPERATOR" "false" "$(jr '.status == "NEEDS-OPERATOR"')"
reason_lacks "(carry1) no reason mentions the operator" "operator"
check "(carry1) the postmaster is not a seat" "false" "$(jr '[.seats[].seat] | index("@postmaster") != null')"
check "(carry1) the roster is the same three seats" '["@core","@tests","@docs"]' "$(j .panel)"

gen carry2 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e[1] = msg(2, "@core", "Changes-requested: the loop leaks.", sha=F, ver=1)
e.append(upstream(30, H, mode="carry", to=["@operator"]))
write(D, export(e), status(sha=F, ver=1))
PY
run_case carry2
# Hand-worked: @core's blocker is its latest verdict and carries as
# blocking. Carry never turns a blocker into a pass. Quiescent: STALLED.
check "(carry2) @core is blocking, carried" "blocking true" "$(seat @core state) $(seat @core carried)"
reason_has "(carry2) the carried blocker is named" "@core: Changes-requested on v2 (carried from v1)"
check "(carry2) STALLED" "STALLED" "$(jr .status)"
reason_has "(carry2) the secretary's carried CONVERGED is caught" "secretary says CONVERGED but @core is blocking"

gen carry3 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e = [x for x in e if x["from"] != "@docs"]
e.append(upstream(30, H, mode="carry", to=["@operator"]))
write(D, export(e), status(sha=F, ver=1))
PY
run_case carry3
# Hand-worked: @docs never gave a verdict on v1, so it has nothing to carry
# and still owes one on v2.
check "(carry3) @docs is silent and not carried" "silent false" "$(seat @docs state) $(seat @docs carried)"
reason_has "(carry3) it owes a verdict" "@docs: no verdict on v2 and nothing to carry from v1"
check "(carry3) not CONVERGED" "STALLED" "$(jr .status)"

gen carry4 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e[3] = msg(4, "@docs", "Reviewed-by: D", sha=B, ver=1)
e.append(upstream(30, H, mode="carry", to=["@operator"]))
write(D, export(e), status(sha=F, ver=1))
PY
run_case carry4
# Hand-worked: @docs' only verdict is on B, a head that is not v1's: stale on
# v1, so nothing to carry from v1.
check "(carry4) @docs is stale, not carried" "stale false" "$(seat @docs state) $(seat @docs carried)"
reason_has "(carry4) it owes a verdict" "@docs: no verdict on v2 and nothing to carry from v1"

gen carry5 <<'PY'
e = [frozen_root(), cover(2, T2, 2, "Re-roll after review.")]
e += panel_positive(sha=T2, ver=2, start=10) + [sec(20, "CONVERGED", 2, "RESPIN", T2, 2)]
e.append(upstream(30, H, mode="carry", to=["@operator"]))
write(D, export(e), status(sha=T2, ver=2))
PY
run_case carry5
# Hand-worked: v2 is the author's re-roll T2, CONVERGED RESPIN. A carry to H
# makes v3 with target H == frozen head H: a RESPIN there has nothing to
# respin. Carry never rewrites a verdict, so it is a contradiction and blocks.
check "(carry5) not CONVERGED" "STALLED" "$(jr .status)"
reason_has "(carry5) RESPIN contradicts the carry version" "secretary verdict RESPIN contradicts target v3 (11111111)"

gen ver1 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="carry", to=["@operator"]))
write(D, export(e), status(sha=F, ver=1))
PY
run_case ver1
check "(ver1) one human push counts as a version: v2" "2" "$(jr .target.version)"

gen ver2 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="carry", to=["@operator"]))
e.append(upstream(31, T4, mode="carry", to=["@operator"]))
write(D, export(e), status(sha=F, ver=1))
PY
run_case ver2
# Hand-worked: two carry pushes since v1 -> v3, at the newest head.
check "(ver2) two pushes: v3 at the newest head" "3 $(printf '4%.0s' $(seq 40))" "$(jr '"\(.target.version) \(.target.sha)"')"
check "(ver2) still CONVERGED" "CONVERGED" "$(jr .status)"

gen ver3 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="carry", to=["@operator"]))
e.append(upstream(31, T4, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "core"]]))
write(D, export(e), status(sha=F, ver=1))
PY
run_case ver3
# Hand-worked: a recheck push after a carry push is unanswered: the author
# has not posted, so there is no carry version (carry applies only when every
# push since the posted version is a carry) and the unanswered push blocks.
check "(ver3) not a carry version: target stays the posted one" "postmaster 1" "$(jr '"\(.target.source) \(.target.version)"')"
reason_has "(ver3) the unanswered push is named" "the human author's newest push 44444444 (seq 31)"

gen carry6 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="carry", to=["@operator"]))
e.append(msg(31, "@core", "Changes-requested: this rebase broke the loop.", sha=F, ver=1))
write(D, export(e), status(sha=F, ver=1))
PY
run_case carry6
# Hand-worked: a seat's later reply on the (still-F) review target is its
# latest verdict and carries as such: @core now blocks the carry version.
check "(carry6) @core's later blocker wins over its earlier positive" "blocking true" "$(seat @core state) $(seat @core carried)"
check "(carry6) STALLED" "STALLED" "$(jr .status)"

printf '\n== push modes: recheck ==\n'
gen re1 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "core"]]))
e.append(cover(31, H, 2, "Small delta; core please look.\n\nFrozen-Head: " + H))
e.append(msg(40, "@core", "Reviewed-by: core <core@example.com>", sha=H, ver=2))
e.append(sec(50, "CONVERGED", 2, "SIGNED-OFF", H, 2))
write(D, export(e), status(sha=H, ver=2))
PY
run_case re1
# Hand-worked: the author's v2 (X-Version 2, target H) answers the recheck
# push (its Frozen-Head H is the push's stamped head). @core is listed: its
# fresh Reviewed-by on H counts. @tests/@docs are not listed: their v1
# verdicts on F carry. The secretary posted a fresh CONVERGED SIGNED-OFF v2
# on H. The target comes from the author's post (postmaster), not a carry.
check "(re1) CONVERGED" "CONVERGED" "$(jr .status)"
check "(re1) SIGNED-OFF at H" "SIGNED-OFF" "$(jr .verdict)"
check "(re1) target is the author's post, version 2" "postmaster 2" "$(jr '"\(.target.source) \(.target.version)"')"
check "(re1) @core fresh" "positive false" "$(seat @core state) $(seat @core carried)"
check "(re1) @tests carried from v1" "positive true 1" "$(seat @tests state) $(seat @tests carried) $(seat @tests version)"
check "(re1) @docs carried from v1" "positive true 1" "$(seat @docs state) $(seat @docs carried) $(seat @docs version)"
check "(re1) the secretary is fresh, not carried" "false" "$(jr .secretary.carried)"
check "(re1) the push is answered" "true" "$(jr .push.answered)"

gen re2 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "core"]]))
e.append(cover(31, H, 2, "Small delta; core please look.\n\nFrozen-Head: " + H))
e.append(sec(50, "CONVERGED", 2, "SIGNED-OFF", H, 2))
write(D, export(e), status(sha=H, ver=2))
PY
run_case re2
# Hand-worked: @core is listed and has said nothing on H. Its v1 positive
# does NOT carry. The others carry.
check "(re2) @core has no fresh verdict: stale, not carried" "stale false" "$(seat @core state) $(seat @core carried)"
reason_has "(re2) the recheck seat owes a verdict" "@core: no verdict on v2 (recheck seat; nothing carries)"
check "(re2) @tests still carried" "positive true" "$(seat @tests state) $(seat @tests carried)"
check "(re2) not CONVERGED" "STALLED" "$(jr .status)"
reason_has "(re2) the secretary's CONVERGED is caught" "secretary says CONVERGED but @core is stale"

gen re3 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "@core,tests"]]))
e.append(cover(31, H, 2, "Small delta.\n\nFrozen-Head: " + H))
e.append(msg(40, "@core", "Reviewed-by: C", sha=H, ver=2))
e.append(sec(50, "CONVERGED", 2, "SIGNED-OFF", H, 2))
write(D, export(e), status(sha=H, ver=2))
PY
run_case re3
# Hand-worked: '@core,tests' lists both spellings. @core is fresh; @tests is
# listed and silent on H: it owes a verdict; @docs carries.
reason_has "(re3) the bare spelling lists @tests" "@tests: no verdict on v2 (recheck seat; nothing carries)"
check "(re3) @docs carried" "true" "$(seat @docs carried)"
check "(re3) @core fresh" "false" "$(seat @core carried)"

gen re8 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "core"]]))
e.append(cover(31, H, 2, "Small delta.\n\nFrozen-Head: " + H))
e.append(msg(40, "@core", "Reviewed-by: C", sha=H, ver=2))
e.append(sec(50, "CONVERGED", 2, "SIGNED-OFF", H, 2))
e.append(cover(60, T4, 3, "Re-roll after review.\n\nFrozen-Head: " + H))
e += panel_positive(sha=T4, ver=3, start=70)
e.append(sec(80, "CONVERGED", 3, "RESPIN", T4, 3))
write(D, export(e), status(sha=T4, ver=3))
PY
run_case re8
# Hand-worked: v3 is the author's re-roll after review. The recheck push was
# answered by v2 (the first post after it), not by v3, so v3 carries nothing;
# all three seats have fresh verdicts on T4 and it converges RESPIN by itself.
check "(re8) a re-roll after the push's own version carries nothing" "true" "$(jr '[.seats[].carried] | all(. == false)')"
check "(re8) CONVERGED RESPIN" "CONVERGED RESPIN" "$(jr '"\(.status) \(.verdict)"')"

printf '\n== push modes: absent and escalate withhold the carry ==\n'
gen abs1 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H))
e.append(cover(31, H, 2, "Human integration.\n\nFrozen-Head: " + H))
write(D, export(e), status(sha=H, ver=2))
PY
run_case abs1
# Hand-worked: a push with no mode: nothing carries; the old verdicts are on
# F, not H, and are stale.
check "(abs1) no mode: no seat carried, all stale" "true" "$(jr '[.seats[] | .state == "stale" and .carried == false] | all')"
reason_has "(abs1) the usual reason" "@core: verdict is on v1 (ffffffff), none on v2 (11111111)"

gen abs2 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="escalate", extra=[["X-Lkml-Tier", "full"]]))
e.append(cover(31, H, 2, "Human integration.\n\nFrozen-Head: " + H))
write(D, export(e), status(sha=H, ver=2))
PY
run_case abs2
check "(abs2) escalate: no seat carried" "true" "$(jr '[.seats[].carried] | all(. == false)')"

gen chain1 <<'PY'
e = [frozen_root()] + panel_positive(sha=F) + [sec(20, "CONVERGED", 1, "SIGNED-OFF", F, 1)]
e.append(upstream(30, H, mode="recheck", extra=[["X-Lkml-Recheck-Seats", "core"]]))
e.append(cover(31, H, 2, "Small delta.\n\nFrozen-Head: " + H))
e.append(msg(40, "@core", "Reviewed-by: C", sha=H, ver=2))
e.append(sec(50, "CONVERGED", 2, "SIGNED-OFF", H, 2))
e.append(upstream(60, T4, mode="carry", to=["@operator"]))
write(D, export(e), status(sha=H, ver=2))
PY
run_case chain1
# Hand-worked: v2 (recheck) carried @tests/@docs from v1; a later carry push
# makes v3 at T4. @core's verdict is on H (v2); @tests' and @docs' latest are
# on F (v1) and reach v3 through v2's own carry link. The secretary's trailer
# is on v2 and carries. CONVERGED SIGNED-OFF at T4.
check "(chain1) carry after a recheck version: CONVERGED" "CONVERGED" "$(jr .status)"
check "(chain1) target v3 at T4" "3 $(printf '4%.0s' $(seq 40))" "$(jr '"\(.target.version) \(.target.sha)"')"
check "(chain1) @tests carried from v1 through v2" "true 1" "$(seat @tests carried) $(seat @tests version)"
check "(chain1) @core carried from v2" "true 2" "$(seat @core carried) $(seat @core version)"

printf '\n== push modes: suite runs carry with the verdict ==\n'
gen sc1 <<'PY'
m = suite_case("Suite-Run: 4 passed, 0 failed\nReviewed-by: T")
m.append(upstream(30, H, mode="carry", to=["@operator"]))
write(D, export(m), status(sha=A, ver=1))
PY
run_case sc1
# Hand-worked: @tests' clean Suite-Run is read off the verdict message that
# carries, so the carry version has a clean suite run and CONVERGES.
check "(sc1) the suite run carries" "clean" "$(seat @tests suite_run.status)"
check "(sc1) CONVERGED" "CONVERGED" "$(jr .status)"

gen sc2 <<'PY'
m = suite_case("Suite-Run: could-not-run no network\nReviewed-by: T")
m.append(upstream(30, H, mode="carry", to=["@operator"]))
write(D, export(m), status(sha=A, ver=1))
PY
run_case sc2
# Hand-worked: a could-not-run suite never counted on v1 and does not become
# clean by carrying.
check "(sc2) could-not-run carries as such" "could-not-run" "$(seat @tests suite_run.status)"
reason_has "(sc2) the usual suite reason, on the carry version" "@tests signed off without a clean suite run (could-not-run"
check "(sc2) not CONVERGED" "STALLED" "$(jr .status)"

printf '\n== CI gate: X-Lkml-Suite-Source ci and the operator'"'"'s CI mail ==\n'
# Shared shape: a v1 panel at head A: @core, @tests, @docs positive on A
# (seq 2-4), the secretary CONVERGED SIGNED-OFF v1 on A (seq 20), the
# postmaster quiet. The root says `ci` and still has Suite lines, but no
# seat states a Suite-Run, so under the Suite-Run gate it would be STALLED.
gen ci0 <<'PY'
write(D, export(suite_case("Reviewed-by: T")), status())
PY
run_case ci0
# Hand-worked: no Suite-Source header: the Suite-Run gate is in force, @tests
# has no Suite-Run line, so STALLED with the missing reason; ci all null.
check "(ci0) no header: STALLED on the Suite-Run gate" "STALLED" "$(jr .status)"
reason_has "(ci0) the missing Suite-Run is the reason" "@tests signed off without a clean suite run (missing"
check "(ci0) ci.source is null" "null" "$(j .ci.source)"
check "(ci0) ci is all null" '{"source":null,"status":null,"sha":null,"branch":null,"url":null,"message_id":null,"covers_target":null}' "$(j .ci)"

gen ci1 <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "success", A)]
write(D, export(e), status())
PY
run_case ci1
# Hand-worked: three positives on A, secretary CONVERGED SIGNED-OFF v1 on
# A, frozen head A == target A, newest trusted CI mail (m030, From
# @operator) says success on A. No Suite-Run anywhere, and none required.
check "(ci1) CONVERGED" "CONVERGED" "$(jr .status)"
check "(ci1) SIGNED-OFF" "SIGNED-OFF" "$(jr .verdict)"
check "(ci1) every suite_run is null" "[null,null,null]" "$(j '[.seats[].suite_run]')"
check "(ci1) the roster still reports the Suite" '"pytest -q" ["@tests"]' "$(jr '"\"" + .roster.suite + "\" " + (.roster.suite_seats | tojson)')"
check "(ci1) the ci object" '{"source":"ci","status":"success","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","branch":"pr/example","url":null,"message_id":"m030","covers_target":true}' "$(j .ci)"

gen ci1b <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "success", A, url="https://ci.example.com/run/7")]
e[3] = msg(4, "@docs", "Reviewed-by: D", sha=A, ver=1)
e[2] = msg(3, "@tests", "Suite-Run: 0 passed, 0 failed\nReviewed-by: T", sha=A, ver=1)
write(D, export(e), status())
PY
run_case ci1b
# Hand-worked: as ci1, but @tests wrote a Suite-Run that would be no-tests
# (blocking under the Suite-Run gate). Under ci it is not read: CONVERGED,
# suite_run null, and the url is carried.
check "(ci1b) a seat's Suite-Run line is not gated under ci" "CONVERGED" "$(jr .status)"
check "(ci1b) suite_run stays null" "null" "$(seat @tests suite_run)"
check "(ci1b) the url is reported" "https://ci.example.com/run/7" "$(jr .ci.url)"

gen ci2 <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "success", B)]
write(D, export(e), status())
PY
run_case ci2
# Hand-worked: the only trusted success is on B, not on the frozen head A.
# It says nothing about A: "CI has not reported on aaaaaaaa", STALLED.
check "(ci2) a result on another sha does not converge" "STALLED" "$(jr .status)"
reason_has "(ci2) CI has not reported on the head" "CI has not reported on aaaaaaaa"
check "(ci2) ci.status is null" "null" "$(j .ci.status)"
check "(ci2) ci.source is still ci" "ci" "$(jr .ci.source)"

gen ci3 <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "failure", A)]
write(D, export(e), status())
PY
run_case ci3
# Hand-worked: the result on A is failure: STALLED, "CI failed on aaaaaaaa
# (message m030)".
check "(ci3) failure blocks" "STALLED" "$(jr .status)"
reason_has "(ci3) CI failed" "CI failed on aaaaaaaa (message m030)"
check "(ci3) ci.status is failure" "failure" "$(jr .ci.status)"

gen ci4 <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "pending", A)]
write(D, export(e), status())
PY
run_case ci4
# Hand-worked: pending is no result yet: not CONVERGED.
check "(ci4) pending blocks" "STALLED" "$(jr .status)"
reason_has "(ci4) the pending reason" "CI has not reported on aaaaaaaa (pending, message m030)"

gen ci5 <<'PY'
e = [ci_root()] + panel_positive() + [sec(20)]
write(D, export(e), status())
PY
run_case ci5
# Hand-worked: no CI mail at all under ci: missing is a reason.
check "(ci5) no CI mail blocks" "STALLED" "$(jr .status)"
reason_has "(ci5) the missing reason" "CI has not reported on aaaaaaaa"
check "(ci5) ci.status is null" "null" "$(j .ci.status)"

gen ci6 <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "success", A, frm="@tests")]
write(D, export(e), status())
PY
run_case ci6
# Hand-worked: a "success" CI mail from a seat is ignored (any seat can set
# an X-* header), so there is no CI result: not CONVERGED, and the forgery
# is a reason that names the sender.
check "(ci6) a forged success does not converge" "STALLED" "$(jr .status)"
check "(ci6) ci.status is null" "null" "$(j .ci.status)"
reason_has "(ci6) the forgery is named" "from @tests carries X-Lkml-CI-Status; only @operator's CI mail counts; ignored"
reason_has "(ci6) and CI has not reported" "CI has not reported on aaaaaaaa"

gen ci6b <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "success", A),
     ci_mail(31, "failure", A, frm="@core")]
write(D, export(e), status())
PY
run_case ci6b
# Hand-worked: the trusted success (m030) stands; the later forged failure
# from @core is ignored, so the only blocker is the forgery reason itself.
check "(ci6b) the trusted result stands" "success m030" "$(jr '"\(.ci.status) \(.ci.message_id)"')"
check "(ci6b) the forgery is the only reason" "1" "$(jr '.reasons | length')"
check "(ci6b) STALLED on that reason alone" "STALLED" "$(jr .status)"

gen ci7a <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), upstream(30, H, mode="carry", to=["@operator"]),
     ci_mail(31, "success", A)]
write(D, export(e), status())
PY
run_case ci7a
# Hand-worked: a carry push to H makes the thread v2 at H: the verdicts and
# the secretary carry, the frozen head is H. CI succeeded on A, the OLD
# head, which says nothing about H: not CONVERGED.
check "(ci7a) CI on the old head does not cover the pushed head" "STALLED" "$(jr .status)"
reason_has "(ci7a) CI has not reported on the pushed head" "CI has not reported on 11111111"
check "(ci7a) the target is the carry version at H" "2 $(printf '1%.0s' $(seq 40))" "$(jr '"\(.target.version) \(.target.sha)"')"

gen ci7b <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), upstream(30, H, mode="carry", to=["@operator"]),
     ci_mail(31, "success", H)]
write(D, export(e), status())
PY
run_case ci7b
# Hand-worked: as ci7a, but CI succeeded on H: the carried verdicts plus a
# green CI on the new frozen head converge, SIGNED-OFF (target == frozen head).
check "(ci7b) CI on the pushed head converges the carry version" "CONVERGED SIGNED-OFF" "$(jr '"\(.status) \(.verdict)"')"
check "(ci7b) ci.sha is H" "$(printf '1%.0s' $(seq 40))" "$(jr .ci.sha)"
check "(ci7b) covers the target" "true" "$(jr .ci.covers_target)"

gen ci8 <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "success", A), ci_mail(31, "failure", A)]
write(D, export(e), status())
PY
run_case ci8
# Hand-worked: two trusted results on A; the newest (seq 31) is failure.
check "(ci8) the newest result wins: failure" "STALLED" "$(jr .status)"
reason_has "(ci8) failed on message m031" "CI failed on aaaaaaaa (message m031)"
check "(ci8) ci.message_id" "m031" "$(jr .ci.message_id)"

gen ci8b <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "failure", A), ci_mail(31, "success", A)]
write(D, export(e), status())
PY
run_case ci8b
# Hand-worked: failure at seq 30, then success at seq 31 (a re-run): the
# newest is success.
check "(ci8b) a re-run that passed converges" "CONVERGED" "$(jr .status)"
check "(ci8b) ci.message_id" "m031" "$(jr .ci.message_id)"

gen ci9 <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "success", A)]
e[0] = ci_root()
e[0]["headers"] = [h for h in e[0]["headers"] if h[0] != "X-Lkml-Suite-Source"] + [["X-Lkml-Suite-Source", "local"]]
write(D, export(e), status())
PY
run_case ci9
# Hand-worked: Suite-Source 'local' is not ci: reason, Suite-Run gate in
# force (@tests has no Suite-Run: missing), ci.source null, yet the trusted
# success on A is still reported as a fact.
check "(ci9) unknown source: STALLED" "STALLED" "$(jr .status)"
reason_has "(ci9) the source reason" "root X-Lkml-Suite-Source 'local' is not ci; the Suite-Run gate stays in force"
reason_has "(ci9) the Suite-Run gate is in force" "@tests signed off without a clean suite run (missing"
check "(ci9) ci.source is null" "null" "$(j .ci.source)"
check "(ci9) the CI result is still a fact" "success" "$(jr .ci.status)"
check "(ci9) @tests' suite_run is read as before" "missing" "$(seat @tests suite_run.status)"

gen ci9b <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "success", A)]
e[0]["headers"].append(["X-Lkml-Suite-Source", "local"])
write(D, export(e), status())
PY
run_case ci9b
# Hand-worked: two distinct values (ci, local) are not 'ci': same as ci9.
check "(ci9b) two distinct values leave the Suite-Run gate in force" "null" "$(j .ci.source)"
reason_has "(ci9b) the source reason" "is not ci; the Suite-Run gate stays in force"

gen ci10 <<'PY'
e = green(sha=B, ver=2)
e[0] = root(sha=B, ver=2, body=ROOT_BODY, extra=[["X-Lkml-Suite-Source", "ci"]])
e.append(ci_mail(30, "success", F))
write(D, export(e), status(sha=B, ver=2))
PY
run_case ci10
# Hand-worked: v2 at B is the author's re-roll on top of the frozen head F.
# CI succeeded on F, the frozen head; B itself (the panel's own commits) was
# never CI-tested. RESPIN is valid (B is not the frozen head), the gate
# passes on F, ci.covers_target says false, and the bundle is F..B.
check "(ci10) CONVERGED RESPIN" "CONVERGED RESPIN" "$(jr '"\(.status) \(.verdict)"')"
check "(ci10) the result is on the frozen head, not the target" "false" "$(jr .ci.covers_target)"
check "(ci10) bundle base is the frozen head" "$(printf 'f%.0s' $(seq 40))" "$(jr .bundle.base)"

gen ci11 <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "green", A)]
write(D, export(e), status())
PY
run_case ci11
# Hand-worked: status 'green' is not success/failure/pending: ignored with a
# reason, so no result: not CONVERGED.
check "(ci11) a bad status is ignored" "STALLED" "$(jr .status)"
reason_has "(ci11) the malformed reason" "X-Lkml-CI-Status 'green' is not success, failure or pending; ignored"
reason_has "(ci11) and no result" "CI has not reported on aaaaaaaa"

gen ci11b <<'PY'
e = [ci_root()] + panel_positive() + [sec(20), ci_mail(30, "success", A, head_value="garbage")]
write(D, export(e), status())
PY
run_case ci11b
# Hand-worked: a head that is not '<branch> <sha>' names no commit: ignored.
check "(ci11b) an unparseable head is ignored" "STALLED" "$(jr .status)"
reason_has "(ci11b) the malformed reason" "no parseable X-Lkml-CI-Head; ignored"
reason_has "(ci11b) and no result" "CI has not reported"

gen ci12 <<'PY'
body = "\n".join(l for l in ROOT_BODY.split("\n") if not l.startswith("Frozen-Head:"))
e = [ci_root(body=body)] + panel_positive() + [sec(20), ci_mail(30, "success", A)]
write(D, export(e), status())
PY
run_case ci12
# Hand-worked: no Frozen-Head anywhere, so no CI result can be matched to a
# head: a reason, STALLED (SIGNED-OFF on v1 is otherwise valid).
check "(ci12) no frozen head under ci: STALLED" "STALLED" "$(jr .status)"
reason_has "(ci12) the named reason" "CI gate: no frozen head is known, so no CI result can apply"

printf '\n== operator questions and the timeout ==\n'
# Shared shape: qthread(): v1 at head A, @core's message at seq 2 (dated
# 2026-03-02T10:02:00Z), @tests/@docs positive, the secretary saying
# CONVERGED SIGNED-OFF. The question is a message tagged Question whose
# To includes @operator. Whatever @core's message resolves to is the only
# open variable.
gen q1 <<'PY'
write(D, export(qthread(Q, hours=None)), status())
PY
run_case q1 --now 2026-03-02T12:02:00Z
# Hand-worked: asked 10:02:00Z, now 12:02:00Z: 7200 s. No timeout header, so
# timed_out is null and the question blocks: @core is in state question,
# the secretary's CONVERGED is contradicted, STALLED.
check "(q1) one operator question is listed" \
    '{"seat":"@core","message_id":"m002","asked_at":"2026-03-02T10:02:00Z","age_seconds":7200,"timed_out":null,"subject":"Re: [PATCH v1] Fix the thing"}' \
    "$(j '.questions[0]')"
check "(q1) exactly one" "1" "$(jr '.questions | length')"
check "(q1) no timeout: null" "null" "$(j .question_timeout_hours)"
check "(q1) now is the given clock" "2026-03-02T12:02:00Z" "$(jr .now)"
check "(q1) the seat is in state question" "question" "$(seat @core state)"
reason_has "(q1) it blocks as an unanswered Question" "@core: unanswered Question on v1"
check "(q1) STALLED" "STALLED" "$(jr .status)"

gen q2 <<'PY'
write(D, export(qthread(Q, hours=None, to=("@pr-author",))), status())
PY
run_case q2 --now 2026-03-02T12:02:00Z
# Hand-worked: not addressed to @operator: an ordinary Question, not listed,
# still blocking.
check "(q2) a Question not addressed to @operator is not listed" "[]" "$(j .questions)"
check "(q2) it blocks as before" "question" "$(seat @core state)"

gen q3 <<'PY'
write(D, export(qthread(Q, hours="2h")), status())
PY
run_case q3 --now 2026-03-02T11:00:00Z
# Hand-worked: asked 10:02:00Z, now 11:00:00Z: 58 min = 3480 s < 7200. Not
# timed out; still blocks.
check "(q3) age" "3480" "$(jr '.questions[0].age_seconds')"
check "(q3) before the timeout: timed_out false" "false" "$(jr '.questions[0].timed_out')"
check "(q3) the timeout is reported" "2" "$(jr .question_timeout_hours)"
check "(q3) before the timeout it blocks" "question" "$(seat @core state)"
check "(q3) STALLED" "STALLED" "$(jr .status)"

gen q4 <<'PY'
write(D, export(qthread(Q + "\nReviewed-by: C <c@example.com>", hours="2h")), status())
PY
run_case q4 --now 2026-03-02T13:00:00Z
# Hand-worked: the same message carries Question (first line) and a
# Reviewed-by trailer. Age 10680 s >= 7200: timed out, Question dropped,
# Reviewed-by decides: @core positive on A; all three positive, secretary on
# target: CONVERGED SIGNED-OFF.
check "(q4) timed_out true" "true" "$(jr '.questions[0].timed_out')"
check "(q4) @core is positive from the same message" "positive Reviewed-by m002" "$(seat @core state) $(seat @core verdict) $(seat @core message_id)"
check "(q4) CONVERGED" "CONVERGED" "$(jr .status)"

run_case q4 --now 2026-03-02T12:02:00Z
# Hand-worked: age exactly 7200 s: the boundary counts as timed out.
check "(q4b) exactly at the timeout: timed out" "true" "$(jr '.questions[0].timed_out')"
check "(q4b) and positive" "positive" "$(seat @core state)"

run_case q4 --now 2026-03-02T12:01:59Z
# Hand-worked: one second short: 7199 s: not timed out, Question wins.
check "(q4c) one second before: not timed out" "false" "$(jr '.questions[0].timed_out')"
check "(q4c) and blocking" "question" "$(seat @core state)"

gen q5 <<'PY'
write(D, export(qthread(Q, hours="2h")), status())
PY
run_case q5 --now 2026-03-02T13:00:00Z
# Hand-worked: Question was the message's only tag. Timed out, the tag is
# dropped and nothing remains: @core has given no verdict on v1, so it is
# silent and owes one; a timeout never makes it positive. STALLED.
check "(q5) timed out" "true" "$(jr '.questions[0].timed_out')"
check "(q5) the seat is silent, not positive" "silent" "$(seat @core state)"
reason_has "(q5) it still owes a verdict" "@core: no verdict on v1 (aaaaaaaa)"
check "(q5) STALLED" "STALLED" "$(jr .status)"

gen q5b <<'PY'
e = qthread(Q, hours="2h")
e[1] = msg(2, "@core", "Reviewed-by: C", sha=A, ver=1)
e.insert(2, question(5, "@core", Q))
write(D, export(e), status())
PY
run_case q5b --now 2026-03-02T10:30:00Z
# Hand-worked: @core said Reviewed-by at seq 2, then asked at seq 5 (dated
# 10:05). Now 10:30: age 1500 s < 7200: the later Question is the verdict on
# A: unanswered.
check "(q5b) before the timeout the later question wins" "question m005" "$(seat @core state) $(seat @core message_id)"
reason_has "(q5b) unanswered Question" "@core: unanswered Question on v1"
run_case q5b --now 2026-03-02T13:00:00Z
# Hand-worked: now 13:00: age 10500 s >= 7200: m005 is timed out and loses
# its only tag; @core's verdict is the earlier Reviewed-by m002: positive,
# CONVERGED.
check "(q5b) after the timeout the earlier verdict decides" "positive m002" "$(seat @core state) $(seat @core message_id)"
check "(q5b) CONVERGED" "CONVERGED" "$(jr .status)"

gen q5c <<'PY'
e = [timeout_root("2h")] + panel_positive() + [sec(20), upstream(30, H, mode="carry", to=["@operator"]),
     question(31, "@core", Q)]
write(D, export(e), status(sha=A, ver=1))
PY
run_case q5c --now 2026-03-02T10:40:00Z
# Hand-worked: v1 positive at m002-m004; a carry push (seq 30) makes v2 at H
# and every verdict carries; @core then asks at seq 31 (10:31) on sha A. Now
# 10:40: age 540 s: not timed out; the question is @core's latest message
# on v1, which carries, so it blocks "(carried from v1)".
reason_has "(q5c) before the timeout the carried question blocks" "@core: unanswered Question on v2 (carried from v1)"
run_case q5c --now 2026-03-02T13:00:00Z
# Hand-worked: age 8940 s >= 7200: the question loses its only tag, so
# @core's latest tagged message on v1 is its Reviewed-by m002, which carries
# onto H: CONVERGED SIGNED-OFF at H. The question is still listed (it is on
# v1, not the target).
check "(q5c) after the timeout the earlier verdict carries" "true 1 positive" "$(seat @core carried) $(seat @core version) $(seat @core state)"
check "(q5c) CONVERGED" "CONVERGED" "$(jr .status)"
check "(q5c) the question on v1 is still listed" "m031" "$(jr '.questions[0].message_id')"

gen q6 <<'PY'
vals = ["2", "0h", "two hours", "2h30m", " h", "-1h", "2H", ("2h", "3h")]
for i, v in enumerate(vals):
    os.makedirs(D + "-%d" % i, exist_ok=True)
    write(D + "-%d" % i, export(qthread(Q, hours=v)), status())
PY
for i in 0 1 2 3 4 5 6 7; do
    gen_dir="$work/case-q6-$i"; cases_run+=("q6-$i")
    OUT="$("$ps" --export-file "$gen_dir/export.json" --status-file "$gen_dir/status.json" --now 2026-03-02T23:00:00Z 2>/dev/null)"
    # Hand-worked: a malformed or conflicting header is no timeout, whatever
    # the age (12 h 58 min): reported, question_timeout_hours null,
    # timed_out null, and the question blocks.
    check "(q6-$i) malformed timeout: no hours" "null" "$(j .question_timeout_hours)"
    check "(q6-$i) timed_out is null" "null" "$(j '.questions[0].timed_out')"
    check "(q6-$i) still blocks" "question" "$(seat @core state)"
    reason_has "(q6-$i) the malformed reason" "is not <N>h with N >= 1; no timeout applied"
done

gen q7 <<'PY'
write(D, export(qthread(Q, hours=None)), status())
PY
run_case q7 --now yesterday
check "(q7) a malformed --now is a usage error" "2" "$RC"
run_case q7 --now
check "(q7) --now without a value is a usage error" "2" "$RC"
run_case q7 --now=2026-03-02T12:02:00+01:00
# Hand-worked: 12:02+01:00 is 11:02Z: age against 10:02Z is 3600 s.
check "(q7) the --now= form and a zone offset" "3600 2026-03-02T11:02:00Z" "$(jr '"\(.questions[0].age_seconds) \(.now)"')"
run_case q7
check "(q7) no --now: the clock, as an ISO UTC stamp" "true" "$(jr '.now | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")')"

gen q8 <<'PY'
e = qthread(Q, hours="2h")
e[1]["date"] = "sometime last week"
write(D, export(e), status())
PY
run_case q8 --now 2026-03-02T13:00:00Z
# Hand-worked: an unreadable Date leaves asked_at/age/timed_out null and the
# question blocking (the safe direction), with a reason naming the message.
check "(q8) null asked_at, age and timed_out" "null null null" "$(jr '"\(.questions[0].asked_at) \(.questions[0].age_seconds) \(.questions[0].timed_out)"')"
reason_has "(q8) the unreadable Date is named" "question m002 from @core: unreadable Date; the timeout cannot apply"
check "(q8) the question still blocks" "question" "$(seat @core state)"

gen q9 <<'PY'
e = qthread(Q, hours="2h")
e[1] = msg(2, "@core", "Reviewed-by: C", sha=A, ver=1)
e.insert(2, question(25, "@secretary", Q, to=("@operator",)))
write(D, export(e), status())
PY
run_case q9 --now 2026-03-02T13:00:00Z
# Hand-worked: @secretary is not a panel seat: its question is not an
# operator question for the panel's purposes and is not listed.
check "(q9) a non-panel sender's question is not listed" "[]" "$(j .questions)"

gen q10 <<'PY'
e = [tier_root()] + panel_positive() + [sec(20)]
e.append(upstream(30, H, mode="escalate",
                  extra=[["X-Lkml-Tier", "full"], ["X-Lkml-Add-Seats", "security"]]))
e.append(cover(31, H, 2, "Human integration.\n\nFrozen-Head: " + H))
e += panel_positive(sha=H, ver=2, start=40)
e.append(question(43, "@security", Q, sha=H, ver=2))
write(D, export(e), status(sha=H, ver=2))
PY
run_case q10 --now 2026-03-02T13:00:00Z
# Hand-worked: @security was escalated onto the effective panel at seq 30,
# so its question to @operator at seq 43 is listed; no timeout header, so it
# blocks.
check "(q10) an escalated-in seat's question is listed" "@security m043 null" "$(jr '"\(.questions[0].seat) \(.questions[0].message_id) \(.questions[0].timed_out)"')"
check "(q10) it blocks" "question" "$(seat @security state)"

printf '\n== invariants over every case above ==\n'
inv_bad=""; inv_n=0; inv_conv=0; diff_bad=""; diff_n=0
# Opt-in differential check: LKML_PANEL_STATE_BASELINE names an earlier copy
# of the script. For every case whose export carries no X-Lkml-* header the
# new output, minus the keys this change added, must equal the old output
# byte for byte. Unset, it did not run, and reports nothing.
baseline="${LKML_PANEL_STATE_BASELINE:-}"
strip_new='del(.tier, .panel, .push, .ci, .questions, .question_timeout_hours, .now) | .seats |= map(del(.carried)) | if .secretary then .secretary |= del(.carried) else . end'
for c in "${cases_run[@]}"; do
    d="$work/case-$c"
    o="$("$ps" --export-file "$d/export.json" --status-file "$d/status.json" 2>/dev/null)" || { inv_bad+=" $c(exit)"; continue; }
    inv_n=$(( inv_n + 1 ))
    if [[ -n "$baseline" ]] && ! grep -q 'X-Lkml-' "$d/export.json"; then
        ob="$(python3 "$baseline" --export-file "$d/export.json" --status-file "$d/status.json" 2>/dev/null)"
        diff_n=$(( diff_n + 1 ))
        [[ "$(jq -c "$strip_new" <<<"$o")" == "$ob" ]] || diff_bad+=" $c"
    fi
    if ! jq -e '
        (["schema","thread","subject","status","verdict","target","roster","tier","panel","push","frozen_head","ci","question_timeout_hours","questions","now","seats","secretary","postmaster","bundle","reasons"]
         - keys | length) == 0
        and (.status | IN("CONVERGED","IN-PROGRESS","STALLED","NEEDS-OPERATOR"))
        and ((.status == "CONVERGED") == (.reasons | length == 0))
        and (.verdict == null or .status == "CONVERGED")
        and (.bundle == null or .verdict == "RESPIN")
        and (.postmaster | has("quiescent") and has("flagged") and has("flag_reason") and has("live_runs")
             and has("pending_retries") and has("held") and has("unrouted"))
        and (.roster | has("author") and has("panel") and has("secretary") and has("version_limit") and has("frozen_head")
             and has("suite") and has("suite_seats"))
        and all(.seats[]; has("seat") and has("state") and has("verdict") and has("message_id") and has("version") and has("sha") and has("suite_run") and has("carried"))
        and all(.seats[]; (.suite_run == null) or (.suite_run | has("status") and has("passed") and has("failed") and has("detail")))
        and (.status != "CONVERGED" or all(.seats[]; .suite_run == null or .suite_run.status == "clean"))
        and (.roster.suite != null or .roster.suite_seats == [])
        and (.secretary == null or (.secretary | has("message_id") and has("version") and has("status")
             and has("verdict") and has("on_target") and has("malformed") and has("carried")))
        and (.ci | has("source") and has("status") and has("sha") and has("branch") and has("url") and has("message_id") and has("covers_target"))
        and (.status != "CONVERGED" or .ci.source != "ci" or .ci.status == "success")
        and (.questions | type == "array")
        and all(.questions[]; has("seat") and has("message_id") and has("asked_at") and has("age_seconds") and has("timed_out") and has("subject"))
        and (.now | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and (.tier | has("name") and has("reason") and has("source") and has("message_id"))
        and (.push == null or (.push | has("mode") and has("message_id") and has("seq") and has("sha") and has("seats") and has("tier") and has("malformed") and has("answered")))
        and (.panel | type == "array") and (.panel[:(.roster.panel | length)] == .roster.panel)
        and (.target == null or (.target | has("branch") and has("sha") and has("version") and has("set_by") and has("set_at") and has("source")))
        and (.status != "CONVERGED" or (.seats | length > 0 and all(.[]; .state == "positive")))
        and (.status != "CONVERGED" or (.secretary.on_target == true and .secretary.status == "CONVERGED"))
        and (.status != "CONVERGED" or .postmaster.quiescent == true)
    ' <<<"$o" >/dev/null; then inv_bad+=" $c"; fi
    [[ "$(jq -r .status <<<"$o")" == CONVERGED ]] && inv_conv=$(( inv_conv + 1 ))
done
check "every case obeys the output invariants (keys present; reasons empty iff CONVERGED; CONVERGED implies every seat positive, secretary on target, quiescent)" "" "$inv_bad"
if [[ "$inv_n" -ge 60 ]]; then ok "the invariants ran over $inv_n cases"; else no "the invariants ran over too few cases" "$inv_n"; fi
if [[ "$inv_conv" -ge 5 ]]; then ok "and $inv_conv of them were CONVERGED (the check is not vacuous)"
else no "too few CONVERGED cases for the invariants to bite" "$inv_conv"; fi
if [[ -n "$baseline" ]]; then
    check "differential: $diff_n header-free cases match the baseline apart from the new keys" "" "$diff_bad"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
