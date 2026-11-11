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

    def comment(self, n, id, at, user, body, utype=None):
        self._p(n)["issue-comments"].append({"id": id, "created_at": at, "updated_at": at,
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
echo "$*" >> "$WORLD/log/sandbox.log"
case "$1" in
mail) shift; [[ "${1:-}" == --remote ]] && shift; exec "$(dirname "$0")/mailstub" "$@" ;;
esac
exit 64
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
printf "\n%d passed, %d failed\n" "$pass" "$fail"
[[ "$fail" -eq 0 ]]
