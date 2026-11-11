#!/usr/bin/env bash
# lkml-gap-monitor-test.sh — Exercise lkml-gap-monitor.py.
#
# Every test drives the script's command line against a "world": a temp
# directory holding the mail list and thread exports, the six forge files
# per pull request (in the shapes the live systems print: headers as a
# list of pairs, paginated files as arrays of pages, cross-reference
# events with no id, committed events with no created_at), and stub
# commands on PATH or in the config that serve them and log their argv.
# The clock is injected with --now; nothing sleeps. A generated helper
# (fx.py) builds the worlds; jq reads answers back. All names are invented.
#
# Usage: tests/lkml-gap-monitor-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
gm_script="${LKML_GAP_MONITOR:-$repo_dir/scripts/lkml-gap-monitor.py}"

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
lacks() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) no "$label" "'$needle' unexpectedly found in: $haystack" ;;
        *) ok "$label" ;;
    esac
}

# Git runs under a neutral config: an operator's own settings must not
# change what these fixtures mean.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

top="$(mktemp -d)"; tmpdirs+=("$top")
export NOW=2026-11-10T12:00:00Z
mkdir -p "$top/bin"

# ---- the fixture builder ----------------------------------------------------
cat > "$top/fx.py" <<'FX'
import json, os, datetime as dt
from email.utils import format_datetime

A, B, C = "a" * 40, "b" * 40, "c" * 40
SO = "2026-11-08T09:00:00Z"      # the usual sign-off
OLD = "2026-11-09T09:00:00Z"     # feedback past the 6 h quiet period at NOW
LONG = "This changes the retry ladder, and the flush can now stall forever on an empty queue."


def iso(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def rfc(s):
    return format_datetime(iso(s)) if s[:2] == "20" else s


def pages(items, n=2):
    return [items[i:i + n] for i in range(0, len(items), n)] or [[]]


class World:
    def __init__(self):
        self.d = os.environ["WORLD"]
        self.threads = {}
        self.prs = {}

    def thread(self, tid, pr, started="2026-11-07T09:00:00Z", reason=None,
               tier="standard", parent=None, secretary="@secretary", body=None):
        h = [["X-Lkml-Tier", tier]] if tier else []
        if pr is not None:
            h.insert(0, ["X-Preview-PR", str(pr)])
        if reason:
            h.append(["X-Lkml-Tier-Reason", reason])
        if parent:
            h.append(["X-Lkml-Parent-Thread", parent])
        if body is None:
            body = "Author: @pr-author\nPanel: @core, @tests\nSecretary: %s\nAdvisory: @second-opinion\n\n## What?\n\nBase: %s\n" % (secretary, "d" * 40)
        t = {"tid": tid, "pr": pr, "headers": h, "msgs": []}
        self.threads[tid] = t
        self.msg(tid, tid + "-root", started, "@ci-example", body, headers=h, subject="[PATCH v1 0/1] widget (#%s)" % pr)
        return t

    def msg(self, tid, mid, date, frm, body, headers=None, subject="re: widget", **kw):
        t = self.threads[tid]
        hs = list(headers) if headers is not None else []
        hs.append(["Date", rfc(date)])
        for k, v in kw.get("extra", []):
            hs.append([k, v])
        t["msgs"].append({"seq": len(t["msgs"]) + 1, "id": mid, "headers": hs, "from": frm,
                          "to": ["@core"], "cc": [], "subject": subject, "date": rfc(date),
                          "in_reply_to": None, "body": body, "attachments": []})

    def signoff(self, tid, mid, date, verdict="SIGNED-OFF", status="CONVERGED", sha=A,
                frm="@secretary", after="", target="widget-branch", version=1, tail_blank=0):
        trailer = "Panel-Version: %d\nPanel-Status: %s\n" % (version, status)
        if verdict:
            trailer += "Panel-Verdict: %s\n" % verdict
        body = "Closing summary.\n\n" + trailer.rstrip("\n") + "\n" * (1 + tail_blank) + after
        extra = [["X-Version", str(version)]]
        if target:
            extra.append(["X-Review-Target", "%s %s" % (target, sha) if target != "bare" else sha])
        self.msg(tid, mid, date, frm, body, extra=extra)

    # forge side
    def pr(self, n, author="alice", title="Retry a stalled flush", body="Retries the flush.",
           state="open", merged_at=None, created="2026-11-06T09:00:00Z"):
        self.prs[n] = {"pr": {"title": title, "body": body, "user": {"login": author},
                              "state": state, "merged_at": merged_at, "merge_commit_sha": None,
                              "created_at": created, "head": {"sha": B}, "base": {"ref": "main"}},
                       "reviews": [], "review-comments": [], "issue-comments": [],
                       "commits": [], "timeline": [{"event": "committed", "sha": A, "message": "x"}]}

    def _p(self, n):
        if n not in self.prs:
            self.pr(n)
        return self.prs[n]

    def user(self, login, utype=None):
        u = {"login": login}
        if utype:
            u["type"] = utype
        return u

    def review(self, n, id, at, user, body, state="COMMENTED", utype=None, submitted=True):
        self._p(n)["reviews"].append({"id": id, "submitted_at": at if submitted else None,
                                      "user": self.user(user, utype), "state": state, "body": body,
                                      "html_url": "https://example.com/r/%s" % id, "commit_id": A})

    def inline(self, n, id, at, user, body, reply_to=None, utype=None):
        self._p(n)["review-comments"].append({
            "id": id, "created_at": at, "user": self.user(user, utype), "body": body,
            "html_url": "https://example.com/i/%s" % id, "path": "src/flush.c", "line": None,
            "original_line": 7, "original_commit_id": A, "in_reply_to_id": reply_to,
            "pull_request_review_id": 1, "diff_hunk": "@@ -1,2 +1,2 @@\n-old\n+new"})

    def comment(self, n, id, at, user, body, utype=None, updated=None):
        self._p(n)["issue-comments"].append({"id": id, "created_at": at, "updated_at": updated or at,
                                             "user": self.user(user, utype), "body": body,
                                             "html_url": "https://example.com/c/%s" % id})

    def xref(self, n, num, at, title="Neutral cleanup", body="", labels=(), created=None, user="dave", pull=False):
        src = {"number": num, "title": title, "body": body, "html_url": "https://example.com/x/%s" % num,
               "state": "open", "created_at": created or at, "user": {"login": user},
               "labels": [{"name": l} for l in labels]}
        if pull:
            src["pull_request"] = {}
        self._p(n)["timeline"].append({"event": "cross-referenced", "created_at": at,
                                       "actor": {"login": user}, "source": {"issue": src}})

    def event(self, n, kind, at):
        self._p(n)["timeline"].append({"event": kind, "created_at": at, "actor": {"login": "erin"},
                                       "commit_id": C})

    def commit(self, n, sha, date, message):
        self._p(n)["commits"].append({"sha": sha, "commit": {"author": {"name": "alice", "email": "alice@example.com", "date": date},
                                                              "message": message}})

    def base(self, pr=1, author="alice", so="so1", at=SO, verdict="SIGNED-OFF", sha=A, tid="t1", reason=None):
        self.thread(tid, pr, reason=reason)
        self.signoff(tid, so, at, verdict=verdict, sha=sha)
        self.pr(pr, author=author)

    def save(self):
        os.makedirs(self.d + "/mail", exist_ok=True)
        listing = []
        for tid, t in self.threads.items():
            last = t["msgs"][-1]["date"]
            listing.append({"thread": tid, "messages": len(t["msgs"]), "subject": "s", "from": "@ci-example",
                            "date": t["msgs"][0]["date"], "last_date": last, "root_headers": t["headers"],
                            "review_target": {}})
            exp = {"thread": tid, "messages": t["msgs"], "senders": [], "addressed": []}
            json.dump(exp, open("%s/mail/%s.json" % (self.d, tid), "w"))
        json.dump(listing, open(self.d + "/mail/list.json", "w"))
        for n, p in self.prs.items():
            fd = "%s/forge/%d" % (self.d, n)
            os.makedirs(fd, exist_ok=True)
            json.dump(p["pr"], open(fd + "/pr.json", "w"))
            for name in ("reviews", "review-comments", "issue-comments", "commits", "timeline"):
                json.dump(pages(p[name]), open("%s/%s.json" % (fd, name), "w"))
FX

# ---- stubs --------------------------------------------------------------------
cat > "$top/bin/mailstub" <<'STUB'
#!/usr/bin/env bash
# serves $WORLD/mail; `list --json`, `export <id> --json`
echo "$*" >> "$WORLD/log/mail.log"
case "$1" in
list) [[ -e "$WORLD/mail/fail-list" ]] && { echo "list broke" >&2; exit 1; }
      cat "$WORLD/mail/list.json" ;;
export) [[ -e "$WORLD/mail/fail-export-$2" ]] && { echo "export broke" >&2; exit 1; }
        [[ -e "$WORLD/mail/garbage-export-$2" ]] && { echo "not json"; exit 0; }
        cat "$WORLD/mail/$2.json" ;;
*) exit 64 ;;
esac
STUB
cat > "$top/bin/forgestub" <<'STUB'
#!/usr/bin/env bash
# serves $WORLD/forge/<pr>/<file>; the last argument is the GET path
echo "$*" >> "$WORLD/log/forge.log"
path="${!#}"; path="${path%%\?*}"
case "$path" in
repos/*/pulls/*/reviews)  n="${path%/reviews}";  f=reviews.json ;;
repos/*/pulls/*/comments) n="${path%/comments}"; f=review-comments.json ;;
repos/*/pulls/*/commits)  n="${path%/commits}";  f=commits.json ;;
repos/*/issues/*/comments) n="${path%/comments}"; f=issue-comments.json ;;
repos/*/issues/*/timeline) n="${path%/timeline}"; f=timeline.json ;;
repos/*/pulls/*)          n="$path"; f=pr.json ;;
*) echo "bad path $path" >&2; exit 64 ;;
esac
n="${n##*/}"
[[ -e "$WORLD/forge/$n/fail-$f" ]] && { echo "forge broke" >&2; exit 1; }
[[ -e "$WORLD/forge/$n/garbage-$f" ]] && { echo "not json"; exit 0; }
[[ -e "$WORLD/forge/$n/$f" ]] || { echo "no such $path" >&2; exit 1; }
cat "$WORLD/forge/$n/$f"
STUB
# Wrappers that log every argument on its own line, for the argv tests.
cat > "$top/bin/mailargs" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$WORLD/log/argv.log"; shift
exec "$(dirname "$0")/mailstub" "$@"
STUB
cat > "$top/bin/forgeargs" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$WORLD/log/argv.log"; shift
exec "$(dirname "$0")/forgestub" "$@"
STUB
cat > "$top/bin/fork-sandbox" <<'STUB'
#!/usr/bin/env bash
# `mail ...` is served from the world; `run ...` plays the judge launcher.
# Mode: $WORLD/mode-<pr> or $WORLD/mode (default ok). The pull request is
# read from the attach dir's name (<pr>-<msg>-a<n>/evidence).
echo "$*" >> "$WORLD/log/sandbox.log"
case "$1" in
mail) shift; [[ "${1:-}" == --remote ]] && shift; exec "$(dirname "$0")/mailstub" "$@" ;;
run) ;;
*) exit 64 ;;
esac
attach=""; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[i]}" == --attach-dir ]] && attach="${args[i+1]}"
done
pr="$(basename "$(dirname "$attach")")"; pr="${pr%%-*}"
mode=ok
[[ -f "$WORLD/mode" ]] && mode="$(cat "$WORLD/mode")"
[[ -f "$WORLD/mode-$pr" ]] && mode="$(cat "$WORLD/mode-$pr")"
mkdir -p "$WORLD/runs"
rd="$(mktemp -d "$WORLD/runs/run.XXXXXX")"; mkdir -p "$rd/outbox"
echo "launcher output"
[[ "$mode" == norundir ]] || echo "  run dir:  $rd"
vf="$WORLD/verdicts-$pr.json"
case "$mode" in
ok) cp "$vf" "$rd/outbox/verdicts.json" ;;
exit3-valid) cp "$vf" "$rd/outbox/verdicts.json"; exit 3 ;;
nofile|norundir) ;;
badjson) echo '{"findings": [' > "$rd/outbox/verdicts.json" ;;
nofindings) echo '{"pr": 1}' > "$rd/outbox/verdicts.json" ;;
strfindings) echo '{"findings": "none"}' > "$rd/outbox/verdicts.json" ;;
listtop) echo '[]' > "$rd/outbox/verdicts.json" ;;
term-parent)
    echo $$ > "$WORLD/term.pid"
    kill "-$(cat "$WORLD/term-sig")" "$PPID"
    sleep 300 ;;
barrier)
    mkdir -p "$WORLD/barrier"; touch "$WORLD/barrier/$$"
    for _ in $(seq 1 100); do
        n="$(find "$WORLD/barrier" -type f | wc -l)"
        [[ "$n" -ge 2 || -e "$WORLD/barrier-release" ]] && break
        sleep 0.1
    done
    echo "$n" >> "$WORLD/barrier.counts"
    touch "$WORLD/barrier-release"
    cp "$vf" "$rd/outbox/verdicts.json"
    sleep 0.3
    rm -f "$WORLD/barrier/$$" ;;
esac
exit 0
STUB
cat > "$top/bin/argvlog" <<'STUB'
#!/usr/bin/env bash
# argvlog <name> args...: logs each argument on its own line, the cwd and
# stdin; copies a trailing summary path for `publish`; fails if told to.
name="$1"; shift
{ printf '%s\n' "$@"; echo '--end--'; } >> "$WORLD/log/$name.args"
pwd >> "$WORLD/log/$name.cwd"
{ cat; echo '---'; } >> "$WORLD/log/$name.stdin"
[[ "$name" == publish ]] && cp "${!#}" "$WORLD/published.md"
[[ -f "$WORLD/hook-action" && "$name" == hook ]] && sh "$WORLD/hook-action" "$@"
[[ -e "$WORLD/fail-$name" ]] && { echo "$name broke" >&2; exit 1; }
exit 0
STUB
cat > "$top/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$WORLD/log/gh.log"
[[ "$1" == api ]] && shift
exec "$(dirname "$0")/forgestub" "$@"
STUB
chmod +x "$top"/bin/*

# ---- harness ---------------------------------------------------------------------
n_world=0
new() {  # a fresh world; sets WORLD, HOME, and the config path
    n_world=$(( n_world + 1 ))
    export WORLD="$top/w$n_world"
    mkdir -p "$WORLD/log" "$WORLD/home"
    export HOME="$WORLD/home"
    export LKML_GAP_MONITOR_FILE="$WORLD/config.yaml"
    export LKML_GAP_MONITOR_SCRATCH_DIR="$WORLD/scratch"
    unset XDG_STATE_HOME
    state="$WORLD/state"
}
py() { PYTHONPATH="$top" python3 -c "from fx import *
$1"; }
cfg() {  # cfg [extra yaml]: the standard config, stubs by list-form argv
    cat > "$LKML_GAP_MONITOR_FILE" <<EOF
repo: example-org/widgets
state_dir: $WORLD/state
mail_cmd: [$top/bin/mailstub]
forge_cmd: [$top/bin/forgestub]
${1:-}
EOF
}
gm() { PATH="$top/bin:$PATH" python3 "$gm_script" "$@"; }
scanj() { gm scan --json --now "${1:-$NOW}" 2>/dev/null; }
cls() {  # cls <window key> [now]: the class of one window
    scanj "${2:-}" | jq -r --arg k "$1" '.windows[] | select(.window == $k) | .class'
}
# one case on the standard base world: case_cls <label> <class> <python>
case_cls() {
    new; py "w = World(); w.base()
$3
w.save()"; cfg "${CFG:-}"
    check "$1" "$2" "$(cls 1:so1)"
}

# ======================= config and command line =============================
printf '\n== R1.1 a missing config names its path ==\n'
new; py "w = World(); w.base(); w.save()"
out="$(HOME="$WORLD/home" LKML_GAP_MONITOR_FILE="" gm scan --no-fetch 2>&1)"; rc=$?
check "no override: exit 2" 2 "$rc"
contains "no override: names the default path" "$out" "$WORLD/home/.config/lkml/gap-monitor.yaml"
mkdir -p "$WORLD/home/.config/lkml"
printf 'repo: example-org/widgets\n' > "$WORLD/home/.config/lkml/gap-monitor.yaml"
out="$(LKML_GAP_MONITOR_FILE="$WORLD/nowhere.yaml" gm scan --no-fetch 2>&1)"; rc=$?
check "override missing, valid default present: exit 2" 2 "$rc"
contains "override missing: names the override path" "$out" "$WORLD/nowhere.yaml"

printf '\n== R1.2 an unknown or duplicate key is refused ==\n'
new
cfg "bogus_key: 1"; out="$(gm scan --no-fetch 2>&1)"; rc=$?
check "unknown top-level key: exit 2" 2 "$rc"; contains "unknown top-level key named" "$out" "bogus_key"
cfg "judge:
  nonsense: 1"; out="$(gm scan --no-fetch 2>&1)"; rc=$?
check "unknown judge key: exit 2" 2 "$rc"; contains "unknown judge key named" "$out" "judge.nonsense"
cfg "quiet_hours: 1
quiet_hours: 2"; out="$(gm scan --no-fetch 2>&1)"; rc=$?
check "duplicate key: exit 2" 2 "$rc"; contains "duplicate key named" "$out" "quiet_hours"

printf '\n== R1.3 wrong types and ranges name the key ==\n'
new
bad() {  # bad <label> <key to find in the message> <yaml>
    printf '%s\n' "$3" > "$LKML_GAP_MONITOR_FILE"
    local o rc; o="$(gm scan --no-fetch 2>&1)"; rc=$?
    if [[ $rc -eq 2 && "$o" == *"$2"* ]]; then ok "$1"; else no "$1" "rc=$rc out=$o"; fi
}
bad "repo missing" repo "quiet_hours: 1"
bad "repo without a slash" repo "repo: widgets"
bad "quiet_hours negative" quiet_hours $'repo: example-org/widgets\nquiet_hours: -1'
bad "lookback_days zero" lookback_days $'repo: example-org/widgets\nlookback_days: 0'
bad "judge.concurrency zero" judge.concurrency $'repo: example-org/widgets\njudge:\n  concurrency: 0'
bad "judge.max_attempts a string" judge.max_attempts $'repo: example-org/widgets\njudge:\n  max_attempts: two'
bad "exclude_tier_reason invalid regex" exclude_tier_reason $'repo: example-org/widgets\nexclude_tier_reason: "("'
bad "xref_pattern invalid regex" xref_pattern $'repo: example-org/widgets\nxref_pattern: "("'
bad "bot_markers a scalar" bot_markers $'repo: example-org/widgets\nbot_markers: nope'
bad "mail_cmd an empty list" mail_cmd $'repo: example-org/widgets\nmail_cmd: []'
bad "judge.run_args a string" judge.run_args $'repo: example-org/widgets\njudge:\n  run_args: --no-services'

printf '\n== R1.4 defaults ==\n'
new; py "w = World(); w.base(); w.comment(1, 11, '2026-11-10T07:00:00Z', 'bob', LONG); w.save()"
printf 'repo: example-org/widgets\n' > "$LKML_GAP_MONITOR_FILE"
XDG_STATE_HOME="$WORLD/xdg" gm scan --now "$NOW" >/dev/null 2>&1
if [[ -d "$WORLD/xdg/lkml/gap-monitor/threads" ]]; then ok "XDG_STATE_HOME: cache under it"; else no "XDG_STATE_HOME: cache under it"; fi
gm scan --now "$NOW" >/dev/null 2>&1
if [[ -d "$HOME/.local/state/lkml/gap-monitor/threads" ]]; then ok "unset: cache under ~/.local/state"; else no "unset: cache under ~/.local/state"; fi
contains "mail default: fork-sandbox mail --remote list --json" "$(cat "$WORLD/log/sandbox.log")" "mail --remote list --json"
contains "forge default: gh api" "$(head -1 "$WORLD/log/gh.log")" "gh api"
check "trigger 5 h old is waiting (default 6 h)" waiting "$(gm scan --json --now "$NOW" 2>/dev/null | jq -r '.windows[0].class')"
check "same trigger 7 h old is due" due "$(gm scan --json --now 2026-11-10T14:00:00Z 2>/dev/null | jq -r '.windows[0].class')"
new; py "w = World(); w.base(so='old13', at='2026-10-28T12:00:00Z'); w.thread('t2', 2); w.signoff('t2', 'old15', '2026-10-26T12:00:00Z'); w.pr(2); w.save()"
printf 'repo: example-org/widgets\n' > "$LKML_GAP_MONITOR_FILE"
check "lookback default 14 days: 13 listed, 15 not" "1:old13" "$(gm scan --json --now "$NOW" 2>/dev/null | jq -r '[.windows[].window] | join(",")')"

printf '\n== R1.5 commands: argv, never a shell ==\n'
for form in list string; do
    for key in mail_cmd forge_cmd; do
        new; py "w = World(); w.base(); w.save()"
        tool=mailargs; [[ $key == forge_cmd ]] && tool=forgeargs
        arg="x y; \$(touch $WORLD/marker)"
        if [[ $form == list ]]; then
            val="[$top/bin/$tool, \"$arg\"]"
        else
            val="\"$top/bin/$tool 'x y; \$(touch $WORLD/marker)'\""
        fi
        cat > "$LKML_GAP_MONITOR_FILE" <<EOF
repo: example-org/widgets
state_dir: $WORLD/state
mail_cmd: [$top/bin/mailstub]
forge_cmd: [$top/bin/forgestub]
EOF
        sed -i "/^$key:/d" "$LKML_GAP_MONITOR_FILE"; printf '%s: %s\n' "$key" "$val" >> "$LKML_GAP_MONITOR_FILE"
        gm scan --now "$NOW" >/dev/null 2>&1
        check "$key as $form: argument passed literally" "$arg" "$(head -1 "$WORLD/log/argv.log" 2>/dev/null)"
        if [[ ! -e "$WORLD/marker" ]]; then ok "$key as $form: no shell ran"; else no "$key as $form: no shell ran"; fi
    done
done

printf '\n== R1.6 --help and usage errors ==\n'
doc="$(python3 -c "import ast,sys; sys.stdout.write(ast.get_docstring(ast.parse(open(sys.argv[1]).read()), clean=False))" "$gm_script")"
new
for a in "--help" "-h" "scan --help"; do
    # shellcheck disable=SC2086  # $a is a deliberate word list
    out="$(gm $a)"; rc=$?
    check "'$a' exits 0" 0 "$rc"
    check "'$a' prints the header docstring" "$doc" "$out"
done
ue() {  # ue <label> args...: exit 2
    local l="$1"; shift
    gm "$@" >/dev/null 2>&1; check "usage error: $l" 2 "$?"
}
cfg
ue "no subcommand"; ue "unknown subcommand" frobnicate; ue "unknown option" scan --frob
ue "--max-judges on scan" scan --max-judges 1; ue "--now without a value" scan --now
ue "--now not ISO" scan --now yesterday; ue "stray positional" scan extra

printf '\n== R3.1 selective export ==\n'
new; py "w = World(); w.base(); w.thread('t9', None); w.msg('t9', 'm9', SO, '@x', 'hi'); w.thread('t2', 2); w.signoff('t2', 'so2', SO); w.pr(2); w.save()"; cfg
gm scan --now "$NOW" >/dev/null 2>&1
check "first scan: list once, exports the PR threads only" $'export t1 --json\nexport t2 --json\nlist --json' "$(sort "$WORLD/log/mail.log")"
: > "$WORLD/log/mail.log"; gm scan --now "$NOW" >/dev/null 2>&1
check "second scan, nothing changed: no export" "list --json" "$(cat "$WORLD/log/mail.log")"
py "w = World(); w.base(); w.thread('t9', None); w.msg('t9', 'm9', SO, '@x', 'hi'); w.thread('t2', 2); w.signoff('t2', 'so2', SO); w.msg('t2', 'extra', OLD, '@core', 'more'); w.pr(2); w.save()"
: > "$WORLD/log/mail.log"; gm scan --now "$NOW" >/dev/null 2>&1
check "message count grew: only that thread exported" $'export t2 --json\nlist --json' "$(sort "$WORLD/log/mail.log")"
jq '.[] |= (if .thread == "t1" then .last_date = "Tue, 10 Nov 2026 01:00:00 +0000" else . end)' "$WORLD/mail/list.json" > "$WORLD/mail/l2" && mv "$WORLD/mail/l2" "$WORLD/mail/list.json"
: > "$WORLD/log/mail.log"; gm scan --now "$NOW" >/dev/null 2>&1
check "last_date changed, count equal: only that thread exported" $'export t1 --json\nlist --json' "$(sort "$WORLD/log/mail.log")"

printf '\n== R3.2 forge GETs for lookback pull requests only ==\n'
new; py "
w = World(); w.base(); w.base(pr=2, so='so2', tid='t2')
w.thread('t3', 3); w.signoff('t3', 'so3', '2026-09-01T09:00:00Z'); w.pr(3)
w.thread('t4', 4); w.pr(4)
w.save()"; cfg
gm scan --now "$NOW" >/dev/null 2>&1
exp=""
for p in 1 2; do exp+="repos/example-org/widgets/pulls/$p"$'\n'
    exp+="--paginate --slurp repos/example-org/widgets/pulls/$p/reviews?per_page=100"$'\n'
    exp+="--paginate --slurp repos/example-org/widgets/pulls/$p/comments?per_page=100"$'\n'
    exp+="--paginate --slurp repos/example-org/widgets/issues/$p/comments?per_page=100"$'\n'
    exp+="--paginate --slurp repos/example-org/widgets/pulls/$p/commits?per_page=100"$'\n'
    exp+="--paginate --slurp repos/example-org/widgets/issues/$p/timeline?per_page=100"$'\n'
done
check "exactly the twelve GETs for the two lookback PRs" "$(printf '%s' "$exp" | sort)" "$(sort "$WORLD/log/forge.log")"
if grep -qE -- '(^| )(-X|--method|-f|-F|--field|--raw-field|--input)( |$)' "$WORLD/log/forge.log"; then
    no "no write flag in any forge call"; else ok "no write flag in any forge call"; fi

printf '\n== R3.3 a failed fetch keeps the old copy ==\n'
new; py "
w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.base(pr=2, so='so2', tid='t2'); w.comment(2, 21, OLD, 'bob', LONG); w.save()"; cfg
gm scan --now "$NOW" >/dev/null 2>&1
sum_t() { cat "$state"/threads/*.json | md5sum; }
sum_f() { cat "$state"/forge/*/*.json | md5sum; }
touch "$WORLD/mail/fail-list"
out="$(gm scan --now "$NOW" 2>&1)"; rc=$?
check "list fails, warm cache: exit 1" 1 "$rc"
contains "list fails: windows still printed from the cache" "$out" "1:so1"
check "list fails: the failure is the last line" "Error" "$(printf '%s\n' "$out" | tail -1 | cut -c1-5)"
rm "$WORLD/mail/fail-list"
# change the world so a refresh would be visible, then fail one export
py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.msg('t1', 'extra', OLD, '@core', 'more'); w.base(pr=2, so='so2', tid='t2'); w.msg('t2', 'extra2', OLD, '@core', 'more'); w.comment(2, 21, OLD, 'bob', LONG); w.save()"
b1="$(md5sum < "$state/threads/t1.json")"
touch "$WORLD/mail/fail-export-t1"
gm scan --now "$NOW" >/dev/null 2>&1; rc=$?
check "export fails: exit 1" 1 "$rc"
check "export fails: its old file is unchanged" "$b1" "$(md5sum < "$state/threads/t1.json")"
contains "export fails: the other thread was refreshed" "$(cat "$state/threads/t2.json")" "extra2"
rm "$WORLD/mail/fail-export-t1"
bf="$(md5sum < "$state/forge/1/issue-comments.json")"
py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.comment(1, 12, OLD, 'bob', LONG + ' again'); w.base(pr=2, so='so2', tid='t2'); w.comment(2, 21, OLD, 'bob', LONG); w.comment(2, 22, OLD, 'bob', LONG + ' again'); w.save()"
touch "$WORLD/forge/1/fail-issue-comments.json"
out="$(gm scan --json --now "$NOW" 2>/dev/null)"; rc=$?
check "forge file fails: exit 1" 1 "$rc"
check "forge file fails: old file unchanged" "$bf" "$(md5sum < "$state/forge/1/issue-comments.json")"
check "forge file fails: the other PR is refreshed and classified" due "$(jq -r '.windows[] | select(.pr == 2) | .class' <<<"$out")"
rm "$WORLD/forge/1/fail-issue-comments.json"; touch "$WORLD/forge/1/garbage-issue-comments.json"
gm scan --now "$NOW" >/dev/null 2>&1; rc=$?
check "forge file non-JSON: exit 1" 1 "$rc"
check "forge file non-JSON: old file unchanged" "$bf" "$(md5sum < "$state/forge/1/issue-comments.json")"
new; py "w = World(); w.base(); w.base(pr=2, so='so2', tid='t2'); w.save()"; cfg
touch "$WORLD/forge/2/fail-pr.json"
out="$(gm scan --now "$NOW" 2>"$WORLD/err")"; rc=$?
check "never-fetched PR: exit 1" 1 "$rc"
lacks "never-fetched PR: no class line" "$out" "2:so2"
contains "never-fetched PR: named on stderr" "$(cat "$WORLD/err")" "2:so2"
check "never-fetched PR: under skipped in --json" "2:so2" "$(gm scan --json --now "$NOW" 2>/dev/null | jq -r '.skipped[0].window')"

printf '\n== R3.4 leftover temp files ==\n'
new; py "w = World(); w.base(); w.save()"; cfg
gm scan --now "$NOW" >/dev/null 2>&1
ref="$(gm scan --now "$NOW" 2>&1)"
echo garbage > "$state/threads/.t1.json.tmp.1"; echo garbage > "$state/threads/.old.tmp"; echo garbage > "$state/forge/1/.pr.json.tmp.1"; echo garbage > "$state/forge/1/.old.tmp"
touch -d '2 days ago' "$state/threads/.old.tmp" "$state/forge/1/.old.tmp"
check "scan output with temp files equals output without" "$ref" "$(gm scan --now "$NOW" 2>&1)"
if [[ ! -e "$state/threads/.old.tmp" && ! -e "$state/forge/1/.old.tmp" ]]; then ok "old temp files removed"; else no "old temp files removed"; fi
if [[ -e "$state/threads/.t1.json.tmp.1" && -e "$state/forge/1/.pr.json.tmp.1" ]]; then ok "fresh temp files left"; else no "fresh temp files left"; fi

printf '\n== R3.5 --no-fetch ==\n'
new; py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.save()"; cfg
fetched="$(gm scan --now "$NOW" 2>&1)"
: > "$WORLD/log/mail.log"; : > "$WORLD/log/forge.log"
nf="$(gm scan --no-fetch --now "$NOW" 2>&1)"
check "--no-fetch: same output as the fetched scan" "$fetched" "$nf"
check "--no-fetch: mail_cmd not run" "" "$(cat "$WORLD/log/mail.log")"
check "--no-fetch: forge_cmd not run" "" "$(cat "$WORLD/log/forge.log")"
new; cfg
out="$(gm scan --no-fetch --now "$NOW" 2>&1)"; rc=$?
check "--no-fetch with no cache: exit 1" 1 "$rc"
contains "--no-fetch with no cache: names the directory" "$out" "$WORLD/state/threads"

# ======================= sign-offs and windows ===============================
wins() { scanj "${1:-}" | jq -r '[.windows[].window] | join(",")'; }
so_case() {  # so_case <label> <expected windows> <python for the thread>
    new; py "w = World(); w.thread('t1', 1)
$3
w.pr(1); w.save()"; cfg
    check "$1" "$2" "$(wins)"
}

printf '\n== R4.1 sign-off detection ==\n'
so_case "CONVERGED + SIGNED-OFF counts" "1:s1" "w.signoff('t1', 's1', SO)"
check "  verdict recorded" SIGNED-OFF "$(scanj | jq -r '.windows[0].signoff_verdict')"
so_case "CONVERGED + RESPIN counts" "1:s1" "w.signoff('t1', 's1', SO, verdict='RESPIN')"
check "  RESPIN recorded" RESPIN "$(scanj | jq -r '.windows[0].signoff_verdict')"
so_case "CONVERGED + another verdict does not" "" "w.signoff('t1', 's1', SO, verdict='NEEDS-WORK')"
so_case "a non-converged status does not" "" "w.signoff('t1', 's1', SO, status='IN-PROGRESS', verdict=None)"
so_case "a non-converged status with SIGNED-OFF does not" "" "w.signoff('t1', 's1', SO, status='IN-PROGRESS')"
so_case "CONVERGED with no verdict line does not" "" "w.signoff('t1', 's1', SO, verdict=None)"

printf '\n== R4.2 the trailer is the last lines of the body ==\n'
so_case "a full trailer followed by prose: no window" "" "w.signoff('t1', 's1', SO, after='\nOne more thing: see above.\n')"
contains "  a warning names thread and message" "$(gm scan --no-fetch --now "$NOW" 2>&1 >/dev/null)" "t1 message s1"
so_case "a quoted trailer in a later non-converged message: no second window" "" "w.signoff('t1', 's1', SO, status='IN-PROGRESS', verdict=None); w.msg('t1', 's2', OLD, '@secretary', '> Panel-Status: CONVERGED\n> Panel-Verdict: SIGNED-OFF\n\nPanel-Version: 1\nPanel-Status: IN-PROGRESS\n')"
lacks "  no warning for the quoted one" "$(gm scan --no-fetch --now "$NOW" 2>&1 >/dev/null)" "CONVERGED"
so_case "trailing blank lines after the trailer: still a sign-off" "1:s1" "w.signoff('t1', 's1', SO, tail_blank=3)"

printf '\n== R4.3 the sender must be the secretary ==\n'
so_case "trailer from @core: none" "" "w.signoff('t1', 's1', SO, frm='@core')"
so_case "roster names another secretary, message from them: window" "1:s1" "w.threads.clear(); w.thread('t1', 1, secretary='@sec-b'); w.signoff('t1', 's1', SO, frm='@sec-b')"
so_case "roster names another secretary, message from @secretary: none" "" "w.threads.clear(); w.thread('t1', 1, secretary='@sec-b'); w.signoff('t1', 's1', SO)"
so_case "root with no Secretary line, from @secretary: window" "1:s1" "w.threads.clear(); w.thread('t1', 1, body='Author: @pr-author\nPanel: @core\n'); w.signoff('t1', 's1', SO)"

printf '\n== R4.4 child threads do not sign off ==\n'
new; py "w = World(); w.thread('c1', 1, parent='t1'); w.signoff('c1', 'sc', SO); w.thread('t1', 1); w.pr(1); w.save()"; cfg
check "child sign-off beside an unsigned main thread: none" "" "$(wins)"
new; py "w = World(); w.thread('c1', 1, parent='t1'); w.signoff('c1', 'sc', SO); w.thread('t1', 1); w.signoff('t1', 's1', SO); w.pr(1); w.save()"; cfg
check "child beside a signed-off main thread: only the main window" "1:s1" "$(wins)"

printf '\n== R4.5 the reviewed sha ==\n'
sha_case() {
    new; py "w = World(); w.thread('t1', 1)
$2
w.pr(1); w.save()"; cfg
    check "$1" "$3" "$(scanj | jq -r '.windows[0].reviewed_sha')"
}
sha_case "branch-name <sha>: the last token" "w.signoff('t1', 's1', SO, sha=B)" "$(printf 'b%.0s' $(seq 40))"
sha_case "a bare sha" "w.signoff('t1', 's1', SO, sha=B, target='bare')" "$(printf 'b%.0s' $(seq 40))"
sha_case "no header: null" "w.signoff('t1', 's1', SO, target=None)" null
sha_case "last token not 40 hex: null" "w.signoff('t1', 's1', SO, sha='nothex')" null
sha_case "the sign-off message's header wins over the root's" "w.threads['t1']['msgs'][0]['headers'].append(['X-Review-Target', 'br ' + C]); w.signoff('t1', 's1', SO, sha=B)" "$(printf 'b%.0s' $(seq 40))"

printf '\n== R4.6 two sign-offs split the feedback ==\n'
twice() {  # twice <label> <python creating the two sign-offs>
    new; py "w = World()
$2
w.pr(1)
w.comment(1, 10, '2026-11-05T10:00:00Z', 'bob', LONG + ' before')
w.comment(1, 11, '2026-11-08T12:00:00Z', 'bob', LONG + ' between')
w.comment(1, 12, '2026-11-09T09:00:00Z', 'bob', LONG + ' after')
w.save()"; cfg
    local o; o="$(scanj)"
    check "$1: first window's trigger is the one between" "comment:11" "$(jq -r '.windows[] | select(.window == "1:sa") | [.triggers[].kind + ":" + (.triggers[].id|tostring)] | join(",")' <<<"$o")"
    check "$1: second window's trigger is the one after" "comment:12" "$(jq -r '.windows[] | select(.window == "1:sb") | [.triggers[].kind + ":" + (.triggers[].id|tostring)] | join(",")' <<<"$o")"
    check "$1: the earlier comment is in neither (item counts 1 and 1)" "1,1" "$(jq -r '[.windows[].counts.items|tostring]|join(",")' <<<"$o")"
}
twice "one thread" "w.thread('t1', 1, started='2026-11-04T09:00:00Z'); w.signoff('t1', 'sa', '2026-11-08T09:00:00Z'); w.signoff('t1', 'sb', '2026-11-08T18:00:00Z', version=2)"
twice "two threads" "w.thread('t1', 1, started='2026-11-04T09:00:00Z'); w.signoff('t1', 'sa', '2026-11-08T09:00:00Z'); w.thread('t2', 1, started='2026-11-08T10:00:00Z'); w.signoff('t2', 'sb', '2026-11-08T18:00:00Z')"

printf '\n== R4.6 window edges: after the sign-off up to and including the next ==\n'
new; py "w = World(); w.thread('t1', 1); w.signoff('t1', 'sa', '2026-11-08T09:00:00Z'); w.signoff('t1', 'sb', '2026-11-08T18:00:00Z', version=2); w.pr(1)
w.comment(1, 10, '2026-11-08T09:00:00Z', 'bob', LONG + ' at the first sign-off'); w.comment(1, 11, '2026-11-08T18:00:00Z', 'bob', LONG + ' at the second'); w.save()"; cfg
check "an item at the sign-off instant is not in its window; one at the next sign-off is" "1,0" "$(scanj | jq -r '[.windows[].counts.items|tostring]|join(",")')"
check "  the item at the next sign-off belongs to the first window" "comment:11" "$(scanj | jq -r '.windows[0].triggers[0]|.kind+":"+(.id|tostring)')"

printf '\n== R4.7 timestamps compare as instants ==\n'
new; py "w = World(); w.thread('t1', 1); w.signoff('t1', 's1', 'Mon, 09 Nov 2026 23:30:00 -0800'); w.pr(1)
w.comment(1, 10, '2026-11-10T07:00:00Z', 'bob', LONG + ' early'); w.comment(1, 11, '2026-11-10T08:00:00Z', 'bob', LONG + ' late'); w.save()"; cfg
check "-0800 sign-off: the 07:00Z comment is before it, the 08:00Z after" "comment:11" "$(scanj 2026-11-10T20:00:00Z | jq -r '.windows[0].triggers | map(.kind + ":" + (.id|tostring)) | join(",")')"
new; py "w = World(); w.thread('t1', 1); w.signoff('t1', 'sa', 'Tue, 10 Nov 2026 01:00:00 +0900'); w.signoff('t1', 'sb', 'Mon, 09 Nov 2026 20:00:00 -0500', version=2); w.pr(1)
w.comment(1, 10, '2026-11-09T20:00:00Z', 'bob', LONG + ' one'); w.comment(1, 11, '2026-11-10T02:00:00Z', 'bob', LONG + ' two'); w.save()"; cfg
o="$(scanj 2026-11-10T20:00:00Z)"
check "string order and time order differ: windows follow the instants" "1:sa,1:sb" "$(jq -r '[.windows[].window]|join(",")' <<<"$o")"
check "  first window holds the 20:00Z comment" "comment:10" "$(jq -r '.windows[0].triggers[0] | .kind + ":" + (.id|tostring)' <<<"$o")"
check "  second window holds the 02:00Z comment" "comment:11" "$(jq -r '.windows[1].triggers[0] | .kind + ":" + (.id|tostring)' <<<"$o")"

printf '\n== R4.8 the lookback bounds the report, not the windows ==\n'
new; py "w = World(); w.thread('t1', 1); w.signoff('t1', 'old', '2026-10-21T09:00:00Z'); w.signoff('t1', 'new', '2026-11-07T09:00:00Z', version=2); w.pr(1)
w.comment(1, 10, '2026-10-31T09:00:00Z', 'bob', LONG); w.save()"; cfg
o="$(scanj)"
check "20-day sign-off not listed, 3-day listed" "1:new" "$(jq -r '[.windows[].window]|join(",")' <<<"$o")"
check "the 10-day-old comment is not among the 3-day window's items" 0 "$(jq -r '.windows[0].counts.items' <<<"$o")"

printf '\n== R4.9 exclude_tier_reason ==\n'
new; py "w = World()
w.thread('t1', 1, reason='production deploy'); w.signoff('t1', 's1', SO); w.pr(1)
w.thread('t2', 1, reason='small change'); w.signoff('t2', 's2', SO); 
w.thread('t3', 2, reason='small change'); w.signoff('t3', 's3', SO); w.pr(2)
w.save()"; cfg 'exclude_tier_reason: production'
o="$(scanj)"; : > "$WORLD/log/forge.log"; rm -rf "$state/forge"; gm scan --now "$NOW" >/dev/null 2>&1
check "excluded PR, its second thread too: only the other PR's window" "2:s3" "$(jq -r '[.windows[].window]|join(",")' <<<"$o")"
check "excluded PR listed under excluded" 1 "$(jq -r '.excluded[0].pr' <<<"$o")"
lacks "no forge call for the excluded PR" "$(cat "$WORLD/log/forge.log")" "pulls/1"
cfg; check "key unset: all three windows" "1:s1,1:s2,2:s3" "$(wins)"

# ======================= items, triggers, classes ============================
printf '\n== R5.1 automation ==\n'
CFG='bot_markers: ["<!-- site-bot"]'
case_cls "user type Bot" empty "w.comment(1, 11, OLD, 'bob', LONG, utype='Bot')"
case_cls "login ending [bot]" empty "w.comment(1, 11, OLD, 'ci-example[bot]', LONG)"
case_cls "lkml-state mid-body, human account" empty "w.comment(1, 11, OLD, 'bob', LONG + '\n<!-- lkml-state v1 -->\nmore')"
case_cls "lkml-panel mid-body, human account" empty "w.comment(1, 11, OLD, 'bob', LONG + '\n<!-- lkml-panel x -->\nmore')"
case_cls "lkml-notice mid-body, human account" empty "w.comment(1, 11, OLD, 'bob', LONG + '\n<!-- lkml-notice x -->\nmore')"
case_cls "body starting 'Mailing list review of '" empty "w.comment(1, 11, OLD, 'bob', 'Mailing list review of this change: ' + LONG)"
case_cls "configured bot_markers mid-body" empty "w.comment(1, 11, OLD, 'bob', LONG + '\n<!-- site-bot 3 -->\nmore')"
case_cls "'Mailing list review of ' mid-body is not automation" due "w.comment(1, 11, OLD, 'bob', LONG + '\nMailing list review of this change.')"
CFG=
case_cls "an integration note from a human is not automation" empty "w.comment(1, 11, OLD, 'bob', '<!-- lkml-integration: s v1 -->\n- 1234567 widget: x -- take -- ok\n' + LONG)"
check "  counted as a note, not as automation" "1,0" "$(scanj | jq -r '[.windows[0].counts.integration_notes, .windows[0].counts.automation]|map(tostring)|join(",")')"
case_cls "an integration note holding a lkml-state marker is still a note" empty "w.comment(1, 11, OLD, 'bob', '<!-- lkml-integration: s v1 -->\n<!-- lkml-state -->\n' + LONG)"
check "  automation count 0" 0 "$(scanj | jq -r '.windows[0].counts.automation')"

printf '\n== R5.2 timeline events are context only ==\n'
for ev in head_ref_force_pushed merged closed reopened; do
    case_cls "$ev alone: empty" empty "w.event(1, '$ev', OLD)"
    case_cls "$ev 1 h old beside a 7 h old comment: due" due "w.comment(1, 11, '2026-11-10T05:00:00Z', 'bob', LONG); w.event(1, '$ev', '2026-11-10T11:00:00Z')"
done

printf '\n== R5.3 comment triggers ==\n'
case_cls "only author comments: author-only" author-only "w.comment(1, 11, OLD, 'alice', LONG); w.inline(1, 12, OLD, 'alice', LONG)"
new; py "w = World(); w.base()
for i in range(5): w.comment(1, 20 + i, OLD, 'alice', LONG + ' %d' % i)
w.comment(1, 30, OLD, 'bob', LONG + ' outside'); w.save()"; cfg
o="$(scanj)"
check "one outside comment among five author comments: due" due "$(jq -r '.windows[0].class' <<<"$o")"
check "  why names exactly that comment" 1 "$(jq -r '.windows[0].triggers|length' <<<"$o")"
check "  the trigger is comment:30" "comment:30" "$(jq -r '.windows[0].triggers[0]|.kind+":"+(.id|tostring)' <<<"$o")"
for t in 'LGTM' 'Looks good to me!' 'thanks.' ':tada:' '/retest now' '+1'; do
    case_cls "trivial outside comment '$t': empty" empty "w.comment(1, 11, OLD, 'bob', '$t')"
done
case_cls "all six trivial comments together: empty" empty "
for i, t in enumerate(['LGTM', 'Looks good to me!', 'thanks.', ':tada:', '/retest now', '+1']): w.comment(1, 11 + i, OLD, 'bob', t)"
c39="$(printf 'x%.0s' $(seq 39))"; c40="${c39}x"
case_cls "issue comment of 39 characters: not a trigger" empty "w.comment(1, 11, OLD, 'bob', '$c39')"
case_cls "issue comment of 40 characters: trigger" due "w.comment(1, 11, OLD, 'bob', '$c40')"
case_cls "review body of 39: not a trigger" empty "w.review(1, 11, OLD, 'bob', '$c39')"
case_cls "review body of 40: trigger" due "w.review(1, 11, OLD, 'bob', '$c40')"
case_cls "inline comment of 12 characters: trigger" due "w.inline(1, 11, OLD, 'bob', 'off by one?!')"
case_cls "inline comment that opens with a path: trigger" due "w.inline(1, 11, OLD, 'bob', '/etc/hosts is read here, not the config')"
case_cls "APPROVED review with empty body: no item" empty "w.review(1, 11, OLD, 'bob', '', state='APPROVED')"
check "  no item at all" 0 "$(scanj | jq -r '.windows[0].counts.items')"
case_cls "CHANGES_REQUESTED with empty body: an item, not a trigger" empty "w.review(1, 11, OLD, 'bob', '', state='CHANGES_REQUESTED')"
check "  one item" 1 "$(scanj | jq -r '.windows[0].counts.items')"
case_cls "kind: review body alone" due "w.review(1, 11, OLD, 'bob', LONG)"
case_cls "kind: inline comment alone" due "w.inline(1, 11, OLD, 'bob', LONG)"
case_cls "kind: issue comment alone" due "w.comment(1, 11, OLD, 'bob', LONG)"
case_cls "kind: outsider's inline reply to the author's inline comment" due "w.inline(1, 11, '2026-11-08T10:00:00Z', 'alice', LONG); w.inline(1, 12, OLD, 'bob', LONG, reply_to=11)"
case_cls "a long integration note from bob alone: not a trigger" empty "w.comment(1, 11, OLD, 'bob', '<!-- lkml-integration: s v1 -->\n- 1234567 widget: x -- take -- ok\n' + LONG)"

printf '\n== R5.4 cross-reference triggers ==\n'
case_cls "xref: label 'type: bug'" due "w.xref(1, 50, OLD, labels=['type: bug'])"
check "  reason label" label "$(scanj | jq -r '.windows[0].triggers[0].reason')"
case_cls "xref: label 'Bug'" due "w.xref(1, 50, OLD, labels=['Bug'])"
case_cls "xref: title matches" due "w.xref(1, 50, OLD, title='Fix stale flush after retry')"
check "  reason title" title "$(scanj | jq -r '.windows[0].triggers[0].reason')"
case_cls "xref: citing paragraph matches" due "w.xref(1, 50, OLD, body='Intro.\n\nFollow-up to #1: the retry was wrong\n\nOutro.')"
check "  reason paragraph" paragraph "$(scanj | jq -r '.windows[0].triggers[0].reason')"
case_cls "xref: match only in an unrelated paragraph" xref-only "w.xref(1, 50, OLD, body='See #1 for context.\n\nThis fixes the build.')"
case_cls "xref: #10 is not #1" xref-only "w.xref(1, 50, OLD, body='Follow-up to #10: a fix')"
case_cls "xref: source created before the sign-off" xref-only "w.xref(1, 50, OLD, labels=['bug'], created='2026-11-01T09:00:00Z')"
case_cls "xref: the source is this pull request" empty "w.xref(1, 1, OLD, labels=['bug'])"
case_cls "xref: a matching source by the PR author" due "w.xref(1, 50, OLD, labels=['bug'], user='alice')"
case_cls "xref: two events from one source: one item" due "w.xref(1, 50, OLD, labels=['bug']); w.xref(1, 50, '2026-11-09T10:00:00Z', labels=['bug'])"
check "  one item" 1 "$(scanj | jq -r '.windows[0].counts.xrefs')"
CFG='xref_pattern: \bflaky\b'
case_cls "xref_pattern override: the default title no longer matches" xref-only "w.xref(1, 50, OLD, title='Fix stale flush after retry')"
case_cls "xref_pattern override: the new word matches" due "w.xref(1, 50, OLD, title='Flaky retry')"
CFG=
case_cls "xref: 'prefix cleanup' is not 'fix' (word boundary)" xref-only "w.xref(1, 50, OLD, title='prefix cleanup')"

printf '\n== R5.5 the quiet period ==\n'
new; py "w = World(); w.base(); w.comment(1, 11, '2026-11-10T11:00:00Z', 'bob', LONG); w.save()"; cfg
o="$(scanj)"
check "trigger 1 h old: waiting" waiting "$(jq -r '.windows[0].class' <<<"$o")"
check "  due_at is the trigger plus 6 h" 2026-11-10T17:00:00Z "$(jq -r '.windows[0].due_at' <<<"$o")"
check "7 h later: due" due "$(cls 1:so1 2026-11-10T18:00:00Z)"
check "exactly 6 h after: waiting" waiting "$(cls 1:so1 2026-11-10T17:00:00Z)"
check "one second later: due" due "$(cls 1:so1 2026-11-10T17:00:01Z)"
new; py "w = World(); w.base(); w.comment(1, 11, '2026-11-10T05:00:00Z', 'bob', LONG); w.comment(1, 12, '2026-11-10T11:00:00Z', 'alice', LONG + ' mine'); w.save()"; cfg
check "7 h old trigger + a 1 h old author comment: waiting" waiting "$(cls 1:so1)"
new; py "w = World(); w.base(); w.comment(1, 11, '2026-11-10T05:00:00Z', 'bob', LONG); w.comment(1, 12, '2026-11-10T11:00:00Z', 'ci[bot]', LONG + ' bot'); w.save()"; cfg
check "7 h old trigger + a 1 h old bot comment: due" due "$(cls 1:so1)"
new; py "w = World(); w.base(); w.comment(1, 11, '2026-11-10T11:20:00Z', 'bob', LONG); w.save()"; cfg 'quiet_hours: 0.5'
check "quiet_hours 0.5, trigger 40 min old: due" due "$(cls 1:so1)"

# ---- the ledger, hand-written ----
wrec() {  # wrec <status> <items json> [attempt]: a window record for 1:so1
    printf '{"schema":1,"kind":"window","window":"1:so1","pr":1,"status":"%s","attempt":%s,"items":%s,"run_dir":"/x","at":"2026-11-09T10:00:00Z","head_matches":true,"notes":""}\n' "$1" "${3:-1}" "$2"
}
ledger() { mkdir -p "$state"; cat > "$state/ledger.jsonl"; }
printf '\n== R5.6 classes from the ledger ==\n'
new; py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.save()"; cfg
wrec judged '["comment:11"]' | ledger
check "judged listing the trigger: judged" judged "$(cls 1:so1)"
py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.comment(1, 12, '2026-11-09T10:00:00Z', 'bob', LONG + ' new'); w.save()"
o="$(scanj)"
check "plus a new outside comment: due" due "$(jq -r '.windows[0].class' <<<"$o")"
check "  why names only the new one" "comment:12" "$(jq -r '.windows[0].triggers|map(.kind+":"+(.id|tostring))|join(",")' <<<"$o")"
py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.comment(1, 12, '2026-11-09T10:00:00Z', 'alice', LONG + ' mine'); w.save()"
check "plus a new author comment: judged" judged "$(cls 1:so1)"
py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.save()"
: | ledger; check "ledger line deleted: due" due "$(cls 1:so1)"
wrec sha-unavailable '[]' 0 | ledger; check "sha-unavailable: blocked" blocked "$(cls 1:so1)"
wrec judge-failed '["comment:11"]' 1 | ledger
o="$(scanj)"; check "one judge-failed, max_attempts 2: due" due "$(jq -r '.windows[0].class' <<<"$o")"
check "  attempts 1" 1 "$(jq -r '.windows[0].attempts' <<<"$o")"
{ wrec judge-failed '[]' 1; wrec judge-failed '[]' 2; } | ledger; check "two judge-failed: failed" failed "$(cls 1:so1)"
py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.comment(1, 12, '2026-11-09T10:00:00Z', 'bob', LONG + ' new'); w.save()"
{ wrec judge-failed '[]' 1; wrec judge-failed '[]' 2; wrec judged '["comment:11"]' 3; wrec judge-failed '[]' 1; } | ledger
check "failures, then judged, then a new trigger and one failure: due" due "$(cls 1:so1)"
{ wrec judge-failed '[]' 1; wrec judge-failed '[]' 2; } | ledger
check "failed plus a new trigger: still failed" failed "$(cls 1:so1)"
py "w = World(); w.base(); w.comment(1, 11, '2026-11-10T11:00:00Z', 'bob', LONG); w.save()"
wrec sha-unavailable '[]' 0 | ledger; check "blocked with the trigger in the quiet period: waiting" waiting "$(cls 1:so1)"

printf '\n== R5.7 damaged ledger lines ==\n'
new; py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.save()"; cfg
{ wrec judged '["comment:11"]'; printf '{"schema":1,"kind":"win'; } | ledger
out="$(gm scan --now "$NOW" 2>"$WORLD/err")"; rc=$?
contains "truncated last line: class judged" "$out" "judged"; check "  exit 0" 0 "$rc"
contains "  warning names line 2" "$(cat "$WORLD/err")" "line 2"
{ wrec judged '["comment:11"]'; echo 'garbage'; wrec judge-failed '[]' 1; } | ledger
out="$(gm scan --now "$NOW" 2>"$WORLD/err")"
contains "garbage line in the middle: still judged" "$out" "judged"; contains "  warning names line 2" "$(cat "$WORLD/err")" "line 2"
{ wrec judged '["comment:11"]' | sed 's/"schema":1/"schema":2/'; } | ledger
out="$(gm scan --now "$NOW" 2>"$WORLD/err")"
contains "schema 2 line skipped: window due again" "$out" "due"; contains "  with a warning" "$(cat "$WORLD/err")" "line 1"
rm -f "$state/ledger.jsonl"; gm scan --now "$NOW" >/dev/null 2>"$WORLD/err"
check "no ledger: no warning" "" "$(cat "$WORLD/err")"

printf '\n== R5.8 scan output and what it leaves alone ==\n'
new; py "w = World(); w.base()
w.comment(1, 11, OLD, 'bob', LONG)
w.base(pr=2, so='so2', tid='t2'); w.comment(2, 21, '2026-11-10T11:00:00Z', 'bob', LONG)
w.base(pr=3, so='so3', tid='t3'); w.comment(3, 31, OLD, 'alice', LONG)
w.base(pr=4, so='so4', tid='t4'); w.xref(4, 50, OLD, title='Neutral cleanup')
w.base(pr=5, so='so5', tid='t5')
w.save()"; cfg
out="$(gm scan --now "$NOW" 2>&1)"
check "five tab-separated lines" 5 "$(printf '%s\n' "$out" | awk -F'\t' 'NF == 3 && $3 != ""' | wc -l)"
check "classes in sign-off order, then key" "due,waiting,author-only,xref-only,empty" "$(printf '%s\n' "$out" | cut -f2 | paste -sd,)"
j="$(scanj)"
check "--json: same classes" "due,waiting,author-only,xref-only,empty" "$(jq -r '[.windows[].class]|join(",")' <<<"$j")"
check "--json: every window carries every documented field" 5 "$(jq '[.windows[] | select(. as $o | ["window","pr","thread","signoff_msg","signoff_at","signoff_verdict","version","tier","reviewed_sha","until","class","why","triggers","counts","newest_item_at","due_at","attempts"] | all(. as $k | $o | has($k))) | select(.counts as $c | ["items","automation","events","author","integration_notes","trivial","xrefs","xrefs_passing","judged","unjudged"] | all(. as $k | $c | has($k)))] | length' <<<"$j")"
check "--json: top-level keys" "excluded,fetch_failures,lookback_days,now,skipped,windows" "$(jq -r 'keys|join(",")' <<<"$j")"
new; py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.save()"
git init -q "$WORLD/co" && git -C "$WORLD/co" commit -q --allow-empty -m init
for c in notify publish hook; do printf '#!/bin/sh\necho "$@" >> "%s/log/%s.log"\n' "$WORLD" "$c" > "$WORLD/$c.sh"; chmod +x "$WORLD/$c.sh"; done
cfg "checkout: $WORLD/co
notify_cmd: [$WORLD/notify.sh]
publish_cmd: [$WORLD/publish.sh]
sha_fetch_cmd: [$WORLD/hook.sh]
judge:
  model: example-model"
refs_before="$(git -C "$WORLD/co" for-each-ref | md5sum)"
gm scan --now "$NOW" >/dev/null 2>&1
check "scan: no fork-sandbox run" "" "$(grep '^run' "$WORLD/log/sandbox.log" 2>/dev/null)"
check "scan: notify, publish, hook never called" "" "$(cat "$WORLD"/log/notify.log "$WORLD"/log/publish.log "$WORLD"/log/hook.log 2>/dev/null)"
if [[ ! -e "$state/ledger.jsonl" && ! -e "$state/summary.md" && ! -e "$state/run.lock" ]]; then ok "scan: no ledger, summary or lock"; else no "scan: no ledger, summary or lock"; fi
check "scan: the checkout's refs are unchanged" "$refs_before" "$(git -C "$WORLD/co" for-each-ref | md5sum)"

# ======================= run: helpers and git fixtures ========================
# Repositories are cloned through file:// so a clone holds only what the
# remote advertises; a plain-path clone would copy every object.
r="$top/repos"; mkdir -p "$r"
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
git init -q -b main "$r/origin"
git -C "$r/origin" commit -q --allow-empty -m base
sha_present="$(git -C "$r/origin" rev-parse HEAD)"
git -C "$r/origin" commit -q --allow-empty -m "a commit on a side ref"
sha_origin="$(git -C "$r/origin" rev-parse HEAD)"
git -C "$r/origin" update-ref refs/other/x "$sha_origin"
git -C "$r/origin" reset -q --hard "$sha_present"
git clone -q "file://$r/origin" "$r/third"
git -C "$r/third" commit -q --allow-empty -m "a commit only the third repository has"
sha_third="$(git -C "$r/third" rev-parse HEAD)"
sha_none="$(printf 'e%.0s' $(seq 40))"
sha_late="$(printf '1%.0s' $(seq 40))"   # replaced below with a real commit

rcfg() {  # rcfg [top-level yaml] [judge yaml, indented]: a run-ready config
    [[ -d "$WORLD/co" ]] || git clone -q "file://$r/origin" "$WORLD/co"
    cfg "checkout: $WORLD/co
${1:-}
judge:
  model: example-model
${2:-}"
}
mkdue() {  # mkdue <sha> <pr>...: a due window per PR, sign-offs a minute apart
    local sha="$1"; shift
    local code="w = World()"
    local i=0 p
    for p in "$@"; do
        i=$(( i + 1 ))
        code+="
w.base(pr=$p, so='so$p', tid='t$p', sha='$sha', at='2026-11-08T09:0$i:00Z'); w.comment($p, ${p}1, OLD, 'bob', LONG + ' pr$p')"
    done
    py "$code
w.save()"
}
fnd() {  # fnd <id> <verdict> [severity] [claim]: one finding as the judge writes it
    jq -nc --arg id "$1" --arg v "$2" --arg sev "${3:-high}" --arg claim "${4:-claim $1}" \
        '{id:$id,claim:$claim,verdict:$v,severity:$sev,true_at_head:true,how_checked:"traced",
          evidence:{path:"a.c:1",ran:["x"]},failure_scenario:"s",panel_coverage:"missed",
          panel_refs:["0a1b2c3d"],code_owner:"human",blame:["x"],gap:"g",seat:"@core",
          seat_on_roster:true,confidence:"high",duplicate_of:null}'
}
vfile() {  # vfile <pr> [finding json]...: what the judge leaves for that PR
    local pr="$1"; shift
    local arr; arr="$(printf '%s\n' "$@" | jq -sc .)"
    jq -nc --argjson f "$arr" --argjson pr "$pr" \
        '{pr:$pr,reviewed_sha:"x",head_matches:true,findings:$f,notes:"a note"}' > "$WORLD/verdicts-$pr.json"
}
launches() { local n; n="$(grep -c '^run ' "$WORLD/log/sandbox.log" 2>/dev/null)"; echo "${n:-0}"; }
recs() { jq -c "select(.kind == \"$1\")" "$state/ledger.jsonl" 2>/dev/null; }
runq() { gm run --now "${1:-$NOW}" >"$WORLD/out" 2>"$WORLD/err"; }

printf '\n== R6.1 run and summary refuse a bad invocation before doing anything ==\n'
new; mkdue "$sha_present" 1
nothing() { [[ ! -s "$WORLD/log/mail.log" && ! -s "$WORLD/log/forge.log" && ! -s "$WORLD/log/sandbox.log" ]]; }
chk() {  # chk <label> <expected message part> args...
    local l="$1" m="$2"; shift 2
    local o rc; o="$(gm "$@" 2>&1)"; rc=$?
    if [[ $rc -eq 2 && "$o" == *"$m"* ]] && nothing; then ok "$l"; else no "$l" "rc=$rc out=$o"; fi
}
cfg; chk "run with no checkout" checkout run --now "$NOW"
cfg "checkout: $WORLD/not-a-repo
judge:
  model: m"; mkdir -p "$WORLD/not-a-repo"; chk "run with checkout not a git work tree" "not a git work tree" run --now "$NOW"
git clone -q "file://$r/origin" "$WORLD/co"
cfg "checkout: $WORLD/co"; chk "run with no judge.model" judge.model run --now "$NOW"
rcfg; chk "run --json" --json run --json; chk "run --max-judges 0" max-judges run --max-judges 0
chk "run --max-judges x" max-judges run --max-judges x; chk "summary --no-fetch" no-fetch summary --no-fetch
chk "summary --json" --json summary --json
rm "$LKML_GAP_MONITOR_FILE"
chk "run with a missing config names the path" "$WORLD/config.yaml" run --now "$NOW"
chk "summary with a missing config names the path" "$WORLD/config.yaml" summary --now "$NOW"

printf '\n== R6.2 the run lock ==\n'
new; mkdue "$sha_present" 1; rcfg; vfile 1
mkdir -p "$state"
out="$(PATH="$top/bin:$PATH" python3 - "$state/run.lock" "$gm_script" "$NOW" <<'PY' 2>&1
import fcntl, subprocess, sys
fd = open(sys.argv[1], "w")
fcntl.flock(fd, fcntl.LOCK_EX)
r = subprocess.run(["python3", sys.argv[2], "run", "--now", sys.argv[3]], capture_output=True, text=True)
print(r.returncode); print(r.stdout + r.stderr)
PY
)"
check "held: exit 1" 1 "$(head -1 <<<"$out")"
contains "held: message names the lock" "$out" "run.lock"
if nothing; then ok "held: no fetch, no launch"; else no "held: no fetch, no launch"; fi
if [[ ! -e "$state/ledger.jsonl" ]]; then ok "held: ledger untouched"; else no "held: ledger untouched"; fi
runq; check "stale lock file, nobody holds it: runs and judges" 1 "$(launches)"

printf '\n== R6.3 the reviewed sha ==\n'
heads() { git -C "$WORLD/co" for-each-ref refs/heads | md5sum; }
new; mkdue "$sha_present" 1; rcfg; vfile 1; h0="$(heads)"
runq; check "present: judge launched with --checkout <sha>" 1 "$(grep -c -- "--checkout $sha_present" "$WORLD/log/sandbox.log")"
check "present: no refs/lkml-gap ref" "" "$(git -C "$WORLD/co" for-each-ref refs/lkml-gap)"
check "present: branches untouched" "$h0" "$(heads)"
new; mkdue "$sha_origin" 1; rcfg "sha_fetch_cmd: [$top/bin/argvlog, hook]"; vfile 1; h0="$(heads)"
runq
check "fetched from origin: judge launched" 1 "$(launches)"
check "  kept under refs/lkml-gap/<pr>-<12 hex>" "$sha_origin" "$(git -C "$WORLD/co" rev-parse "refs/lkml-gap/1-${sha_origin:0:12}")"
if [[ ! -e "$WORLD/log/hook.args" ]]; then ok "  hook not called"; else no "  hook not called"; fi
check "  no branch created" "$h0" "$(heads)"
for v in SIGNED-OFF RESPIN; do
    new; mkdue "$sha_third" 1; rcfg "sha_fetch_cmd: [$top/bin/argvlog, hook]"; vfile 1
    py "w = World(); w.base(sha='$sha_third', verdict='$v'); w.comment(1, 11, OLD, 'bob', LONG); w.save()"
# shellcheck disable=SC2016  # literal $2 and backticks are wanted
    printf 'git fetch -q "%s" "$2"\n' "$r/third" > "$WORLD/hook-action"
    runq
    check "hook ($v): judge launched" 1 "$(launches)"
    check "  hook argv ends <pr> <sha> $v" "1"$'\n'"$sha_third"$'\n'"$v" "$(grep -B3 -- '--end--' "$WORLD/log/hook.args" | head -3)"
    check "  hook cwd is the checkout" "$WORLD/co" "$(head -1 "$WORLD/log/hook.cwd")"
    check "  ref created" "$sha_third" "$(git -C "$WORLD/co" rev-parse "refs/lkml-gap/1-${sha_third:0:12}")"
done
new; mkdue "$sha_none" 1; rcfg; vfile 1; h0="$(heads)"
runq; rc=$?; gm run --now "$NOW" >/dev/null 2>&1; rc=$?
check "missing, no hook: no launch" 0 "$(launches)"
check "  exit 1" 1 "$rc"
check "  one sha-unavailable record after two runs" 1 "$(recs window | jq -s '[.[] | select(.status == "sha-unavailable" and .attempt == 0)] | length')"
check "  scan says blocked" blocked "$(cls 1:so1)"
contains "  the summary's blocked table names the window" "$(cat "$state/summary.md")" "1:so1"
git clone -q "file://$r/origin" "$WORLD/late-src"
git -C "$WORLD/late-src" commit -q --allow-empty -m "late arrival"
sha_late="$(git -C "$WORLD/late-src" rev-parse HEAD)"
git -C "$WORLD/late-src" push -q "$r/origin" "HEAD:refs/other/late"
py "w = World(); w.base(sha='$sha_late'); w.comment(1, 11, OLD, 'bob', LONG); w.save()"
rm -f "$state/ledger.jsonl"; : > "$WORLD/log/sandbox.log"
vfile 1; runq; check "  once the sha is on origin a run judges it" 1 "$(launches)"
check "  and scan prints judged" judged "$(cls 1:so1)"
new; mkdue "$sha_none" 1; rcfg "sha_fetch_cmd: [$top/bin/argvlog, hook]"; vfile 1; touch "$WORLD/fail-hook"
runq; check "hook set and failing: blocked, no judge" "0 blocked" "$(launches) $(cls 1:so1)"
check "  one record" 1 "$(recs window | wc -l)"
new; py "w = World(); w.base(); w.comment(1, 11, OLD, 'bob', LONG); w.threads['t1']['msgs'][-1]['headers'] = [h for h in w.threads['t1']['msgs'][-1]['headers'] if h[0] != 'X-Review-Target']; w.save()"
rcfg; vfile 1; runq
check "no sha on the sign-off message: blocked, no judge" "0 blocked" "$(launches) $(cls 1:so1)"
contains "  the record's notes mention the header" "$(recs window | jq -r '.notes')" "X-Review-Target"

printf '\n== R6.4 sha_fetch_cmd, notify_cmd and publish_cmd: argv, no shell ==\n'
for key in sha_fetch_cmd notify_cmd publish_cmd; do
    for form in list string; do
        new; sha="$sha_present"; [[ $key == sha_fetch_cmd ]] && sha="$sha_none"
        mkdue "$sha" 1; vfile 1 "$(fnd F1 real-defect)"
        arg="x y; \$(touch $WORLD/marker)"; name="${key%_cmd}"; name="${name%%_*}"
        if [[ $form == list ]]; then val="[$top/bin/argvlog, $name, \"$arg\"]"
        else val="\"$top/bin/argvlog $name 'x y; \$(touch $WORLD/marker)'\""; fi
        rcfg "$key: $val"; runq
        [[ -f "$WORLD/log/$name.args" ]] || { no "$key as $form: was called"; continue; }
        check "$key as $form: the argument is literal and first" "$arg" "$(head -1 "$WORLD/log/$name.args")"
        if [[ ! -e "$WORLD/marker" ]]; then ok "$key as $form: no shell ran"; else no "$key as $form: no shell ran"; fi
        case $key in
        sha_fetch_cmd) check "$key as $form: <pr> <sha> <verdict> appended last" "1 $sha SIGNED-OFF" "$(sed -n '2,4p' "$WORLD/log/$name.args" | paste -sd' ')" ;;
        notify_cmd) check "$key as $form: nothing appended" "--end--" "$(sed -n 2p "$WORLD/log/$name.args")" ;;
        publish_cmd) check "$key as $form: the summary path appended" "$state/summary.md" "$(sed -n 2p "$WORLD/log/$name.args")" ;;
        esac
    done
done

# ======================= evidence and launch ====================================
printf '\n== R6.5 the evidence directory ==\n'
new; mkdue "$sha_present" 1; rcfg; vfile 1; runq
ev="$WORLD/scratch/1-so1-a1/evidence"
check "exactly five files for a one-thread PR" "feedback.md index.json later.md pr.md thread.md" "$(find "$ev" -type f -printf '%f\n' | sort | paste -sd' ')"
check "--attach-dir is that directory" 1 "$(grep -c -- "--attach-dir $ev " "$WORLD/log/sandbox.log")"
if [[ "$ev" != "$state"/* ]]; then ok "  and it is not under state_dir"; else no "  and it is not under state_dir"; fi
new; py "w = World(); w.thread('t1', 1); w.msg('t1', 'm-before', '2026-11-08T08:00:00Z', '@core', 'before'); w.signoff('t1', 'so1', SO, sha='$sha_present')
w.msg('t1', 'm-after', '2026-11-08T10:00:00Z', '@core', 'after the first sign-off'); w.signoff('t1', 'so2', '2026-11-08T12:00:00Z', sha='$sha_present', version=2)
w.pr(1); w.comment(1, 11, '2026-11-08T11:00:00Z', 'bob', LONG); w.save()"; rcfg; vfile 1; runq
t="$(cat "$WORLD/scratch/1-so1-a1/evidence/thread.md")"
contains "thread.md holds the sign-off message id" "$t" "id so1"; contains "  and an earlier message" "$t" "m-before"
lacks "  not a message posted after it" "$t" "m-after"; lacks "  nor the second sign-off" "$t" "id so2"
new; py "w = World(); w.thread('t0', 1, started='2026-11-06T09:00:00Z'); w.msg('t0', 'm0-early', '2026-11-07T08:00:00Z', '@core', 'early words'); w.msg('t0', 'm0-late', '2026-11-08T12:00:00Z', '@core', 'late words')
w.thread('t1', 1); w.signoff('t1', 'so1', SO, sha='$sha_present'); w.thread('t9', 1, started='2026-11-08T12:00:00Z'); w.msg('t9', 'm9-later', '2026-11-08T13:00:00Z', '@core', 'a later thread')
w.pr(1); w.comment(1, 11, OLD, 'bob', LONG); w.save()"; rcfg; vfile 1; runq
ev="$WORLD/scratch/1-so1-a1/evidence"
check "other threads: the earlier one is thread-earlier-1.md" "feedback.md index.json later.md pr.md thread-earlier-1.md thread.md" "$(find "$ev" -type f -printf '%f\n' | sort | paste -sd' ')"
contains "  it holds the earlier message" "$(cat "$ev/thread-earlier-1.md")" "early words"
lacks "  and omits the one dated after the sign-off" "$(cat "$ev/thread-earlier-1.md")" "late words"
check "  no file holds the later thread's message" 0 "$(grep -l 'm9-later\|a later thread' "$ev"/* | wc -l)"
new; py "w = World(); w.base(sha='$sha_present'); w.pr(1, body='', merged_at='2026-11-09T09:00:00Z'); w.comment(1, 11, OLD, 'bob', LONG)
w.commit(1, '$sha_present', '2026-11-07T09:00:00Z', 'the reviewed one'); w.commit(1, 'f' * 40, '2026-11-09T08:00:00Z', 'a later fix'); w.save()"; rcfg; vfile 1; runq
ev="$WORLD/scratch/1-so1-a1/evidence"
contains "pr.md: title" "$(cat "$ev/pr.md")" "Retry a stalled flush"; contains "  author" "$(cat "$ev/pr.md")" "alice"; contains "  (empty) for an empty body" "$(cat "$ev/pr.md")" "(empty)"
contains "later.md: the commit after the reviewed sha" "$(cat "$ev/later.md")" "a later fix"
lacks "  not the reviewed one" "$(cat "$ev/later.md")" "the reviewed one"; contains "  the merge line" "$(cat "$ev/later.md")" "Merged at 2026-11-09T09:00:00Z"

printf '\n== R6.6 feedback.md and index.json ==\n'
new; py "w = World(); w.base(sha='$sha_present')
w.review(1, 101, '2026-11-08T10:00:00Z', 'bob', 'REVIEWBODY ' + LONG)
w.inline(1, 102, '2026-11-08T11:00:00Z', 'bob', 'INLINEBODY ' + LONG)
w.inline(1, 109, '2026-11-08T11:30:00Z', 'alice', 'REPLYBODY thanks, fixed', reply_to=102)
w.comment(1, 103, '2026-11-08T12:00:00Z', 'alice', 'AUTHORBODY ' + LONG)
w.comment(1, 104, '2026-11-08T13:00:00Z', 'carol', '<!-- lkml-integration: s v1 -->\n- 1234567 widget: x -- take -- ok\nNOTEBODY')
w.comment(1, 105, '2026-11-08T13:30:00Z', 'ci[bot]', 'BOTBODY ' + LONG)
w.xref(1, 50, '2026-11-08T14:00:00Z', labels=['bug'], title='XREFTITLE')
w.event(1, 'head_ref_force_pushed', '2026-11-08T15:00:00Z'); w.save()"; rcfg; vfile 1; runq
fb="$WORLD/scratch/1-so1-a1/evidence/feedback.md"
check "F1..F5 in time order" "F1 review,F2 inline,F3 comment,F4 comment,F5 xref" "$(grep '^## F' "$fb" | sed -E 's/^## (F[0-9]+) \[([a-z]+)\].*/\1 \2/' | paste -sd,)"
check "the reply sits inside its parent's section" "1" "$(awk '/^## F2 /{p=1} /^## F3 /{p=0} p && /REPLYBODY/' "$fb" | wc -l)"
check "the reply has no F heading of its own" 5 "$(grep -c '^## F' "$fb")"
lacks "the bot comment is absent" "$(cat "$fb")" "BOTBODY"; check "one event line" 1 "$(grep -c '^--- event:' "$fb")"
ix="$WORLD/scratch/1-so1-a1/evidence/index.json"
check "index.json keys are F1..F5" "F1,F2,F3,F4,F5" "$(jq -r 'keys|join(",")' "$ix")"
check "  each entry's kind, id, url, user" "review:101:https://example.com/r/101:bob,inline:102:https://example.com/i/102:bob,comment:103:https://example.com/c/103:alice,comment:104:https://example.com/c/104:carol,xref:50:https://example.com/x/50:dave" "$(jq -r '[.[] | "\(.kind):\(.id):\(.url):\(.user)"] | join(",")' "$ix")"
check "  the window record lists those five and the nested reply" "comment:103,comment:104,inline:102,inline:109,review:101,xref:50" "$(recs window | jq -r '.items | sort | join(",")')"
new; py "w = World(); w.base(sha='$sha_present')
w.inline(1, 200, '2026-11-08T10:00:00Z', 'ci[bot]', 'BOTPARENT text of the bot', utype='Bot')
w.inline(1, 201, '2026-11-08T10:30:00Z', 'bob', 'REPLYTOBOT ' + LONG, reply_to=200)
w.inline(1, 210, '2026-11-07T09:00:00Z', 'carol', 'OLDPARENT before the sign-off')
w.inline(1, 211, '2026-11-08T11:00:00Z', 'bob', 'REPLYTOOLD ' + LONG, reply_to=210); w.save()"; rcfg; vfile 1; runq
fb="$WORLD/scratch/1-so1-a1/evidence/feedback.md"
check "replies to an unnumbered parent are their own items" 2 "$(grep -c '^## F' "$fb")"
contains "  the bot parent is quoted" "$(cat "$fb")" "> BOTPARENT text of the bot"; contains "  the old parent is quoted" "$(cat "$fb")" "> OLDPARENT before the sign-off"
new; py "w = World(); w.base(sha='$sha_present')
w.inline(1, 300, '2026-11-08T10:00:00Z', 'alice', 'AUTHORNOTE ' + LONG)
w.inline(1, 301, '2026-11-08T10:30:00Z', 'bob', 'BOBCLAIM ' + LONG, reply_to=300)
w.inline(1, 302, '2026-11-08T11:00:00Z', 'alice', 'AUTHORANSWER ' + LONG, reply_to=301); w.save()"; rcfg; vfile 1; runq
fb="$WORLD/scratch/1-so1-a1/evidence/feedback.md"
ix="$WORLD/scratch/1-so1-a1/evidence/index.json"
check "a trigger reply under the author's note gets its own F" "inline:300,inline:301" "$(jq -r '[.[] | "\(.kind):\(.id)"] | join(",")' "$ix")"
check "  the author's answer to it nests under the claim" "1" "$(awk '/^## F2 /{p=1} p && /AUTHORANSWER/' "$fb" | wc -l)"
contains "  the claim quotes the note it answers" "$(cat "$fb")" "> AUTHORNOTE"
new; py "w = World(); w.base(sha='$sha_present'); w.comment(1, 11, OLD, 'bob', LONG)
w.xref(1, 50, OLD, labels=['bug'], title='passes'); w.xref(1, 51, OLD, title='Neutral one'); w.xref(1, 52, OLD, title='Neutral two'); w.save()"; rcfg; vfile 1; runq
fb="$WORLD/scratch/1-so1-a1/evidence/feedback.md"
check "cross-references: the passing one and the comment are numbered" 2 "$(grep -c '^## F' "$fb")"
contains "  the closing line counts the two left out" "$(cat "$fb")" "(2 other later issues"
check "  neither left-out id is in items" "" "$(recs window | jq -r '.items[] | select(. == "xref:51" or . == "xref:52")')"

printf '\n== R6.7 the handoff ==\n'
new; py "w = World(); w.thread('t1', 1, tier=None); w.signoff('t1', 'so1', SO, sha='$sha_present', version=3)
w.msg('t1', 'cover', '2026-11-07T10:00:00Z', '@pr-author', 'Frozen-Head: ' + 'f' * 40 + '\nBase: ' + 'c' * 40 + '\n', subject='[PATCH v1 1/1] widget')
w.pr(1, title='Title with @@SHA@@ inside'); w.comment(1, 11, OLD, 'bob', LONG); w.comment(1, 12, OLD, 'bob', LONG + ' second'); w.save()"
rcfg; vfile 1; runq; hf="$WORLD/scratch/1-so1-a1/handoff.md"
contains "title containing a placeholder appears verbatim" "$(cat "$hf")" "Title with @@SHA@@ inside"
check "no other @@ left" 1 "$(grep -c '@@' "$hf")"
contains "the reviewed sha" "$(cat "$hf")" "commit \`$sha_present\`"; contains "untiered for a thread with no tier" "$(cat "$hf")" "untiered tier, version 3"
contains "the count of numbered items" "$(cat "$hf")" "the 2 later feedback items"; contains "thread file names" "$(cat "$hf")" "\`/attachments/thread.md\`"
contains "roster from the Panel and Advisory lines" "$(cat "$hf")" "@core, @tests (advisory: @second-opinion)"
contains "SIGNED-OFF note" "$(cat "$hf")" "The verdict was SIGNED-OFF"; lacks "  and not the RESPIN note" "$(cat "$hf")" "The verdict was RESPIN"
contains "base from the author cover wins" "$(cat "$hf")" "base commit is \`$(printf 'c%.0s' $(seq 40))\`"
new; py "w = World(); w.thread('t1', 1, body='Author: @pr-author\nPanel: @core\nSecretary: @secretary\n'); w.signoff('t1', 'so1', SO, verdict='RESPIN', sha='$sha_present'); w.pr(1); w.comment(1, 11, OLD, 'bob', LONG); w.save()"
rcfg; vfile 1; runq; hf="$WORLD/scratch/1-so1-a1/handoff.md"
contains "RESPIN note" "$(cat "$hf")" "The verdict was RESPIN"; lacks "  and not the SIGNED-OFF note" "$(cat "$hf")" "The verdict was SIGNED-OFF"
contains "no Base anywhere: the not-recorded note" "$(cat "$hf")" "base is not recorded"
tmpl="$repo_dir/fleet/prompts/gap-judge.md"; tt="$(cat "$tmpl")"
for ph in PR TITLE SHA VERDICT VERSION SIGNOFF_DATE TIER RESPIN_NOTE BASE_NOTE THREAD_FILES ROSTER N_ITEMS; do contains "template holds @@$ph@@" "$tt" "@@$ph@@"; done
for v in real-defect design-disagreement nit not-knowable not-in-reviewed-tree not-a-finding duplicate unresolved; do contains "template names verdict $v" "$tt" "\`$v\`"; done
for c in missed raised-and-dropped raised-and-decided raised-and-fixed-short predicted n-a; do contains "template names coverage $c" "$tt" "\`$c\`"; done
contains "template names verdicts.json" "$tt" verdicts.json; contains "template names verdicts.md" "$tt" verdicts.md
lacks "template has no X-Lkml- header name" "$tt" "X-Lkml-"; lacks "template does not name tier-focus.md" "$tt" "tier-focus.md"
new; mkdue "$sha_present" 1; rcfg; mkdir -p "$WORLD/alone/scripts"; cp "$gm_script" "$WORLD/alone/scripts/"
out="$(PATH="$top/bin:$PATH" python3 "$WORLD/alone/scripts/lkml-gap-monitor.py" run --now "$NOW" 2>&1)"; rc=$?
check "template missing: exit 2" 2 "$rc"; contains "  names the template path" "$out" "$WORLD/alone/fleet/prompts/gap-judge.md"
if [[ ! -s "$WORLD/log/mail.log" ]]; then ok "  before any fetch"; else no "  before any fetch"; fi

printf '\n== R6.8 the launch ==\n'
new; mkdue "$sha_present" 1; rcfg; vfile 1; runq
line="$(grep '^run ' "$WORLD/log/sandbox.log" | sed -E 's/--branch [^ ]+/--branch BRANCH/')"
meta='{"kind":"investigate","difficulty":3,"size":"s","prompt_template_id":"lkml-gap-judge-v1","stage":"gap-monitor"}'
check "argv under defaults" "run --wait --wait-timeout 7200 --harness claude --model example-model --branch BRANCH --checkout $sha_present --attach-dir $WORLD/scratch/1-so1-a1/evidence --task-meta $meta $WORLD/co $WORLD/scratch/1-so1-a1/handoff.md" "$line"
new; mkdue "$sha_present" 1; rcfg "" "  harness: pi
  wait_timeout: 99
  run_args: [--no-services, --flag-b]"; vfile 1; runq
line="$(grep '^run ' "$WORLD/log/sandbox.log" | sed -E 's/--branch [^ ]+/--branch BRANCH/')"
check "configured harness, timeout and run args (before --task-meta)" "run --wait --wait-timeout 99 --harness pi --model example-model --branch BRANCH --checkout $sha_present --attach-dir $WORLD/scratch/1-so1-a1/evidence --no-services --flag-b --task-meta $meta $WORLD/co $WORLD/scratch/1-so1-a1/handoff.md" "$line"
new; mkdue "$sha_present" 1 2; rcfg; vfile 1; vfile 2; echo nofile > "$WORLD/mode-1"; runq; echo ok > "$WORLD/mode-1"; runq
b="$(grep -o -- '--branch [^ ]*' "$WORLD/log/sandbox.log")"
check "three launches" 3 "$(wc -l <<<"$b")"; check "all three branch names differ" 3 "$(sort -u <<<"$b" | wc -l)"
contains "the attempt is in the branch name (a1, then a2)" "$(sed -n 1p <<<"$b") $(sed -n 3p <<<"$b")" "-a1-"
contains "  second attempt" "$(sed -n 3p <<<"$b")" "-a2-"

# ======================= verdicts, failures, attempts ===========================
printf '\n== R6.9 verdict ingestion ==\n'
new; py "w = World(); w.base(sha='$sha_present'); w.comment(1, 11, OLD, 'bob', LONG + ' one'); w.comment(1, 12, '2026-11-09T10:00:00Z', 'bob', LONG + ' two'); w.comment(1, 13, '2026-11-09T11:00:00Z', 'bob', LONG + ' three'); w.save()"
rcfg; vfile 1 "$(fnd F1 real-defect)" "$(fnd F2 nit low)" "$(fnd F3 design-disagreement)"; runq
check "three finding lines and one window line" "3 1" "$(recs finding | wc -l) $(recs window | wc -l)"
check "every record has schema 1" 4 "$(jq -s '[.[] | select(.schema == 1)] | length' "$state/ledger.jsonl")"
check "the window line is last" window "$(tail -1 "$state/ledger.jsonl" | jq -r .kind)"
f1="$(recs finding | head -1)"
check "every field of the decision is present" 0 "$(jq -r '[("judged_at","window","pr","thread","signoff_msg","signoff_at","signoff_verdict","version","tier","reviewed_sha","finding_id","item","claim","verdict","severity","true_at_head","how_checked","evidence","failure_scenario","panel_coverage","panel_refs","code_owner","blame","gap","seat","seat_on_roster","confidence","duplicate_of","run_dir","judge_model") as $k | select(has($k) | not)] | length' <<<"$f1")"
check "the judge's fields are copied through unchanged" "$(fnd F1 real-defect | jq -S 'del(.id)')" "$(jq -S '{claim,verdict,severity,true_at_head,how_checked,evidence,failure_scenario,panel_coverage,panel_refs,code_owner,blame,gap,seat,seat_on_roster,confidence,duplicate_of}' <<<"$f1")"
check "  context fields" "1:so1 1 so1 SIGNED-OFF standard $sha_present example-model 1" "$(jq -r '[.window,.pr,.signoff_msg,.signoff_verdict,.tier,.reviewed_sha,.judge_model,.version]|join(" ")' <<<"$f1")"
check "  item comes from index.json by the F stem" "comment:11:https://example.com/c/11:bob" "$(jq -r '.item | "\(.kind):\(.id):\(.url):\(.user)"' <<<"$f1")"
w1="$(recs window)"
check "window record: status, attempt, head_matches, notes, signoff_at" "judged 1 true a note 2026-11-08T09:00:00Z" "$(jq -r '[.status,.attempt,.head_matches,.notes,.signoff_at]|join(" ")' <<<"$w1")"
check "window record lists the three items" "comment:11,comment:12,comment:13" "$(jq -r '.items|join(",")' <<<"$w1")"
check "run_dir on the finding and the window agree" "$(jq -r .run_dir <<<"$f1")" "$(jq -r .run_dir <<<"$w1")"
new; py "w = World(); w.base(sha='$sha_present'); w.comment(1, 11, OLD, 'bob', LONG + ' one'); w.comment(1, 12, '2026-11-09T10:00:00Z', 'bob', LONG + ' two'); w.save()"
rcfg; vfile 1 "$(fnd F1 nit)" "$(fnd F2a real-defect)" "$(fnd F2b nit)"; runq
check "split id: two findings F2a, F2b with item F2's URL and id" "F2a:https://example.com/c/12:12 F2b:https://example.com/c/12:12" "$(recs finding | jq -r 'select(.finding_id | startswith("F2")) | "\(.finding_id):\(.item.url):\(.item.id)"' | paste -sd' ')"
new; py "w = World(); w.base(sha='$sha_present'); w.comment(1, 11, OLD, 'bob', LONG + ' one'); w.comment(1, 12, '2026-11-09T10:00:00Z', 'bob', LONG + ' two'); w.comment(1, 13, '2026-11-09T11:00:00Z', 'bob', LONG + ' three'); w.save()"
rcfg; vfile 1 "$(fnd F9 nit)" "$(fnd general nit)" "$(fnd F1 nit)" "$(fnd F2 nit)" "$(fnd F3 nit)"; runq
check "unmapped ids are recorded with item null" "F9:null general:null" "$(recs finding | jq -r 'select(.finding_id == "F9" or .finding_id == "general") | "\(.finding_id):\(.item)"' | paste -sd' ')"
new; py "w = World(); w.base(sha='$sha_present'); w.comment(1, 11, OLD, 'bob', LONG + ' one'); w.comment(1, 12, '2026-11-09T10:00:00Z', 'bob', LONG + ' two'); w.save()"
rcfg; vfile 1; runq
check "empty findings list: judged, no findings" "judged 0" "$(recs window | jq -r '.status') $(recs finding | wc -l)"
contains "  the notes name F1 and F2" "$(recs window | jq -r .notes)" "F1, F2"; contains "  and so does stderr" "$(cat "$WORLD/err")" "F1, F2"

printf '\n== R6.10 idempotence and re-judging ==\n'
new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 nit)"; runq
sum1="$(md5sum < "$state/ledger.jsonl")"; : > "$WORLD/log/sandbox.log"
gm run --now "$NOW" >/dev/null 2>&1; rc=$?
check "second run launches nothing" 0 "$(launches)"; check "  appends nothing" "$sum1" "$(md5sum < "$state/ledger.jsonl")"; check "  exit 0" 0 "$rc"
py "w = World(); w.base(sha='$sha_present'); w.comment(1, 11, OLD, 'bob', LONG + ' pr1'); w.comment(1, 12, '2026-11-09T10:00:00Z', 'bob', LONG + ' fresh'); w.save()"
vfile 1 "$(fnd F1 nit)"; runq
check "a new outside comment: one launch" 1 "$(launches)"
fb="$WORLD/scratch/1-so1-a1/evidence/feedback.md"
check "  attempt 1 again (the first was judged)" 1 "$(recs window | tail -1 | jq -r .attempt)"
check "  exactly one F heading, the new comment" "## F1 [comment] by bob at 2026-11-09T10:00:00Z" "$(grep '^## F' "$fb")"
contains "  the earlier item is in the closing judged section" "$(sed -n '/Already judged/,$p' "$fb")" "comment:11"
check "  the window record lists only the new item" "comment:12" "$(recs window | tail -1 | jq -r '.items|join(",")')"
check "  scan prints judged" judged "$(cls 1:so1)"
: > "$WORLD/log/sandbox.log"; rm -f "$state/ledger.jsonl"; rm -rf "$WORLD/scratch"; runq
check "ledger deleted: judged again with every item numbered" "2" "$(grep -c '^## F' "$WORLD/scratch/1-so1-a1/evidence/feedback.md")"

printf '\n== R6.11 judge failure ==\n'
fmode() {  # fmode <label> <mode> <expected status> <expected findings> <expected exit> [note part]
    new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 real-defect)"; echo "$2" > "$WORLD/mode"
    gm run --now "$NOW" >"$WORLD/out" 2>"$WORLD/err"; local rc=$?
    check "$1: status, findings, exit" "$3 $4 $5" "$(recs window | jq -r '.status') $(recs finding | wc -l) $rc"
    [[ -z "${6:-}" ]] || contains "  notes name the reason" "$(recs window | jq -r '.notes')" "$6"
}
fmode "exit 0 with no file" nofile judge-failed 0 1 "no verdicts.json"
fmode "invalid JSON" badjson judge-failed 0 1 "not valid JSON"
fmode "valid object without findings" nofindings judge-failed 0 1 "no findings list"
fmode "findings a string" strfindings judge-failed 0 1 "no findings list"
fmode "top level a list" listtop judge-failed 0 1 "no findings list"
fmode "no run dir line" norundir judge-failed 0 1 "run dir"
check "  run_dir null" null "$(recs window | jq -r '.run_dir')"
fmode "exit 3 with a valid file" exit3-valid judged 1 0

printf '\n== R6.12 attempts are capped ==\n'
new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 nit)"; echo nofile > "$WORLD/mode"
runq; check "run 1 fails: attempt 1" 1 "$(recs window | tail -1 | jq -r .attempt)"; check "  scan: due" due "$(cls 1:so1)"
runq; check "run 2 fails: attempt 2" 2 "$(recs window | tail -1 | jq -r .attempt)"; check "  scan: failed" failed "$(cls 1:so1)"
: > "$WORLD/log/sandbox.log"; n1="$(wc -l < "$state/ledger.jsonl")"
gm run --now "$NOW" >/dev/null 2>&1; rc=$?
check "run 3 launches nothing, appends nothing, exits 0" "0 $n1 0" "$(launches) $(wc -l < "$state/ledger.jsonl") $rc"
contains "  the summary lists it as failed" "$(grep 1:so1 "$state/summary.md")" "failed"
new; mkdue "$sha_present" 1; rcfg "" "  max_attempts: 3"; vfile 1 "$(fnd F1 nit)"; echo nofile > "$WORLD/mode"; runq; runq; runq
check "max_attempts 3: the third run launches" 3 "$(launches)"
new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 nit)"; echo nofile > "$WORLD/mode"; runq; echo ok > "$WORLD/mode"; runq
check "a failure then a success: judged, attempt 2" "judged 2" "$(cls 1:so1) $(recs window | tail -1 | jq -r .attempt)"

printf '\n== R6.13 concurrency, isolation, the cap ==\n'
new; mkdue "$sha_present" 1 2 3; rcfg; for p in 1 2 3; do vfile $p "$(fnd F1 nit)"; done; echo barrier > "$WORLD/mode"; runq
check "at most two judges at once (default), reached exactly" 2 "$(sort -n "$WORLD/barrier.counts" | tail -1)"
check "  all three windows judged" "judged,judged,judged" "$(scanj | jq -r '[.windows[].class]|join(",")')"
new; mkdue "$sha_present" 1 2 3; rcfg; for p in 1 2 3; do vfile $p "$(fnd F1 nit)"; done; echo badjson > "$WORLD/mode-2"
gm run --now "$NOW" >/dev/null 2>&1; rc=$?
check "one failing judge does not stop the others" "judged,due,judged 1" "$(scanj | jq -r '[.windows[].class]|join(",")') $rc"
check "  the failed one is recorded judge-failed" judge-failed "$(recs window | jq -r 'select(.window == "2:so2") | .status')"
new; mkdue "$sha_present" 1 2 3; rcfg; for p in 1 2 3; do vfile $p "$(fnd F1 nit)"; done
gm run --now "$NOW" --max-judges 1 >"$WORLD/out" 2>&1; rc=$?
check "--max-judges 1: one launch, the oldest sign-off" "1 1:so1 0" "$(launches) $(recs window | jq -r .window) $rc"
check "  the others are still due" "judged,due,due" "$(scanj | jq -r '[.windows[].class]|join(",")')"
contains "  a line says two were left" "$(cat "$WORLD/out")" "2 due window(s) left"
new; mkdue "$sha_present" 1 2 3; rcfg; for p in 1 2 3; do vfile $p "$(fnd F1 nit)"; done
gm run --now "$NOW" --max-judges 2 >/dev/null 2>&1; check "--max-judges 2: two launches" 2 "$(launches)"
new; mkdue "$sha_present" 2 3; py "w = World(); w.base(pr=1, so='so1', tid='t1', sha='$sha_none', at='2026-11-08T08:00:00Z'); w.comment(1, 11, OLD, 'bob', LONG)
for p in (2, 3): w.base(pr=p, so='so%d' % p, tid='t%d' % p, sha='$sha_present', at='2026-11-08T09:0%d:00Z' % p); w.comment(p, p * 10 + 1, OLD, 'bob', LONG)
w.save()"; rcfg; for p in 2 3; do vfile $p "$(fnd F1 nit)"; done
gm run --now "$NOW" --max-judges 1 >/dev/null 2>&1
check "a blocked window ahead does not use up the cap" "1 blocked,judged,due" "$(launches) $(scanj | jq -r '[.windows[].class]|join(",")')"

# ======================= integration tally =====================================
printf '\n== R6.14 integration notes are counted, not judged ==\n'
inote() { printf '%s\n' "$@"; }
new; py "w = World(); w.base(sha='$sha_present')
w.comment(1, 301, '2026-11-08T10:00:00Z', 'carol', '<!-- lkml-integration: pr-1-abc v2 -->\n- 1a2b3c4d5e widget: Bound the retry ladder -- take -- one ladder per run now.\n- 2b3c4d5e6f widget: Stop after a give-up -- take with changes -- kept the flag, shortened the comment.\n- 3c4d5e6f70 tests: Cover the stall -- drop -- duplicates an existing test.\n- 4d5e6f7081 docs: Explain it -- take -- fine.\n\nHost: test_widget 65 OK.', updated='2026-11-08T11:00:00Z')
w.save()"; rcfg; runq
n="$(recs integration)"
check "real layout: take 2, take with changes 1, drop 1" "2 1 1" "$(jq -r '[.take,.take_with_changes,.drop]|join(" ")' <<<"$n")"
check "  changes and drops hold sha, subject, reason" "2b3c4d5e6f|widget: Stop after a give-up|kept the flag, shortened the comment. 3c4d5e6f70|tests: Cover the stall|duplicates an existing test." "$(jq -r '(.changes[], .drops[]) | "\(.sha)|\(.subject)|\(.reason)"' <<<"$n" | paste -sd' ')"
check "  comment_id, updated_at, url, series, version, pr" "301 2026-11-08T11:00:00Z https://example.com/c/301 pr-1-abc 2 1" "$(jq -r '[.comment_id,.updated_at,.url,.series,.version,.pr]|join(" ")' <<<"$n")"
check "  a window holding only a note launches no judge" 0 "$(launches)"
new
# shellcheck disable=SC2016  # the note body holds literal backticks
body='<!-- lkml-integration: v v1 -->
- `1111111aaa` widget: sha in backticks -- take -- r1
- 2222222bbb widget: em dash — take — r2
- 3333333ccc widget: en dash – drop – r3
- 4444444ddd widget: bold decision -- **take with changes** -- r4
- 5555555eee widget: colon reason -- take: r5
* 6666666fff widget: star bullet -- take -- r6
7777777aaa widget: no bullet -- drop -- r7
- 8888888bbb widget: no reason -- drop
- 9999999ccc widget: next line -- take with changes -- r9
- aaaaaaaddd widget: take over the lock -- drop -- r10'
BODY="$body" py "import os; w = World(); w.base(sha='$sha_present'); w.comment(1, 301, '2026-11-08T10:00:00Z', 'carol', os.environ['BODY']); w.save()"; rcfg; runq
n="$(recs integration)"
check "variants: counts take 4, take with changes 2, drop 4" "4 2 4" "$(jq -r '[.take,.take_with_changes,.drop]|join(" ")' <<<"$n")"
check "  change reasons exactly as written, no bold marker" "r4,r9" "$(jq -r '[.changes[].reason]|join(",")' <<<"$n")"
check "  drop reasons, the empty one empty, the 'take' subject a drop" "r3,r7,,r10" "$(jq -r '[.drops[].reason]|join(",")' <<<"$n")"
check "  the backticked sha is recorded bare" "1111111aaa" "$(jq -r '.take' <<<"$n" >/dev/null; BODY="$body" python3 -c "import os,re; print(re.search(r'\`([0-9a-f]+)\`', os.environ['BODY']).group(1))")"
new; py "w = World(); w.base(sha='$sha_present')
w.comment(1, 301, '2026-11-08T10:00:00Z', 'carol', '<!-- lkml-integration: s v1 -->\n- 1111111aaa widget: a -- drop -- first thoughts')
w.comment(1, 302, '2026-11-08T11:00:00Z', 'carol', '<!-- lkml-integration: s v1 -->\n- 1111111aaa widget: a -- take -- ok\n- 2222222bbb widget: b -- take -- ok')
w.comment(1, 300, '2026-11-08T09:30:00Z', 'carol', '<!-- lkml-integration: s v1 -->\n- 1111111aaa widget: a -- drop -- zeroth thoughts')
w.comment(1, 303, '2026-11-08T12:00:00Z', 'carol', '<!-- lkml-integration: s v2 -->\n- 3333333ccc widget: c -- take -- ok'); w.save()"; rcfg; runq
check "newest per (series, version): v1 from 302, plus a v2 record" "s:1:302:2 s:2:303:1" "$(recs integration | jq -r '"\(.series):\(.version):\(.comment_id):\(.take)"' | paste -sd' ')"
runq; check "a second run appends no integration record" 2 "$(recs integration | wc -l)"
py "w = World(); w.base(sha='$sha_present')
w.comment(1, 302, '2026-11-08T11:00:00Z', 'carol', '<!-- lkml-integration: s v1 -->\n- 1111111aaa widget: a -- take -- ok\n- 2222222bbb widget: b -- drop -- changed my mind', updated='2026-11-09T11:00:00Z')
w.comment(1, 303, '2026-11-08T12:00:00Z', 'carol', '<!-- lkml-integration: s v2 -->\n- 3333333ccc widget: c -- take -- ok'); w.save()"
runq; check "after the comment changed: one new integration record" 3 "$(recs integration | wc -l)"
contains "  the summary counts the new v1 note only (week 46: take 1, drop 1)" "$(cat "$state/summary.md")" "| 2026-W46 | 1 | 1 | 0 | 1 |"
contains "  and the v2 note in its own week" "$(cat "$state/summary.md")" "| 2026-W45 | 1 | 1 | 0 | 0 |"

# ======================= summary, publish, notify, exit =========================
printf '\n== R6.15 the summary ==\n'
new; rcfg
SUMNOW=2027-01-20T00:00:00Z
mkdir -p "$state"
python3 - "$state/ledger.jsonl" <<'PY'
import json, sys
out = []
def win(key, status, signoff, at="2027-01-10T10:00:00Z", items=(), run="/r/x", notes=""):
    out.append({"schema": 1, "kind": "window", "window": key, "pr": int(key.split(":")[0]), "status": status,
                "attempt": 1, "items": list(items), "run_dir": run, "at": at, "head_matches": True,
                "notes": notes, "signoff_at": signoff})
def fin(key, fid, verdict, signoff, judged="2027-01-10T10:00:00Z", sev=None, owner=None, cov=None, seat=None,
        claim="c", url="https://example.com/c/9", run="/r/x"):
    out.append({"schema": 1, "kind": "finding", "judged_at": judged, "window": key, "pr": int(key.split(":")[0]),
                "signoff_at": signoff, "finding_id": fid, "item": {"kind": "comment", "id": 9, "url": url, "user": "bob"} if url else None,
                "claim": claim, "verdict": verdict, "severity": sev, "code_owner": owner, "panel_coverage": cov, "seat": seat,
                "run_dir": run, "judge_model": "m"})
def integ(pr, series, ver, upd, take, twc, drop, changes=(), drops=()):
    out.append({"schema": 1, "kind": "integration", "pr": pr, "series": series, "version": ver, "comment_id": 1,
                "updated_at": upd, "url": "u", "take": take, "take_with_changes": twc, "drop": drop,
                "changes": list(changes), "drops": list(drops)})
S1, S2, S3, S4, S5 = "2026-12-31T10:00:00Z", "2027-01-01T08:00:00Z", "2027-01-05T10:00:00Z", "2027-01-06T10:00:00Z", "2026-11-20T10:00:00Z"
win("1:a", "judged", S1, run="/r/a"); win("2:b", "judged", S2, run="/r/b"); win("3:c", "judged", S3, run="/r/c")
win("4:d", "judged", S4, run="/r/d"); win("5:e", "judged", S5, run="/r/e")
fin("1:a", "F1", "real-defect", S1, sev="high", owner="human", cov="missed", seat="@core", claim="claim a1", url="https://example.com/c/11", run="/r/a")
fin("1:a", "F2", "real-defect", S1, sev="medium", owner="panel", cov="raised-and-dropped", seat="@tests", claim="claim a2", run="/r/a")
fin("1:a", "F3", "nit", S1, run="/r/a")
for i, v in enumerate(["design-disagreement", "not-knowable", "not-in-reviewed-tree", "not-a-finding", "duplicate", "unresolved", "weird"], 1):
    fin("2:b", "F%d" % i, v, S2, run="/r/b")
fin("4:d", "F1", "real-defect", S4, judged="2027-01-14T10:00:00Z", sev="low", owner="human", cov="missed", seat="@core", claim="claim d", url=None, run="/r/d")
fin("5:e", "F1", "real-defect", S5, judged="2026-11-25T10:00:00Z", sev="high", owner="human", cov="predicted", seat=None, claim="claim e", run="/r/e")
integ(1, "s", 1, "2026-12-30T10:00:00Z", 1, 0, 0)
integ(1, "s", 1, "2027-01-08T10:00:00Z", 2, 1, 1, changes=[{"sha": "abc1234", "subject": "x", "reason": "kept the flag"}], drops=[{"sha": "def5678", "subject": "y", "reason": "duplicate"}])
integ(2, "s2", 1, "2027-01-06T10:00:00Z", 1, 0, 0)
win("6:f", "sha-unavailable", S1, at="2027-01-02T10:00:00Z", run=None, notes="sha missing")
for k in (1, 2):
    win("7:g", "judge-failed", S1, at="2027-01-0%dT10:00:00Z" % (k + 2), run=None, notes="failed %d" % k)
win("8:h", "judge-failed", S1, at="2027-01-04T10:00:00Z", run=None, notes="one failure")
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in out) + "\n")
PY
sm() { gm summary --now "$SUMNOW" >/dev/null 2>"$WORLD/err"; cat "$state/summary.md"; }
S="$(sm)"
row() { grep -F -- "$1" <<<"$S" | head -1; }
check "week 2026-W47" "| 2026-W47 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |" "$(row '| 2026-W47 |')"
check "year-boundary week 2026-W53: two windows, ten findings" "| 2026-W53 | 2 | 10 | 2 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |" "$(row '| 2026-W53 |')"
check "week 2027-W01" "| 2027-W01 | 2 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |" "$(row '| 2027-W01 | 2 |')"
sec() { awk -v h="$1" '$0 == h {p=1; next} /^#/ {p=0} p && /^\|/' <<<"$S" | tail -n +3; }
check "by severity" $'| high | 2 |\n| low | 1 |\n| medium | 1 |' "$(sec '### By severity')"
check "by code owner" $'| human | 3 |\n| panel | 1 |' "$(sec '### By code owner')"
check "by panel coverage" $'| missed | 2 |\n| predicted | 1 |\n| raised-and-dropped | 1 |' "$(sec '### By panel coverage')"
check "by seat (a null seat counted as (none))" $'| @core | 2 |\n| (none) | 1 |\n| @tests | 1 |' "$(sec '### By seat')"
check "last 30 days: newest first; the 56-day-old one is absent" $'| #4 | low | human | missed | claim d | - |\n| #1 | high | human | missed | claim a1 | https://example.com/c/11 |\n| #1 | medium | panel | raised-and-dropped | claim a2 | https://example.com/c/9 |' "$(sec '## Real defects, last 30 days')"
check "integration: newest record per key only" "| 2027-W01 | 2 | 3 | 1 | 1 |" "$(row '| 2027-W01 | 2 | 3')"
contains "  reasons of the changes and drops listed" "$S" "| #1 | s | v1 | take with changes | abc1234 | kept the flag |"
check "blocked and failed windows" $'| 6:f | blocked | 2027-01-02T10:00:00Z | sha missing |\n| 7:g | failed | 2027-01-04T10:00:00Z | failed 2 |\n| 8:h | retrying (1/2) | 2027-01-04T10:00:00Z | one failure |' "$(sec '## Blocked and failed windows')"
cp "$state/summary.md" "$WORLD/sum.ok"
printf '%s\n' '{"schema":1,"kind":"finding","judged_at":"2027-01-15T00:00:00Z","window":"1:a","pr":1,"signoff_at":"2026-12-31T10:00:00Z","verdict":"real-defect","severity":"high","code_owner":"human","panel_coverage":"missed","seat":"@core","claim":"orphan","run_dir":"/r/other"}' >> "$state/ledger.jsonl"
S2="$(sm)"; check "orphan findings change no count" "$(cat "$WORLD/sum.ok")" "$S2"
contains "  and stderr warns" "$(cat "$WORLD/err")" "ignored"
: > "$WORLD/log/sandbox.log"; sm >/dev/null; cp "$state/summary.md" "$WORLD/sum.2"; sm >/dev/null
check "summary is byte-identical on a second call" "$(cat "$WORLD/sum.2")" "$(cat "$state/summary.md")"
check "  and calls no stub" "" "$(cat "$WORLD/log/sandbox.log" "$WORLD/log/mail.log" "$WORLD/log/forge.log" 2>/dev/null)"
rm "$state/ledger.jsonl"; S="$(sm)"; contains "empty ledger: (none) rows, exit 0" "$S" "| (none) |"
new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 real-defect)"; runq
cp "$state/summary.md" "$WORLD/sum.run"; gm summary --now "$NOW" >/dev/null 2>&1
check "the summary a run writes equals the one summary writes" "$(cat "$WORLD/sum.run")" "$(cat "$state/summary.md")"

printf '\n== R6.16 publish ==\n'
new; mkdue "$sha_present" 1; rcfg "publish_cmd: [$top/bin/argvlog, publish]
notify_cmd: [$top/bin/argvlog, notify]"; vfile 1 "$(fnd F1 real-defect)"; runq; rc=$?
check "success: called once, summary path last, file existed" "$state/summary.md 1" "$(sed -n 1p "$WORLD/log/publish.args") $(grep -c -- '--end--' "$WORLD/log/publish.args")"
if [[ -s "$WORLD/published.md" ]]; then ok "  the summary existed when it ran"; else no "  the summary existed when it ran"; fi
new; mkdue "$sha_present" 1; rcfg "publish_cmd: [$top/bin/argvlog, publish]
notify_cmd: [$top/bin/argvlog, notify]"; vfile 1 "$(fnd F1 real-defect)"; touch "$WORLD/fail-publish"
gm run --now "$NOW" >/dev/null 2>"$WORLD/err"; rc=$?
check "publish fails: exit 1" 1 "$rc"; contains "  reported" "$(cat "$WORLD/err")" "publish_cmd failed"
check "  notify still called, ledger intact" "1 2" "$(grep -c -- '--end--' "$WORLD/log/notify.args") $(wc -l < "$state/ledger.jsonl")"
new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 real-defect)"; gm run --now "$NOW" >/dev/null 2>&1; check "unset: exit 0" 0 "$?"
gm summary --now "$NOW" >/dev/null 2>&1
new; mkdue "$sha_present" 1; rcfg "publish_cmd: [$top/bin/argvlog, publish]"; vfile 1; gm summary --now "$NOW" >/dev/null 2>&1
if [[ ! -e "$WORLD/log/publish.args" ]]; then ok "the summary subcommand does not publish"; else no "the summary subcommand does not publish"; fi

printf '\n== R6.17 notification ==\n'
new; mkdue "$sha_present" 1 2; rcfg "notify_cmd: [$top/bin/argvlog, notify]"
vfile 1 "$(fnd F1 real-defect high 'first
line two')" "$(fnd F2 nit)"
vfile 2 "$(fnd F1 real-defect medium)" "$(fnd general real-defect low 'no item')" "$(fnd F2 design-disagreement)"
runq
check "one call for the run" 1 "$(grep -c -- '--end--' "$WORLD/log/notify.args")"
in="$(grep -v '^---$' "$WORLD/log/notify.stdin")"
check "stdin is exactly three lines" 3 "$(wc -l <<<"$in")"
check "  a multi-line claim is on one line, with severity, owner, coverage, URL" "PR #1 [high] owner=human coverage=missed: first line two https://example.com/c/11" "$(sed -n 1p <<<"$in")"
check "  an unmapped item shows -" "PR #2 [low] owner=human coverage=missed: no item -" "$(grep 'no item' <<<"$in")"
: > "$WORLD/log/notify.stdin"; rm -f "$WORLD/log/notify.args"
if gm run --now "$NOW" >/dev/null 2>&1; [[ ! -e "$WORLD/log/notify.args" ]]; then ok "the next run, nothing new: no call"; else no "the next run, nothing new: no call"; fi
new; mkdue "$sha_present" 1; rcfg "notify_cmd: [$top/bin/argvlog, notify]"; vfile 1 "$(fnd F1 nit)" ; runq
if [[ ! -e "$WORLD/log/notify.args" ]]; then ok "no real defect: no call"; else no "no real defect: no call"; fi
new; rcfg "notify_cmd: [$top/bin/argvlog, notify]"; mkdue "$sha_present" 1; rm "$WORLD/py-none" 2>/dev/null; py "w = World(); w.base(sha='$sha_present'); w.save()"; runq
if [[ ! -e "$WORLD/log/notify.args" ]]; then ok "a run that launches nothing: no call"; else no "a run that launches nothing: no call"; fi
new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 real-defect)"; gm run --now "$NOW" >/dev/null 2>&1; check "notify_cmd unset with a new real defect: exit 0" 0 "$?"
new; mkdue "$sha_present" 1; rcfg "notify_cmd: [$top/bin/argvlog, notify]"; vfile 1 "$(fnd F1 real-defect)"; touch "$WORLD/fail-notify"
gm run --now "$NOW" >/dev/null 2>"$WORLD/err"; rc=$?
check "notify fails: exit 1" 1 "$rc"; contains "  reported" "$(cat "$WORLD/err")" "notify_cmd failed"; check "  ledger intact" 2 "$(wc -l < "$state/ledger.jsonl")"

printf '\n== R6.18 exit status ==\n'
new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 nit)"; gm run --now "$NOW" >/dev/null 2>&1; check "everything succeeds: 0" 0 "$?"
gm run --now "$NOW" >/dev/null 2>&1; check "nothing due: 0" 0 "$?"
new; mkdue "$sha_present" 1 2; rcfg; vfile 1 "$(fnd F1 nit)"; vfile 2 "$(fnd F1 nit)"
gm scan --now "$NOW" >/dev/null 2>&1; touch "$WORLD/forge/2/fail-reviews.json"; py "w = World(); w.base(pr=1, so='so1', tid='t1', sha='$sha_present'); w.comment(1, 11, OLD, 'bob', LONG + ' pr1'); w.comment(1, 12, OLD, 'bob', LONG + ' new'); w.save()"
rm -f "$WORLD/forge/1/fail-"* ; touch "$WORLD/forge/2/fail-reviews.json"
gm run --now "$NOW" >"$WORLD/out" 2>"$WORLD/err"; rc=$?
check "a forge fetch fails while another window is judged: exit 1" 1 "$rc"
check "  the judged window's records are in the ledger" "1:so1" "$(recs window | jq -r '.window' | sort -u | head -1)"
if [[ -s "$state/summary.md" ]]; then ok "  the summary is written"; else no "  the summary is written"; fi
contains "  the fetch failure is the last thing on stderr" "$(tail -1 "$WORLD/err")" "forge"
new; mkdue "$sha_present" 1; rcfg; vfile 1; echo nofile > "$WORLD/mode"; runq; runq
gm run --now "$NOW" >/dev/null 2>&1; check "only an already failed window: 0" 0 "$?"

# ======================= interrupted and partial runs ===========================
printf '\n== R6.19 an interrupted run ==\n'
for sig in TERM INT; do
    new; mkdue "$sha_present" 1 2; rcfg "notify_cmd: [$top/bin/argvlog, notify]" "  concurrency: 1"
    vfile 1 "$(fnd F1 real-defect)"; vfile 2 "$(fnd F1 nit)"; echo term-parent > "$WORLD/mode-2"; echo "$sig" > "$WORLD/term-sig"
    PATH="$top/bin:$PATH" timeout 60 python3 "$gm_script" run --now "$NOW" >"$WORLD/out" 2>"$WORLD/err"; rc=$?
    check "SIG$sig: exit 1" 1 "$rc"
    pid="$(cat "$WORLD/term.pid" 2>/dev/null)"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then ok "SIG$sig: the blocking launcher is gone"; else no "SIG$sig: the blocking launcher is gone" "pid=$pid"; fi
    check "SIG$sig: the finished window is recorded, the interrupted one is not" "1:so1" "$(recs window | jq -r .window | sort -u)"
    check "SIG$sig: notify called once" 1 "$(grep -c -- '--end--' "$WORLD/log/notify.args")"
    if [[ -s "$state/summary.md" ]]; then ok "SIG$sig: summary written"; else no "SIG$sig: summary written"; fi
    first_branch="$(grep -o -- '--branch [^ ]*' "$WORLD/log/sandbox.log" | tail -1)"
    echo ok > "$WORLD/mode-2"; : > "$WORLD/log/sandbox.log"; runq
    check "SIG$sig: the next run launches the interrupted window as attempt 1" "1 1" "$(launches) $(recs window | tail -1 | jq -r .attempt)"
    if [[ "$(grep -o -- '--branch [^ ]*' "$WORLD/log/sandbox.log")" != "$first_branch" ]]; then ok "SIG$sig: with a different --branch"; else no "SIG$sig: with a different --branch"; fi
done

printf '\n== R6.20 a torn ledger ==\n'
new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 nit)"; mkdir -p "$state"; printf '{"schema":1,"kind":"win' > "$state/ledger.jsonl"
runq
check "records after the torn line all parse" 2 "$(tail -n +2 "$state/ledger.jsonl" | jq -c . | wc -l)"
out="$(gm scan --now "$NOW" 2>"$WORLD/err")"; contains "  scan prints judged" "$out" judged
check "  and warns about one line only" 1 "$(grep -c 'line' "$WORLD/err")"

printf '\n== R6.21 a stale staging directory ==\n'
new; mkdue "$sha_present" 1; rcfg; vfile 1 "$(fnd F1 nit)"
mkdir -p "$WORLD/scratch/1-so1-a1/evidence"; echo stray > "$WORLD/scratch/1-so1-a1/evidence/stray.txt"; echo "stale handoff" > "$WORLD/scratch/1-so1-a1/handoff.md"
runq
if [[ ! -e "$WORLD/scratch/1-so1-a1/evidence/stray.txt" ]]; then ok "the stray file is gone from the attach dir"; else no "the stray file is gone from the attach dir"; fi
contains "  the handoff is the new one" "$(cat "$WORLD/scratch/1-so1-a1/handoff.md")" "Judge the feedback"

# ======================= docs and units =========================================
printf '\n== R8.1 user units ==\n'
svc="$(cat "$repo_dir/contrib/systemd/lkml-gap-monitor.service")"; tmr="$(cat "$repo_dir/contrib/systemd/lkml-gap-monitor.timer")"
contains "service is oneshot" "$svc" "Type=oneshot"
check "ExecStart ends with 'lkml-gap-monitor.py run'" 1 "$(grep -c '^ExecStart=.*lkml-gap-monitor\.py run$' <<<"$svc")"
contains "timer: OnCalendar=daily" "$tmr" "OnCalendar=daily"; contains "timer: Persistent=true" "$tmr" "Persistent=true"
contains "timer: WantedBy=timers.target" "$tmr" "WantedBy=timers.target"
for f in "$svc" "$tmr"; do lacks "no /home/ in a unit" "$f" "/home/"; lacks "no User= in a unit" "$f" "User="; done
lacks "install.sh does not install the units" "$(cat "$repo_dir/install.sh")" "contrib"

printf '\n== R8.2 docs and the README pointer ==\n'
doc_md="$(cat "$repo_dir/docs/gap-monitor.md")"
for k in repo checkout state_dir mail_cmd forge_cmd judge.model judge.harness judge.concurrency judge.wait_timeout judge.max_attempts judge.run_args sha_fetch_cmd bot_markers exclude_tier_reason xref_pattern quiet_hours lookback_days notify_cmd publish_cmd LKML_GAP_MONITOR_FILE; do
    contains "docs name $k" "$doc_md" "\`$k\`"
done
for c in due waiting judged author-only xref-only empty blocked failed; do contains "docs name class $c" "$doc_md" "\`$c\`"; done
for k in finding window integration judged judge-failed sha-unavailable; do contains "docs name $k" "$doc_md" "\`$k\`"; done
contains "docs show systemctl --user" "$doc_md" "systemctl --user"
check "README: exactly one line names the tool" 1 "$(grep -c 'lkml-gap-monitor' "$repo_dir/README.md")"
contains "  and it points to the doc" "$(grep 'lkml-gap-monitor' "$repo_dir/README.md")" "docs/gap-monitor.md"
printf "\n%d passed, %d failed\n" "$pass" "$fail"
[[ "$fail" -eq 0 ]]
