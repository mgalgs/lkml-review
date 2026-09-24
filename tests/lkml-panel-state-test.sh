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
    if verdict is None:
        verdict = "SIGNED-OFF" if ver == 1 else "RESPIN"
    return ([root(sha=sha, ver=ver)] + panel_positive(sha=sha, ver=ver)
            + [sec(20, "CONVERGED", ver, verdict, sha, ver)])

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
    OUT="$("$ps" --export-file "$d/export.json" --status-file "$d/status.json" 2>"$work/err")"; RC=$?
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
    '{"message_id":"m020","version":1,"status":"CONVERGED","verdict":"SIGNED-OFF","on_target":true,"malformed":null}' \
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
write(D, export(green(sha=A, ver=1, verdict="RESPIN")), status())
PY
run_case v2
check "RESPIN on a v1 target: not CONVERGED" "STALLED" "$(jr .status)"
reason_has "RESPIN on v1: the contradiction is named" "RESPIN contradicts target v1"
check "RESPIN on v1: no bundle" "null" "$(j .bundle)"

gen v3 <<'PY'
write(D, export(green(sha=C, ver=4)), status(sha=C, ver=4))
PY
run_case v3
check "v4 RESPIN: CONVERGED" "CONVERGED" "$(jr .status)"

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

printf '\n== invariants over every case above ==\n'
inv_bad=""; inv_n=0; inv_conv=0
for c in "${cases_run[@]}"; do
    d="$work/case-$c"
    o="$("$ps" --export-file "$d/export.json" --status-file "$d/status.json" 2>/dev/null)" || { inv_bad+=" $c(exit)"; continue; }
    inv_n=$(( inv_n + 1 ))
    if ! jq -e '
        (["schema","thread","subject","status","verdict","target","roster","seats","secretary","postmaster","bundle","reasons"]
         - keys | length) == 0
        and (.status | IN("CONVERGED","IN-PROGRESS","STALLED","NEEDS-OPERATOR"))
        and ((.status == "CONVERGED") == (.reasons | length == 0))
        and (.verdict == null or .status == "CONVERGED")
        and (.bundle == null or .verdict == "RESPIN")
        and (.postmaster | has("quiescent") and has("flagged") and has("flag_reason") and has("live_runs")
             and has("pending_retries") and has("held") and has("unrouted"))
        and (.roster | has("author") and has("panel") and has("secretary") and has("version_limit") and has("frozen_head"))
        and all(.seats[]; has("seat") and has("state") and has("verdict") and has("message_id") and has("version") and has("sha"))
        and (.secretary == null or (.secretary | has("message_id") and has("version") and has("status")
             and has("verdict") and has("on_target") and has("malformed")))
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
