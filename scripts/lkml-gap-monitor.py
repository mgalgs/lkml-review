#!/usr/bin/env python3
"""lkml-gap-monitor.py — judge the feedback a pull request drew after its
review panel signed off, and keep a ledger of what that shows.

Usage: lkml-gap-monitor.py scan [--json] [--no-fetch] [--now <ISO-8601>]
       lkml-gap-monitor.py run [--no-fetch] [--max-judges N] [--now <ISO-8601>]
       lkml-gap-monitor.py summary [--now <ISO-8601>]
       lkml-gap-monitor.py -h|--help

A panel signs off on a pull request; afterwards people and other review
agents still comment. Every real defect found after the sign-off is a gap
in the panel. A comment proves nothing, so each piece of feedback is
judged by a strong model in a checkout of the exact tree the panel signed
off on, and only the verdict counts. A daily timer can run `run`.

  scan     fetch, build one window per sign-off and print one line per
           window inside the lookback, tab separated:
               <pr>:<sign-off message id> <class> <why>
           --json prints one object (windows, excluded, skipped,
           fetch_failures). Launches nothing; writes only the fetch cache.
  run      scan, then judge every due window (--max-judges N caps one
           run, oldest sign-off first), append the verdicts to the ledger,
           tally the integrator's notes, regenerate the summary, run
           publish_cmd, and run notify_cmd once if a new real defect
           landed.
  summary  regenerate summary.md from the ledger alone.
  --no-fetch  on scan and run: use what the state directory already holds.
  --now    the clock for every decision and timestamp (tests, replays).

Classes: due (an unjudged trigger, quiet period over), waiting (trigger,
quiet period not over), judged (nothing new since the last judging),
author-only, xref-only (cross-references, none passing the rule), empty,
blocked (the reviewed sha could not be had), failed (attempts used up).

Configuration is read from ~/.config/lkml/gap-monitor.yaml, or from the
file named by LKML_GAP_MONITOR_FILE. There is no fallback location: a
missing file is an error that names the path, and an unknown key is an
error. Keys:

    repo                forge slug, owner/name (required)
    checkout            local clone of the reviewed repository (run)
    state_dir           default ${XDG_STATE_HOME:-~/.local/state}/lkml/gap-monitor
    mail_cmd            default "fork-sandbox mail --remote"
    forge_cmd           default "gh api"; only GET paths are passed, with
                        at most --paginate --slurp before the path
    judge:              model (required by run), harness (claude),
                        concurrency (2), wait_timeout (7200),
                        max_attempts (2), run_args []  (local runs only)
    sha_fetch_cmd       run as: <cmd> <pr> <sha> <SIGNED-OFF|RESPIN>, cwd
                        the checkout, when the sha is still missing
    bot_markers         extra substrings that mark a body as automation
    exclude_tier_reason regex; a pull request with a matching thread is
                        skipped whole
    xref_pattern        regex overriding the fix/bug-report pattern
    quiet_hours (6), lookback_days (14)
    notify_cmd          gets one line per new real defect on stdin
    publish_cmd         run with the summary path appended

Commands are argv lists, or strings split with shlex; none is run through
a shell.

What counts. A sign-off is a message from the thread's secretary whose
trailing Panel-* lines say Panel-Status: CONVERGED and Panel-Verdict:
SIGNED-OFF or RESPIN; the reviewed sha is the last token of its
X-Review-Target header. A window runs from one sign-off to the pull
request's next one (any thread), or to now; feedback belongs to the
latest sign-off before it. A trigger is a review body, inline comment or
issue comment from someone other than the pull request's author that is
not automation, not an integration note and not trivial, or a later
issue or pull request citing this one that reads as a fix or bug report.
A window is due once its newest non-automation item is older than
quiet_hours. Integration notes (<!-- lkml-integration: <series> v<N> -->)
are counted per panel commit (take, take with changes, drop), never
judged.

State. <state_dir>/ledger.jsonl is the only state: append-only JSON
lines, "schema": 1, kind finding | window | integration. An item is
judged when a window record with status judged lists it; deleting lines
forces a re-judge. A failed judge (no parseable verdicts.json with a
findings list, whatever the exit status) leaves no verdict and is retried
until judge.max_attempts. threads/ and forge/ are the fetch cache and
summary.md the report. Evidence and handoffs are staged under
${LKML_GAP_MONITOR_SCRATCH_DIR:-/var/tmp/claude-scratch/lkml-gap-monitor},
because fork-sandbox only binds attachments from there. The template is
fleet/prompts/gap-judge.md beside this script's repository.

Exit status: 0 the run did everything it set out to; 1 a fetch, judge,
publish or notification failed, a window is blocked, or another run holds
the lock (the work that could be done is still done and recorded); 2 a
usage or configuration error.
"""

import datetime as dt
import fcntl
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from email.utils import parsedate_to_datetime

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "Error: the gap monitor's config is YAML, and parsing it needs the\n"
        "PyYAML python module, which this machine does not have. Install it\n"
        "(commonly packaged as python-yaml or python3-yaml).\n"
    )
    sys.exit(2)

TOP_KEYS = ("repo", "checkout", "state_dir", "mail_cmd", "forge_cmd", "judge",
            "sha_fetch_cmd", "bot_markers", "exclude_tier_reason",
            "xref_pattern", "quiet_hours", "lookback_days", "notify_cmd",
            "publish_cmd")
JUDGE_KEYS = ("model", "harness", "concurrency", "wait_timeout",
              "max_attempts", "run_args")

DEFAULT_XREF = (r"\b(fix(es|ed)?|bug|regress(ion|ed|es)?|revert(s|ed)?|"
                r"broke(n)?|crash(es|ed)?|incorrect|wrong(ly)?|hotfix|"
                r"follow[- ]?ups?|missed)\b")
TRIVIAL = re.compile(
    r"^\s*(lgtm|looks good( to me)?|thanks?|thank you|done|fixed|ack|nice|"
    r"\+1|approved?|:\w+:|/[\w-]+(\s.*)?)?[\s.!]*$", re.I)
BUILTIN_MARKERS = ("<!-- lkml-state", "<!-- lkml-panel", "<!-- lkml-notice")
EVENT_KINDS = ("head_ref_force_pushed", "merged", "closed", "reopened")
FLOOR = 40
HEX40 = re.compile(r"[0-9a-f]{40}")
TRAILER_LINE = re.compile(r"^Panel-([A-Za-z-]+):[ \t]*(.*?)[ \t]*$")
STATUS_LINE = re.compile(r"^Panel-Status:[ \t]*CONVERGED[ \t]*$")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class UsageError(Exception):
    pass


class ConfigError(Exception):
    pass


class InputError(Exception):
    pass


def warn(msg):
    sys.stderr.write(f"Warning: {msg}\n")


# ---- time -------------------------------------------------------------------

def parse_when(text):
    """A mail Date (RFC 2822) or an ISO-8601 stamp -> an aware UTC datetime,
    or None. A stamp with no zone is read as UTC."""
    if not isinstance(text, str) or not text.strip():
        return None
    text = text.strip()
    try:
        when = parsedate_to_datetime(text)
    except (TypeError, ValueError, IndexError):
        iso = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
        try:
            when = dt.datetime.fromisoformat(iso)
        except ValueError:
            return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=dt.timezone.utc)
    return when.astimezone(dt.timezone.utc)


def stamp(when):
    return when.strftime("%Y-%m-%dT%H:%M:%SZ") if when else None


# ---- configuration ------------------------------------------------------------

class DupKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses duplicate mapping keys (duplicated, not
    sourced, from lkml-seats-parse.py)."""


def _no_dup_mapping(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise ConfigError(f"duplicate key '{key}' "
                              f"(line {key_node.start_mark.line + 1})")
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


DupKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup_mapping)


def config_path():
    return (os.environ.get("LKML_GAP_MONITOR_FILE")
            or os.path.join(os.path.expanduser("~"), ".config", "lkml",
                            "gap-monitor.yaml"))


def want_cmd(value, key):
    if isinstance(value, str):
        try:
            argv = shlex.split(value)
        except ValueError as e:
            raise ConfigError(f"{key}: {e}")
    elif isinstance(value, list) and all(isinstance(x, str) for x in value):
        argv = list(value)
    else:
        raise ConfigError(f"{key} must be a command string or a list of strings")
    if not argv:
        raise ConfigError(f"{key} must not be empty")
    return argv


def want_int(value, key, minimum=1):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ConfigError(f"{key} must be an integer >= {minimum}")
    return value


def want_list(value, key):
    if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
        raise ConfigError(f"{key} must be a list of strings")
    return value


def want_str(value, key):
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{key} must be a non-empty string")
    return value


def want_regex(value, key, flags=0):
    want_str(value, key)
    try:
        return re.compile(value, flags)
    except re.error as e:
        raise ConfigError(f"{key} is not a valid regular expression: {e}")


def load_config():
    path = config_path()
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        raise ConfigError(f"config file not found: {path} "
                          "(set LKML_GAP_MONITOR_FILE to use another)")
    try:
        raw = yaml.load(text, Loader=DupKeyLoader)
    except yaml.YAMLError as e:
        raise ConfigError(f"{path}: {e}")
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise ConfigError(f"{path}: top level must be a mapping")
    for k in raw:
        if k not in TOP_KEYS:
            raise ConfigError(f"{path}: unknown key '{k}'")
    judge = raw.get("judge") or {}
    if not isinstance(judge, dict):
        raise ConfigError("judge must be a mapping")
    for k in judge:
        if k not in JUDGE_KEYS:
            raise ConfigError(f"{path}: unknown key 'judge.{k}'")

    cfg = {"path": path}
    repo = raw.get("repo")
    if not isinstance(repo, str) or not re.fullmatch(r"[^/\s]+/[^/\s]+", repo):
        raise ConfigError("repo is required and must look like owner/name")
    cfg["repo"] = repo
    cfg["checkout"] = (os.path.expanduser(want_str(raw["checkout"], "checkout"))
                       if "checkout" in raw else None)
    if "state_dir" in raw:
        cfg["state_dir"] = os.path.expanduser(want_str(raw["state_dir"], "state_dir"))
    else:
        base = (os.environ.get("XDG_STATE_HOME")
                or os.path.join(os.path.expanduser("~"), ".local", "state"))
        cfg["state_dir"] = os.path.join(base, "lkml", "gap-monitor")
    cfg["mail_cmd"] = want_cmd(raw.get("mail_cmd", "fork-sandbox mail --remote"),
                               "mail_cmd")
    cfg["forge_cmd"] = want_cmd(raw.get("forge_cmd", "gh api"), "forge_cmd")
    for k in ("sha_fetch_cmd", "notify_cmd", "publish_cmd"):
        cfg[k] = want_cmd(raw[k], k) if k in raw else None
    cfg["bot_markers"] = want_list(raw.get("bot_markers", []), "bot_markers")
    cfg["exclude_tier_reason"] = (want_regex(raw["exclude_tier_reason"],
                                             "exclude_tier_reason")
                                  if "exclude_tier_reason" in raw else None)
    cfg["xref_pattern"] = want_regex(raw.get("xref_pattern", DEFAULT_XREF),
                                     "xref_pattern", re.I)
    qh = raw.get("quiet_hours", 6)
    if isinstance(qh, bool) or not isinstance(qh, (int, float)) or qh < 0:
        raise ConfigError("quiet_hours must be a number >= 0")
    cfg["quiet_hours"] = qh
    cfg["lookback_days"] = want_int(raw.get("lookback_days", 14), "lookback_days")
    j = {}
    j["model"] = want_str(judge["model"], "judge.model") if "model" in judge else None
    j["harness"] = want_str(judge.get("harness", "claude"), "judge.harness")
    j["concurrency"] = want_int(judge.get("concurrency", 2), "judge.concurrency")
    j["wait_timeout"] = want_int(judge.get("wait_timeout", 7200), "judge.wait_timeout")
    j["max_attempts"] = want_int(judge.get("max_attempts", 2), "judge.max_attempts")
    j["run_args"] = want_list(judge.get("run_args", []), "judge.run_args")
    cfg["judge"] = j
    return cfg


# ---- subprocess -----------------------------------------------------------------

def run_cmd(argv, cwd=None, stdin_text=None):
    """Run an argv list (never a shell). Returns (returncode, stdout, stderr);
    a command that cannot start is returncode 127."""
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True,
                           input=stdin_text.encode() if stdin_text is not None else None,
                           stdin=None if stdin_text is not None else subprocess.DEVNULL)
    except OSError as e:
        return 127, "", f"cannot run {argv[0]}: {e}"
    return (p.returncode, p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"))


def last_line(text):
    lines = [x for x in text.strip().splitlines() if x.strip()]
    return lines[-1] if lines else ""


# ---- fetching -------------------------------------------------------------------

FORGE_FILES = (  # name, path suffix, paginated
    ("pr.json", "", False),
    ("reviews.json", "/reviews?per_page=100", True),
    ("review-comments.json", "/comments?per_page=100", True),
    ("issue-comments.json", "/comments?per_page=100", True),
    ("commits.json", "/commits?per_page=100", True),
    ("timeline.json", "/timeline?per_page=100", True),
)


def forge_path(repo, pr, name, suffix):
    seg = "issues" if name in ("issue-comments.json", "timeline.json") else "pulls"
    return f"repos/{repo}/{seg}/{pr}{suffix}"


def atomic_write(path, text):
    d, base = os.path.split(path)
    tmp = os.path.join(d, f".{base}.tmp.{os.getpid()}")
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def sweep_temp(directory):
    """Remove dot-prefixed temp files a killed run left, once a day old."""
    try:
        names = os.listdir(directory)
    except OSError:
        return
    for n in names:
        p = os.path.join(directory, n)
        if n.startswith(".") and os.path.isfile(p):
            try:
                if time.time() - os.path.getmtime(p) > 86400:
                    os.unlink(p)
            except OSError:
                pass


def fetch_threads(cfg, failures):
    tdir = os.path.join(cfg["state_dir"], "threads")
    os.makedirs(tdir, exist_ok=True)
    sweep_temp(tdir)
    rc, out, err = run_cmd(cfg["mail_cmd"] + ["list", "--json"])
    if rc != 0:
        failures.append(f"mail list failed (exit {rc}): {last_line(err)}")
        return
    try:
        listing = json.loads(out)
        if not isinstance(listing, list):
            raise ValueError("not a list")
    except ValueError as e:
        failures.append(f"mail list printed no JSON list: {e}")
        return
    for t in listing:
        if not isinstance(t, dict):
            continue
        tid = t.get("thread")
        heads = t.get("root_headers") or []
        pr = None
        for pair in heads:
            if isinstance(pair, (list, tuple)) and len(pair) == 2 and pair[0] == "X-Preview-PR":
                pr = str(pair[1]).strip()
                break
        if pr is None or not pr.isdigit():
            continue
        if not isinstance(tid, str) or not SAFE_ID.match(tid):
            failures.append(f"mail list: unusable thread id {tid!r}")
            continue
        path = os.path.join(tdir, f"{tid}.json")
        try:
            with open(path, encoding="utf-8") as f:
                cached = json.load(f)
            if (cached.get("messages") == t.get("messages")
                    and cached.get("last_date") == t.get("last_date")):
                continue
        except (OSError, ValueError, AttributeError):
            pass
        rc, out, err = run_cmd(cfg["mail_cmd"] + ["export", tid, "--json"])
        if rc != 0:
            failures.append(f"mail export {tid} failed (exit {rc}): {last_line(err)}")
            continue
        try:
            exp = json.loads(out)
            if not isinstance(exp, dict) or not isinstance(exp.get("messages"), list):
                raise ValueError("no messages list")
        except ValueError as e:
            failures.append(f"mail export {tid} printed unusable JSON: {e}")
            continue
        atomic_write(path, json.dumps({"messages": t.get("messages"),
                                       "last_date": t.get("last_date"),
                                       "export": exp}))


def fetch_forge(cfg, pr, failures):
    d = os.path.join(cfg["state_dir"], "forge", str(pr))
    os.makedirs(d, exist_ok=True)
    sweep_temp(d)
    for name, suffix, paginated in FORGE_FILES:
        path = forge_path(cfg["repo"], pr, name, suffix)
        argv = cfg["forge_cmd"] + (["--paginate", "--slurp"] if paginated else []) + [path]
        rc, out, err = run_cmd(argv)
        if rc != 0:
            failures.append(f"forge {path} failed (exit {rc}): {last_line(err)}")
            continue
        try:
            data = json.loads(out)
            if paginated != isinstance(data, list) or (not paginated and not isinstance(data, dict)):
                raise ValueError("unexpected JSON shape")
        except ValueError as e:
            failures.append(f"forge {path} printed unusable JSON: {e}")
            continue
        atomic_write(os.path.join(d, name), out)


# ---- reading the mail cache ---------------------------------------------------------

def hdr_values(msg, name):
    out = []
    for pair in msg.get("headers") or []:
        if isinstance(pair, (list, tuple)) and len(pair) == 2 and pair[0] == name:
            out.append(str(pair[1]))
    return out


def hdr_first(msg, name):
    v = hdr_values(msg, name)
    return v[0] if v else None


def trailing_panel_block(body):
    """The Panel-* lines that are the last non-empty lines of body, as
    (dict, index of the first such line in the line list)."""
    lines = body.splitlines()
    end = len(lines)
    while end > 0 and not lines[end - 1].strip():
        end -= 1
    start = end
    while start > 0 and TRAILER_LINE.match(lines[start - 1]):
        start -= 1
    block = {}
    for ln in lines[start:end]:
        m = TRAILER_LINE.match(ln)
        block[m.group(1)] = m.group(2)
    return block, start, lines


def parse_thread(cached, path, cfg):
    """One cached thread -> {thread, pr, tier, ..., signoffs}, or None."""
    exp = cached.get("export") or {}
    msgs = exp.get("messages") or []
    if not msgs or not isinstance(msgs[0], dict):
        return None
    root = msgs[0]
    pr = (hdr_first(root, "X-Preview-PR") or "").strip()
    if not pr.isdigit():
        return None
    tid = exp.get("thread") or os.path.basename(path)[:-5]
    body0 = root.get("body") or ""
    m = re.search(r"^Secretary:[ \t]*(\S.*?)[ \t]*$", body0, re.M)
    secretary = m.group(1) if m else "@secretary"
    th = {
        "thread": tid, "pr": int(pr),
        "tier": (hdr_first(root, "X-Lkml-Tier") or "").strip() or "untiered",
        "tier_reason": hdr_first(root, "X-Lkml-Tier-Reason") or "",
        "started": parse_when(root.get("date")),
        "child": bool(hdr_values(root, "X-Lkml-Parent-Thread")),
        "messages": msgs, "signoffs": [],
    }
    for m in msgs:
        if not isinstance(m, dict) or (m.get("from") or "").strip() != secretary:
            continue
        block, start, lines = trailing_panel_block(m.get("body") or "")
        so = (block.get("Status") == "CONVERGED"
              and block.get("Verdict") in ("SIGNED-OFF", "RESPIN"))
        if not so:
            if any(STATUS_LINE.match(x) for x in lines[:start]):
                warn(f"thread {tid} message {m.get('id')}: an unquoted "
                     "'Panel-Status: CONVERGED' line is not in the trailing "
                     "block, so this message is not counted as a sign-off")
            continue
        if th["child"]:
            continue
        at = parse_when(m.get("date"))
        if at is None:
            warn(f"thread {tid} message {m.get('id')}: sign-off with no usable Date")
            continue
        targets = hdr_values(m, "X-Review-Target")
        sha = None
        if len(targets) == 1 and targets[0].split():
            last = targets[0].split()[-1]
            if HEX40.fullmatch(last):
                sha = last
        ver = block.get("Version", "")
        if not ver.isdigit():
            ver = (hdr_first(m, "X-Version") or "").strip()
        th["signoffs"].append({
            "thread": tid, "msg": m.get("id"), "at": at,
            "verdict": block["Verdict"], "version": int(ver) if ver.isdigit() else None,
            "sha": sha, "tier": th["tier"],
        })
    return th


def load_threads(state_dir):
    tdir = os.path.join(state_dir, "threads")
    out = []
    for n in sorted(os.listdir(tdir)):
        if n.startswith(".") or not n.endswith(".json"):
            continue
        p = os.path.join(tdir, n)
        try:
            with open(p, encoding="utf-8") as f:
                cached = json.load(f)
        except (OSError, ValueError) as e:
            warn(f"unreadable cached thread {p}: {e}")
            continue
        out.append((cached, p))
    return out


# ---- forge items ----------------------------------------------------------------------

def flatten(data):
    out = []
    for page in data if isinstance(data, list) else []:
        if isinstance(page, list):
            out.extend(page)
        else:
            out.append(page)
    return out


def read_forge(state_dir, pr):
    """-> (pr.json, {name: flattened list}) or None when the cache is incomplete."""
    d = os.path.join(state_dir, "forge", str(pr))
    files = {}
    try:
        for name, _, paginated in FORGE_FILES:
            with open(os.path.join(d, name), encoding="utf-8") as f:
                data = json.load(f)
            files[name] = flatten(data) if paginated else data
    except (OSError, ValueError):
        return None
    return files.pop("pr.json"), files


def login_of(user):
    return (user or {}).get("login", "") if isinstance(user, dict) else ""


def build_items(files):
    """Every feedback item and context event with a time, oldest first."""
    items, events = [], []

    def add(kind, id_, at, user, body, url, **extra):
        when = parse_when(at)
        if when is None:
            return
        d = {"kind": kind, "id": id_, "at": when, "user": login_of(user),
             "utype": (user or {}).get("type") if isinstance(user, dict) else None,
             "body": body or "", "url": url or ""}
        d.update(extra)
        items.append(d)

    for r in files["reviews.json"]:
        if not r.get("submitted_at"):
            continue
        if not (r.get("body") or "").strip() and r.get("state") != "CHANGES_REQUESTED":
            continue
        add("review", r["id"], r["submitted_at"], r.get("user"), r.get("body"),
            r.get("html_url"), state=r.get("state"), commit=r.get("commit_id"))
    for c in files["review-comments.json"]:
        add("inline", c["id"], c.get("created_at"), c.get("user"), c.get("body"),
            c.get("html_url"), path=c.get("path"),
            line=c.get("line") or c.get("original_line"),
            commit=c.get("original_commit_id"), in_reply_to=c.get("in_reply_to_id"),
            hunk=(c.get("diff_hunk") or "")[-1500:])
    for c in files["issue-comments.json"]:
        add("comment", c["id"], c.get("created_at"), c.get("user"), c.get("body"),
            c.get("html_url"))
    for e in files["timeline.json"]:
        ev = e.get("event")
        if ev == "cross-referenced":
            src = (e.get("source") or {}).get("issue") or {}
            if not src.get("number"):
                continue
            add("xref", src["number"], e.get("created_at"),
                src.get("user") or e.get("actor"), src.get("title"),
                src.get("html_url"), src=src)
        elif ev in EVENT_KINDS:
            when = parse_when(e.get("created_at"))
            if when is not None:
                events.append({"kind": ev, "at": when,
                               "user": login_of(e.get("actor")),
                               "ref": e.get("commit_id") or ""})
    items.sort(key=lambda i: (i["at"], i["kind"], str(i["id"])))
    events.sort(key=lambda e: e["at"])
    return items, events


def is_note(item):
    return item["kind"] != "xref" and item["body"].lstrip().startswith("<!-- lkml-integration:")


def is_automation(item, cfg):
    if item["kind"] == "xref":
        return False
    if is_note(item):
        return False
    if item["utype"] == "Bot" or item["user"].endswith("[bot]"):
        return True
    body = item["body"]
    if body.lstrip().startswith("Mailing list review of "):
        return True
    return any(m in body for m in BUILTIN_MARKERS + tuple(cfg["bot_markers"]))


def is_trivial(item):
    body = item["body"]
    if TRIVIAL.match(body):
        return True
    return item["kind"] in ("review", "comment") and len(body.strip()) < FLOOR


def cites(para, repo, n):
    r = re.escape(repo)
    pats = (rf"(?<![\w/-])#{n}(?!\d)", rf"{r}#{n}(?!\d)",
            rf"{r}/(?:pull|issues)/{n}(?!\d)")
    return any(re.search(p, para, re.I) for p in pats)


def xref_reason(item, cfg, pr, signoff_at):
    """Why a cross-reference reads as a fix or bug report, or None."""
    src = item["src"]
    created = parse_when(src.get("created_at"))
    if created is None or created <= signoff_at or src.get("number") == pr:
        return None
    for lab in src.get("labels") or []:
        if "bug" in str((lab or {}).get("name", "")).lower():
            return "label"
    pat = cfg["xref_pattern"]
    if pat.search(src.get("title") or ""):
        return "title"
    for para in re.split(r"\n\s*\n", src.get("body") or ""):
        if cites(para, cfg["repo"], pr) and pat.search(para):
            return "paragraph"
    return None


# ---- ledger (reading) ---------------------------------------------------------------------

KINDS = ("finding", "window", "integration")


def read_ledger(state_dir):
    """-> list of valid records in file order. A line that is not a JSON
    object with "schema": 1 and a known kind is skipped with a warning."""
    path = os.path.join(state_dir, "ledger.jsonl")
    recs = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
    except OSError:
        return recs
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except ValueError:
            r = None
        if not (isinstance(r, dict) and r.get("schema") == 1 and r.get("kind") in KINDS):
            warn(f"{path} line {n}: not a schema-1 ledger record, skipped")
            continue
        recs.append(r)
    return recs


def window_ledger(recs):
    """window key -> {judged: set, has_judged, fails, newest, attempts}."""
    out = {}
    for r in recs:
        if r["kind"] != "window":
            continue
        w = out.setdefault(r.get("window"), {"judged": set(), "has_judged": False,
                                              "fails": 0, "newest": None})
        st = r.get("status")
        w["newest"] = st
        if st == "judged":
            w["has_judged"] = True
            w["fails"] = 0
            w["judged"].update(x for x in r.get("items") or [] if isinstance(x, str))
        elif st == "judge-failed":
            w["fails"] += 1
    return out


# ---- windows ---------------------------------------------------------------------------------

def build_model(cfg, now, fetch_failures):
    """Cached state -> (windows, excluded, skipped). Windows inside the
    lookback only, each carrying its items; classification is separate."""
    state = cfg["state_dir"]
    by_pr = {}
    for cached, path in load_threads(state):
        th = parse_thread(cached, path, cfg)
        if th:
            by_pr.setdefault(th["pr"], []).append(th)
    excluded = []
    pats = cfg["exclude_tier_reason"]
    horizon = now - dt.timedelta(days=cfg["lookback_days"])
    raw = []  # (pr, [signoff...], threads)
    for pr in sorted(by_pr):
        ths = sorted(by_pr[pr], key=lambda t: (t["started"] or now, t["thread"]))
        hit = [t for t in ths if pats and pats.search(t["tier_reason"])]
        if hit:
            for t in hit:
                excluded.append({"pr": pr, "thread": t["thread"],
                                 "reason": t["tier_reason"]})
            continue
        sos = sorted((s for t in ths for s in t["signoffs"]),
                     key=lambda s: (s["at"], s["msg"] or ""))
        if any(s["at"] >= horizon for s in sos):
            raw.append((pr, sos, ths))
    return raw, excluded


def assemble(cfg, now, raw, fetch_failures):
    windows, skipped = [], []
    horizon = now - dt.timedelta(days=cfg["lookback_days"])
    for pr, sos, ths in raw:
        forge = read_forge(cfg["state_dir"], pr)
        if forge is None:
            for s in sos:
                if s["at"] >= horizon:
                    skipped.append({"window": f"{pr}:{s['msg']}",
                                    "reason": "no forge activity cached for this pull request"})
            continue
        prj, files = forge
        items, events = build_items(files)
        author = login_of(prj.get("user"))
        for i, s in enumerate(sos):
            if s["at"] < horizon:
                continue
            end = sos[i + 1]["at"] if i + 1 < len(sos) else None
            win = {"window": f"{pr}:{s['msg']}", "pr": pr, "signoff": s,
                   "until": end, "author": author, "prj": prj, "threads": ths,
                   "files": files, "all_items": items, "events": [], "items": []}
            seen_x = set()
            for it in items:
                if it["at"] <= s["at"] or (end is not None and it["at"] > end):
                    continue
                if it["kind"] == "xref":
                    if it["id"] == pr or it["id"] in seen_x:
                        continue
                    seen_x.add(it["id"])
                    it["reason"] = xref_reason(it, cfg, pr, s["at"])
                win["items"].append(it)
            for ev in events:
                if ev["at"] > s["at"] and (end is None or ev["at"] <= end):
                    win["events"].append(ev)
            windows.append(win)
    windows.sort(key=lambda w: (w["signoff"]["at"], w["window"]))
    return windows, skipped


def annotate(win, cfg):
    """Fill the per-item predicates; return nothing."""
    for it in win["items"]:
        it["auto"] = is_automation(it, cfg)
        it["note"] = is_note(it)
        it["author"] = it["kind"] != "xref" and it["user"] == win["author"]
        it["trivial"] = it["kind"] != "xref" and is_trivial(it)
        if it["kind"] == "xref":
            it["trigger"] = bool(it.get("reason"))
        else:
            it["trigger"] = not (it["auto"] or it["note"] or it["author"] or it["trivial"])
        it["key"] = f"{it['kind']}:{it['id']}"


def classify(win, cfg, led, now):
    items = win["items"]
    lw = led.get(win["window"]) or {"judged": set(), "has_judged": False,
                                    "fails": 0, "newest": None}
    judged = lw["judged"]
    trig = [i for i in items if i["trigger"] and i["key"] not in judged]
    live = [i for i in items if not i["auto"]]
    newest = max((i["at"] for i in live), default=None)
    due_at = newest + dt.timedelta(hours=cfg["quiet_hours"]) if newest else None
    counts = {
        "items": len(items),
        "automation": sum(1 for i in items if i["auto"]),
        "events": len(win["events"]),
        "author": sum(1 for i in live if i["author"] and not i["note"]),
        "integration_notes": sum(1 for i in items if i["note"]),
        "trivial": sum(1 for i in live if i["trivial"] and not i["note"]),
        "xrefs": sum(1 for i in items if i["kind"] == "xref"),
        "xrefs_passing": sum(1 for i in items if i["kind"] == "xref" and i["trigger"]),
        "judged": sum(1 for i in items if i["key"] in judged),
        "unjudged": sum(1 for i in live if i["key"] not in judged),
    }
    summary = ", ".join(f"{k} {v}" for k, v in counts.items() if v) or "nothing"
    tdesc = "; ".join(
        f"{t['key']} ({t['user'] or '?'}" + (f", {t['reason']}" if t["kind"] == "xref" else "") + ")"
        for t in trig)
    if trig:
        if lw["fails"] >= cfg["judge"]["max_attempts"]:
            cls, why = "failed", f"{lw['fails']} judging attempts failed; unjudged: {tdesc}"
        elif now <= due_at:
            cls, why = "waiting", f"quiet period ends {stamp(due_at)}; unjudged: {tdesc}"
        elif lw["newest"] == "sha-unavailable":
            cls, why = "blocked", f"reviewed sha not available; unjudged: {tdesc}"
        else:
            cls, why = "due", f"unjudged: {tdesc}"
    elif lw["has_judged"]:
        cls, why = "judged", f"nothing new since the last judging ({summary})"
    elif counts["xrefs"]:
        cls, why = "xref-only", f"cross-references, none passing the rule ({summary})"
    elif counts["author"]:
        cls, why = "author-only", f"only the author's own comments ({summary})"
    else:
        cls, why = "empty", f"nothing that could trigger ({summary})"
    s = win["signoff"]
    return {
        "window": win["window"], "pr": win["pr"], "thread": s["thread"],
        "signoff_msg": s["msg"], "signoff_at": stamp(s["at"]),
        "signoff_verdict": s["verdict"], "version": s["version"],
        "tier": s["tier"], "reviewed_sha": s["sha"], "until": stamp(win["until"]),
        "class": cls, "why": why,
        "triggers": [{"kind": t["kind"], "id": t["id"], "url": t["url"],
                      "user": t["user"], "at": stamp(t["at"]),
                      "reason": t.get("reason")} for t in trig],
        "counts": counts, "newest_item_at": stamp(newest), "due_at": stamp(due_at),
        "attempts": lw["fails"],
    }


# ---- the ledger (writing) -------------------------------------------------------------

JUDGE_FIELDS = ("claim", "verdict", "severity", "true_at_head", "how_checked",
                "evidence", "failure_scenario", "panel_coverage", "panel_refs",
                "code_owner", "blame", "gap", "seat", "seat_on_roster",
                "confidence", "duplicate_of")


def append_records(state_dir, recs):
    """Append one batch in a single write, then fsync. A file that does
    not end in a newline (an earlier torn append) gets one first, so the
    batch is never glued to a half line."""
    path = os.path.join(state_dir, "ledger.jsonl")
    os.makedirs(state_dir, exist_ok=True)
    data = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in recs).encode("utf-8")
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            if f.tell():
                f.seek(-1, os.SEEK_END)
                if f.read(1) != b"\n":
                    data = b"\n" + data
    except OSError:
        pass
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)


def live_findings(recs):
    """Findings that belong to a judged window record with the same run_dir;
    the rest are orphans (a crash between lines, or a deleted window line)."""
    judged = {(r.get("window"), r.get("run_dir")) for r in recs
              if r["kind"] == "window" and r.get("status") == "judged"}
    live, orphans = [], 0
    for r in recs:
        if r["kind"] != "finding":
            continue
        if (r.get("window"), r.get("run_dir")) in judged:
            live.append(r)
        else:
            orphans += 1
    if orphans:
        warn(f"{orphans} finding record(s) have no judged window record "
             "with the same run_dir and are ignored")
    return live


# ---- integration notes ------------------------------------------------------------------------

NOTE_HEAD = re.compile(r"^\s*<!--\s*lkml-integration:\s*(\S+)\s+v(\d+)\s*-->")
SEP = r"(?:--|—|–)"
NOTE_LINE = re.compile(
    r"^\s*(?:[-*]\s+)?`?([0-9a-f]{7,40})`?\s+(.*?)\s+" + SEP
    + r"\s+\**(take with changes|take|drop)\b\**\s*(?:(?:" + SEP + r"|:)\s*(.*?))?\s*$",
    re.I)


def parse_note(body):
    m = NOTE_HEAD.match(body)
    if not m:
        return None
    out = {"series": m.group(1), "version": int(m.group(2)), "take": 0,
           "take_with_changes": 0, "drop": 0, "changes": [], "drops": []}
    for line in body.splitlines()[1:]:
        lm = NOTE_LINE.match(line)
        if not lm:
            continue
        sha, subject, decision, reason = lm.groups()
        decision = decision.lower()
        entry = {"sha": sha, "subject": subject.strip(), "reason": (reason or "").strip()}
        if decision == "take":
            out["take"] += 1
        elif decision == "drop":
            out["drop"] += 1
            out["drops"].append(entry)
        else:
            out["take_with_changes"] += 1
            out["changes"].append(entry)
    return out


def integration_records(pr, files, recs):
    """New or changed integration records for one pull request."""
    newest = {}
    for c in files["issue-comments.json"]:
        note = parse_note(c.get("body") or "")
        if not note:
            continue
        key = (note["series"], note["version"])
        rank = (c.get("created_at") or "", c.get("id") or 0)
        if key not in newest or rank >= newest[key][0]:
            newest[key] = (rank, c, note)
    have = {}
    for r in recs:
        if r["kind"] == "integration":
            have[(r.get("pr"), r.get("series"), r.get("version"))] = r
    out = []
    for (series, version), (_rank, c, note) in sorted(newest.items()):
        old = have.get((pr, series, version))
        if old and old.get("comment_id") == c.get("id") and old.get("updated_at") == c.get("updated_at"):
            continue
        out.append({"schema": 1, "kind": "integration", "pr": pr, "series": series,
                    "version": version, "comment_id": c.get("id"),
                    "updated_at": c.get("updated_at") or c.get("created_at"),
                    "url": c.get("html_url"), "take": note["take"],
                    "take_with_changes": note["take_with_changes"], "drop": note["drop"],
                    "changes": note["changes"], "drops": note["drops"]})
    return out


# ---- the summary ---------------------------------------------------------------------------------

VERDICTS = ("real-defect", "design-disagreement", "nit", "not-knowable",
            "not-in-reviewed-tree", "not-a-finding", "duplicate", "unresolved")


def iso_week(when):
    if when is None:
        return "unknown"
    y, w, _ = when.isocalendar()
    return f"{y}-W{w:02d}"


def cell(v):
    if v is None or v == "":
        return "(none)"
    return " ".join(str(v).split()).replace("|", "\\|")


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join("---" for _ in headers) + "|"]
    if not rows:
        rows = [["(none)"] + [""] * (len(headers) - 1)]
    for r in rows:
        out.append("| " + " | ".join("" if c is None else str(c) for c in r) + " |")
    return out


def count_table(title, live, field):
    counts = {}
    for f in live:
        k = cell(f.get(field))
        counts[k] = counts.get(k, 0) + 1
    rows = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    return [f"### {title}", ""] + table([field.replace("_", " "), "real defects"],
                                         [[k, v] for k, v in rows]) + [""]


def build_summary(recs, cfg, now):
    live = live_findings(recs)
    wrecs = [r for r in recs if r["kind"] == "window"]
    L = ["# Gap monitor summary", "",
         f"As of {stamp(now)}. Repository {cfg['repo']}. Built from the ledger alone.", ""]
    # 1. per week of sign-off
    weeks = {}

    def wk(week):
        return weeks.setdefault(week, {"windows": set(), "findings": 0,
                                       **{v: 0 for v in VERDICTS}, "other": 0})
    signoff_of = {}
    for r in wrecs:
        at = parse_when(r.get("signoff_at")) or parse_when(r.get("at"))
        if r.get("status") == "judged":
            signoff_of[r.get("window")] = at
            wk(iso_week(at))["windows"].add(r.get("window"))
    for f in live:
        at = parse_when(f.get("signoff_at")) or signoff_of.get(f.get("window"))
        row = wk(iso_week(at))
        row["findings"] += 1
        v = f.get("verdict")
        row[v if v in VERDICTS else "other"] += 1
    L += ["## Sign-offs judged, per ISO week of sign-off", ""]
    L += table(["week", "windows judged", "findings"] + list(VERDICTS) + ["other"],
               [[w, len(d["windows"]), d["findings"]] + [d[v] for v in VERDICTS] + [d["other"]]
                for w, d in sorted(weeks.items())]) + [""]
    # 2. real defects
    real = [f for f in live if f.get("verdict") == "real-defect"]
    L += ["## Real defects", ""]
    L += count_table("By severity", real, "severity")
    L += count_table("By code owner", real, "code_owner")
    L += count_table("By panel coverage", real, "panel_coverage")
    L += count_table("By seat", real, "seat")
    # 3. last 30 days
    horizon = now - dt.timedelta(days=30)
    recent = [f for f in real if (parse_when(f.get("judged_at")) or now) >= horizon]
    recent.sort(key=lambda f: (parse_when(f.get("judged_at")) or now, f.get("window") or ""),
                reverse=True)
    L += ["## Real defects, last 30 days", ""]
    L += table(["pull request", "severity", "owner", "coverage", "claim", "comment"],
               [[f"#{f.get('pr')}", cell(f.get("severity")), cell(f.get("code_owner")),
                 cell(f.get("panel_coverage")), cell(f.get("claim")),
                 ((f.get("item") or {}).get("url") or "-")] for f in recent]) + [""]
    # 4. integration tally
    newest = {}
    for r in recs:
        if r["kind"] == "integration":
            newest[(r.get("pr"), r.get("series"), r.get("version"))] = r
    wk_int = {}
    for r in newest.values():
        d = wk_int.setdefault(iso_week(parse_when(r.get("updated_at"))),
                              {"notes": 0, "take": 0, "take_with_changes": 0, "drop": 0})
        d["notes"] += 1
        for k in ("take", "take_with_changes", "drop"):
            d[k] += r.get(k) or 0
    L += ["## Integration tally, per ISO week of the note", ""]
    L += table(["week", "notes", "take", "take with changes", "drop"],
               [[w, d["notes"], d["take"], d["take_with_changes"], d["drop"]]
                for w, d in sorted(wk_int.items())]) + [""]
    reasons = []
    for key in sorted(newest, key=lambda k: (k[0] or 0, str(k[1]), k[2] or 0)):
        r = newest[key]
        for label, lst in (("take with changes", r.get("changes")), ("drop", r.get("drops"))):
            for e in lst or []:
                reasons.append([f"#{r.get('pr')}", cell(r.get("series")), f"v{r.get('version')}",
                                label, cell(e.get("sha")), cell(e.get("reason"))])
    L += ["### Reasons given for the changes and drops", ""]
    L += table(["pull request", "series", "version", "decision", "commit", "reason"], reasons) + [""]
    # 5. blocked and failed
    state = window_ledger(recs)
    last = {}
    for r in wrecs:
        last[r.get("window")] = r
    rows = []
    for key in sorted(last):
        r, st = last[key], state[key]
        if r.get("status") == "judged":
            continue
        if r.get("status") == "sha-unavailable":
            label = "blocked"
        elif st["fails"] >= cfg["judge"]["max_attempts"]:
            label = "failed"
        else:
            label = f"retrying ({st['fails']}/{cfg['judge']['max_attempts']})"
        rows.append([cell(key), label, cell(r.get("at")), cell(r.get("notes"))])
    L += ["## Blocked and failed windows", ""]
    L += table(["window", "state", "since", "last note"], rows) + [""]
    return "\n".join(L)


def write_summary(cfg, recs, now):
    text = build_summary(recs, cfg, now)
    os.makedirs(cfg["state_dir"], exist_ok=True)
    path = os.path.join(cfg["state_dir"], "summary.md")
    atomic_write(path, text)
    return path


# ---- evidence ------------------------------------------------------------------------------------------

RENDER_HEADERS = ("X-Version", "X-Review-Target", "X-Upstream-Head", "X-Lkml-Push-Mode",
                  "X-Lkml-Tier", "X-Lkml-Tier-Reason", "X-Seats", "X-Upstream-State")
BASE_RE = re.compile(r"^Base:\s*([0-9a-f]{40})\s*$", re.M)
FROZEN_RE = re.compile(r"^Frozen-Head:\s*([0-9a-f]{40})\s*$", re.M)
PANEL_RE = re.compile(r"^Panel:\s*(.+?)\s*$", re.M)
ADVISORY_RE = re.compile(r"^Advisory:\s*(.+?)\s*$", re.M)
SCRATCH_DEFAULT = "/var/tmp/claude-scratch/lkml-gap-monitor"


def render_thread(msgs, upto_msg=None, upto_at=None):
    out = []
    for m in msgs:
        when = parse_when(m.get("date"))
        if upto_at is not None and when is not None and when > upto_at:
            break
        out.append("=" * 78)
        out.append(f"Message {m.get('seq')}  id {m.get('id')}")
        out.append(f"Date: {m.get('date')}")
        cc = m.get("cc") or []
        out.append(f"From: {m.get('from')}    To: {', '.join(m.get('to') or [])}"
                   + (f"    Cc: {', '.join(cc)}" if cc else ""))
        out.append(f"Subject: {m.get('subject')}")
        for k in RENDER_HEADERS:
            v = hdr_first(m, k)
            if v is not None:
                out.append(f"{k}: {v}")
        if m.get("attachments"):
            out.append("Attachments (names only, contents not available): " + ", ".join(
                a.get("name", str(a)) if isinstance(a, dict) else str(a) for a in m["attachments"]))
        out.append("")
        out.append((m.get("body") or "").rstrip())
        out.append("")
        if upto_msg is not None and m.get("id") == upto_msg:
            break
    return "\n".join(out) + "\n"


def thread_base(msgs, version):
    """The PR base: the newest author cover at or before version carrying a
    Base: line, else the thread root's."""
    m0 = BASE_RE.search(msgs[0].get("body") or "")
    base = m0.group(1) if m0 else None
    for m in msgs[1:]:
        if m.get("from") != "@pr-author":
            continue
        mv = re.match(r"\[PATCH v(\d+)", m.get("subject") or "")
        if not mv or (version is not None and int(mv.group(1)) > int(version)):
            continue
        mb = BASE_RE.search((m.get("body") or "")[:3000])
        if mb:
            base = mb.group(1)
    return base


def thread_roster(msgs):
    body = (msgs[0].get("body") or "")[:2000]
    mp, ma = PANEL_RE.search(body), ADVISORY_RE.search(body)
    return (mp.group(1) if mp else ""), (ma.group(1) if ma else "")


def frozen_head(msgs, version):
    found = None
    for m in msgs[1:]:
        mv = re.match(r"\[PATCH v(\d+)", m.get("subject") or "")
        if m.get("from") == "@pr-author" and mv and str(version) == mv.group(1):
            fm = FROZEN_RE.search(m.get("body") or "")
            if fm:
                found = fm.group(1)
    if found:
        return found
    fm = FROZEN_RE.search(msgs[0].get("body") or "")
    return fm.group(1) if fm else None


def quote(text):
    return "> " + (text or "").replace("\n", "\n> ")


def stage_evidence(win, led_judged, ev_dir):
    """Write evidence/ for one window. Returns (index, n_numbered, keys,
    thread file names)."""
    s, prj, pr = win["signoff"], win["prj"], win["pr"]
    os.makedirs(ev_dir)
    with open(os.path.join(ev_dir, "pr.md"), "w", encoding="utf-8") as f:
        f.write(f"# PR #{pr}: {prj.get('title')}\n\n")
        f.write(f"- Author: {login_of(prj.get('user'))}\n- Created: {prj.get('created_at')}\n"
                f"- State now: {prj.get('state')}, merged_at: {prj.get('merged_at')}\n")
        f.write(f"- Base branch: {(prj.get('base') or {}).get('ref')}\n"
                f"- Head now: {(prj.get('head') or {}).get('sha')}\n\n")
        f.write("NOTE: this is the PR description as it reads TODAY. It may have been "
                "edited after the panel signed off.\n"
                "The panel thread quotes parts of the description it actually saw.\n\n---\n\n")
        f.write((prj.get("body") or "").strip() and prj["body"] or "(empty)")
        f.write("\n")
    names = []
    for n, th in enumerate(win["threads"], 1):
        if th["thread"] == s["thread"]:
            name, text = "thread.md", render_thread(th["messages"], upto_msg=s["msg"])
        elif th["started"] is not None and th["started"] <= s["at"]:
            name, text = f"thread-earlier-{n}.md", render_thread(th["messages"], upto_at=s["at"])
        else:
            continue
        with open(os.path.join(ev_dir, name), "w", encoding="utf-8") as f:
            f.write(text)
        names.append(name)

    # feedback.md
    items = win["items"]
    cand = [i for i in items if not i["auto"] and i["key"] not in led_judged
            and (i["kind"] != "xref" or i["trigger"])]
    left_out = sum(1 for i in items if i["kind"] == "xref" and not i["trigger"]
                   and i["key"] not in led_judged)
    done = [i for i in items if not i["auto"] and i["key"] in led_judged]
    byid = {i["id"]: i for i in cand if i["kind"] == "inline"}
    raw_inline = {c.get("id"): c for c in win["files"]["review-comments.json"]}
    nested = {}
    # A reply nests under the top of its chain, unless it is a trigger
    # and that top is not: the judge is told nested replies are context,
    # so a claim under the author's note or a trivial comment would be
    # recorded as judged without a verdict slot. Such a reply is its own
    # item, and replies below it nest under it.
    own = set()
    for i in sorted(cand, key=lambda c: c["at"]):
        par = i.get("in_reply_to") if i["kind"] == "inline" else None
        if par not in byid:
            continue
        top, seen = par, set()
        while top not in own and byid[top].get("in_reply_to") in byid and top not in seen:
            seen.add(top)
            top = byid[top]["in_reply_to"]
        if i["trigger"] and not byid[top]["trigger"]:
            own.add(i["id"])
        else:
            nested.setdefault(top, []).append(i)
    nested_ids = {r["id"] for rs in nested.values() for r in rs}
    roots = [i for i in cand if i["kind"] != "inline" or i["id"] not in nested_ids]
    timeline = sorted([(i["at"], 0, i) for i in roots] + [(e["at"], 1, e) for e in win["events"]],
                      key=lambda t: (t[0], t[1]))
    end = f" and up to the panel's next sign-off at {stamp(win['until'])}" if win["until"] else " (no later sign-off)"
    L = [f"# Feedback on PR #{pr} after the panel's sign-off at {stamp(s['at'])} (UTC)\n",
         f"Window: after {stamp(s['at'])}{end}.\n",
         "Each top-level item has an id F<n>. Replies are shown under the item they answer; "
         "they are context, not separate findings.\n",
         "Items of kind `xref` are later issues or pull requests that mention this PR.\n"]
    index, n = {}, 0
    for _at, _o, x in timeline:
        if "ref" in x:
            L.append(f"\n--- event: {x['kind']} at {stamp(x['at'])} by {x['user']} {x['ref'][:12]}\n")
            continue
        n += 1
        index[f"F{n}"] = {"kind": x["kind"], "id": x["id"], "url": x["url"], "user": x["user"]}
        L.append(f"\n## F{n} [{x['kind']}] by {x['user']} at {stamp(x['at'])}\n")
        if x["url"]:
            L.append(f"URL: {x['url']}\n")
        if x["kind"] == "review":
            L.append(f"Review state: {x.get('state')}  (on commit {str(x.get('commit'))[:12]})\n")
        if x["kind"] == "inline":
            L.append(f"File: {x.get('path')}  line {x.get('line')}  "
                     f"(comment made on commit {str(x.get('commit'))[:12]})\n")
            par = raw_inline.get(x.get("in_reply_to"))
            if par and x.get("in_reply_to") in byid:
                L.append(f"\nThis is a reply to a comment shown above, by "
                         f"{login_of(par.get('user'))} at {par.get('created_at')}:\n\n"
                         + quote(par.get("body")) + "\n")
            elif par:
                L.append(f"\nThis is a reply to an EARLIER comment (before the sign-off, "
                         f"or not itself feedback) by {login_of(par.get('user'))} at "
                         f"{par.get('created_at')}:\n\n" + quote(par.get("body")) + "\n")
            if x.get("hunk"):
                L.append("\nDiff hunk the comment is attached to:\n\n```diff\n" + x["hunk"] + "\n```\n")
        if x["kind"] == "xref":
            src = x["src"]
            L.append(f"Referenced from: #{src.get('number')} "
                     f"({'pull request' if 'pull_request' in src else 'issue'}), created "
                     f"{src.get('created_at')}, state {src.get('state')}\n")
            L.append(f"\nTitle: {src.get('title')}\nAuthor: {login_of(src.get('user'))}\n\nBody:\n\n"
                     + ((src.get("body") or "(empty)")[:12000]) + "\n")
        else:
            L.append("\n" + (x["body"] or "(empty body)") + "\n")
        for r in sorted(nested.get(x["id"], []), key=lambda r: r["at"]) if x["kind"] == "inline" else []:
            L.append(f"\n> Reply by {r['user']} at {stamp(r['at'])}:\n>\n" + quote(r["body"]) + "\n")
    if done:
        L.append("\n## Already judged (context only; do not judge these again)\n")
        for d in done:
            first = (d["body"].strip().splitlines() or [""])[0][:100]
            L.append(f"- {d['key']} by {d['user']} at {stamp(d['at'])}: {first}")
        L.append("")
    if left_out:
        L.append(f"\n({left_out} other later issues or pull requests mention this PR and "
                 "were left out: nothing in them reads as a fix or a bug report.)\n")
    with open(os.path.join(ev_dir, "feedback.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    with open(os.path.join(ev_dir, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1)

    # later.md
    commits = win["files"]["commits.json"]
    shas = [c.get("sha") for c in commits]
    if s["sha"] in shas:
        later = commits[shas.index(s["sha"]) + 1:]
        how = "after the reviewed commit"
    else:
        later = [c for c in commits
                 if (parse_when(((c.get("commit") or {}).get("author") or {}).get("date")) or s["at"]) > s["at"]]
        how = "dated after the sign-off (the reviewed commit is not in the list)"
    with open(os.path.join(ev_dir, "later.md"), "w", encoding="utf-8") as f:
        f.write(f"# PR #{pr}: commits on the PR as it stands today, {how}\n\n")
        f.write("Compare with `git log` in your checkout to see which were added or rewritten "
                "after the sign-off.\nA commit listed here may exist in your clone's object store "
                "(try `git show <sha>`); if it does, it is\nEVIDENCE of what was later changed, "
                "not part of the tree you are judging.\n\n")
        for c in later:
            cm = c.get("commit") or {}
            a = cm.get("author") or {}
            f.write(f"- {str(c.get('sha'))[:12]}  {a.get('date')}  {a.get('name')} "
                    f"<{a.get('email')}>  {((cm.get('message') or '').splitlines() or [''])[0]}\n")
        if not later:
            f.write("(no commits after the reviewed one)\n")
        if prj.get("merged_at"):
            f.write(f"\nMerged at {prj['merged_at']} (merge commit {prj.get('merge_commit_sha')}).\n")
    keys = [i["key"] for i in cand]
    return index, n, keys, names


def render_template(text, values):
    """One pass: a value that contains @@ is never re-scanned."""
    return re.sub(r"@@([A-Z_]+)@@", lambda m: values[m.group(1)], text)


def template_path():
    return os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))),
                        "fleet", "prompts", "gap-judge.md")


PLACEHOLDERS = ("PR", "TITLE", "SHA", "VERDICT", "VERSION", "SIGNOFF_DATE", "TIER",
                "RESPIN_NOTE", "BASE_NOTE", "THREAD_FILES", "ROSTER", "N_ITEMS")


def load_template():
    path = template_path()
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        raise ConfigError(f"judge handoff template not found: {path}")
    unknown = sorted(set(re.findall(r"@@([A-Z_]+)@@", text)) - set(PLACEHOLDERS))
    if unknown:
        raise ConfigError(f"{path}: unknown placeholder(s) {', '.join(unknown)}")
    return text


def handoff_values(win, n_items, names):
    s, prj = win["signoff"], win["prj"]
    th = next(t for t in win["threads"] if t["thread"] == s["thread"])
    msgs = th["messages"]
    base = thread_base(msgs, s["version"])
    roster, advisory = thread_roster(msgs)
    if s["verdict"] == "RESPIN":
        note = ("The verdict was RESPIN: the panel's own author seat wrote commits on top of the "
                f"PR author's frozen head (`{frozen_head(msgs, s['version']) or '?'}`), and the "
                "reviewers signed off on that combined tree. Those panel-written commits are in "
                "your checkout, authored by `fork-sandbox agent <agent@fork-sandbox.invalid>`.")
    else:
        note = ("The verdict was SIGNED-OFF: the reviewed tree is the PR author's own pushed head. "
                "It may still contain commits the panel's author seat wrote in an earlier round "
                "and the PR author took; those are authored by "
                "`fork-sandbox agent <agent@fork-sandbox.invalid>`.")
    base_note = (f"The PR's base commit is `{base}`: read the PR as `git log {base}..HEAD`." if base else
                 "The PR's base is not recorded here; the thread root's `Base:` and `Patches:` "
                 "lines say where the PR starts.")
    return {
        "PR": str(win["pr"]), "TITLE": str(prj.get("title")), "SHA": s["sha"],
        "VERDICT": s["verdict"],
        "VERSION": str(s["version"]) if s["version"] is not None else "unknown",
        "SIGNOFF_DATE": stamp(s["at"]), "TIER": s["tier"] or "untiered",
        "RESPIN_NOTE": note, "BASE_NOTE": base_note,
        "THREAD_FILES": ", ".join(f"`/attachments/{n}`" for n in names),
        "ROSTER": roster + (f" (advisory: {advisory})" if advisory else ""),
        "N_ITEMS": str(n_items),
    }


# ---- sha handling ---------------------------------------------------------------------------------------

def have_commit(checkout, sha):
    return run_cmd(["git", "-C", checkout, "cat-file", "-e", f"{sha}^{{commit}}"])[0] == 0


def ensure_sha(cfg, win):
    """Make the reviewed sha present in the checkout. -> (ok, note)."""
    s, co = win["signoff"], cfg["checkout"]
    sha = s["sha"]
    if not sha:
        return False, "no usable X-Review-Target header (absent, repeated or not ending in a 40-hex sha) on the sign-off message"
    if have_commit(co, sha):
        return True, None
    note = []
    rc, _o, err = run_cmd(["git", "-C", co, "fetch", "origin", sha])
    if rc != 0:
        note.append(f"git fetch origin failed: {last_line(err)}")
    if not have_commit(co, sha) and cfg["sha_fetch_cmd"]:
        rc, _o, err = run_cmd(cfg["sha_fetch_cmd"] + [str(win["pr"]), sha, s["verdict"]], cwd=co)
        if rc != 0:
            note.append(f"sha_fetch_cmd failed (exit {rc}): {last_line(err)}")
    if not have_commit(co, sha):
        return False, f"reviewed sha {sha} is not in the checkout; " + "; ".join(note or ["no sha_fetch_cmd set"])
    run_cmd(["git", "-C", co, "update-ref", f"refs/lkml-gap/{win['pr']}-{sha[:12]}", sha])
    return True, None


# ---- judging -----------------------------------------------------------------------------------------------

class Judging:
    """Runs judges, judge.concurrency at a time, each launcher in its own
    process group so an interrupt can stop it and everything under it."""

    def __init__(self, cfg, now, scratch, template, led, state_dir):
        self.cfg, self.now, self.scratch = cfg, now, scratch
        self.template, self.led, self.state = template, led, state_dir
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.procs = {}
        self.killed = set()
        self.new_findings = []
        self.failures = []
        self.appended = 0

    def interrupt(self):
        self.stop.set()
        with self.lock:
            for key, proc in self.procs.items():
                self.killed.add(key)
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except OSError:
                    pass

    def run_all(self, wins):
        queue = list(wins)
        qlock = threading.Lock()

        def worker():
            while not self.stop.is_set():
                with qlock:
                    if not queue:
                        return
                    win = queue.pop(0)
                try:
                    self.judge(win)
                except Exception as e:  # one judge failing must not stop the rest
                    with self.lock:
                        self.failures.append(f"window {win['window']}: {type(e).__name__}: {e}")
        threads = [threading.Thread(target=worker) for _ in range(self.cfg["judge"]["concurrency"])]
        for t in threads:
            t.start()
        while any(t.is_alive() for t in threads):
            for t in threads:
                t.join(0.2)

    def judge(self, win):
        cfg, s = self.cfg, win["signoff"]
        lw = self.led.get(win["window"]) or {"judged": set(), "fails": 0}
        attempt = lw["fails"] + 1
        msg8 = re.sub(r"[^A-Za-z0-9]", "", (s["msg"] or "")[:8]) or "x"
        stage = os.path.join(self.scratch, f"{win['pr']}-{msg8}-a{attempt}")
        if os.path.lexists(stage):
            shutil.rmtree(stage)
        os.makedirs(stage)
        ev_dir = os.path.join(stage, "evidence")
        index, n_items, keys, names = stage_evidence(win, lw["judged"], ev_dir)
        handoff = os.path.join(stage, "handoff.md")
        with open(handoff, "w", encoding="utf-8") as f:
            f.write(render_template(self.template, handoff_values(win, n_items, names)))
        # A uniqueness token, not a recorded time: wall clock plus pid, so a
        # re-launch after an interrupted run never reuses a branch name.
        branch = (f"lkml-gap-judge-{win['pr']}-{msg8}-a{attempt}-"
                  f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{os.getpid():x}")
        meta = json.dumps({"kind": "investigate", "difficulty": 3, "size": "s",
                           "prompt_template_id": "lkml-gap-judge-v1", "stage": "gap-monitor"},
                          separators=(",", ":"))
        j = cfg["judge"]
        argv = (["fork-sandbox", "run", "--wait", "--wait-timeout", str(j["wait_timeout"]),
                 "--harness", j["harness"], "--model", j["model"], "--branch", branch,
                 "--checkout", s["sha"], "--attach-dir", ev_dir] + j["run_args"]
                + ["--task-meta", meta, cfg["checkout"], handoff])
        log_path = os.path.join(stage, "launch.log")
        sys.stdout.write(f"judging {win['window']} (attempt {attempt}, {n_items} items)\n")
        sys.stdout.flush()
        launch_err = None
        with open(log_path, "w", encoding="utf-8") as log:
            with self.lock:
                if self.stop.is_set():
                    return
                try:
                    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log,
                                            stderr=subprocess.STDOUT, start_new_session=True)
                    self.procs[win["window"]] = proc
                except OSError as e:
                    proc, launch_err = None, f"cannot run fork-sandbox: {e}"
            if proc is not None:
                proc.wait()
                with self.lock:
                    self.procs.pop(win["window"], None)
                    if win["window"] in self.killed:
                        return  # interrupted: no record, no attempt consumed
        run_dir, verdicts, why = None, None, launch_err
        if not why:
            with open(log_path, encoding="utf-8", errors="replace") as f:
                m = re.search(r"^  run dir:  (.+?)\s*$", f.read(), re.M)
            if not m:
                why = "no 'run dir:' line in the launcher output"
            else:
                run_dir = m.group(1)
                vpath = os.path.join(run_dir, "outbox", "verdicts.json")
                try:
                    with open(vpath, encoding="utf-8") as f:
                        verdicts = json.load(f)
                    if not isinstance(verdicts, dict) or not isinstance(verdicts.get("findings"), list):
                        why = "verdicts.json has no findings list"
                except OSError:
                    why = f"no verdicts.json at {vpath}"
                except ValueError as e:
                    why = f"verdicts.json is not valid JSON: {e}"
        self.record(win, attempt, keys, index, run_dir, None if why else verdicts, why)

    def record(self, win, attempt, keys, index, run_dir, verdicts, why):
        cfg, s = self.cfg, win["signoff"]
        at = stamp(self.now)
        wrec = {"schema": 1, "kind": "window", "window": win["window"], "pr": win["pr"],
                "status": "judge-failed" if why else "judged", "attempt": attempt,
                "items": keys, "run_dir": run_dir, "at": at, "head_matches": None,
                "notes": why or "", "signoff_at": stamp(s["at"])}
        recs = []
        if not why:
            wrec["head_matches"] = verdicts.get("head_matches")
            note = verdicts.get("notes")
            wrec["notes"] = note if isinstance(note, str) else ("" if note is None else json.dumps(note))
            answered = set()
            for el in verdicts["findings"]:
                if not isinstance(el, dict):
                    continue
                fid = el.get("id")
                stem = re.match(r"^(F\d+)[a-z]*$", fid) if isinstance(fid, str) else None
                if stem:
                    answered.add(stem.group(1))
                rec = {"schema": 1, "kind": "finding", "judged_at": at, "window": win["window"],
                       "pr": win["pr"], "thread": s["thread"], "signoff_msg": s["msg"],
                       "signoff_at": stamp(s["at"]), "signoff_verdict": s["verdict"],
                       "version": s["version"], "tier": s["tier"], "reviewed_sha": s["sha"],
                       "finding_id": fid,
                       "item": index.get(stem.group(1)) if stem else None}
                for k in JUDGE_FIELDS:
                    rec[k] = el.get(k)
                rec["run_dir"], rec["judge_model"] = run_dir, cfg["judge"]["model"]
                recs.append(rec)
            missing = [k for k in index if k not in answered]
            if missing:
                msg = f"no verdict for {', '.join(missing)}"
                wrec["notes"] = (wrec["notes"] + "; " if wrec["notes"] else "") + msg
                sys.stderr.write(f"Warning: window {win['window']}: {msg}\n")
        recs.append(wrec)  # the window record last: a torn append leaves orphans, not a gap
        with self.lock:
            append_records(self.state, recs)
            self.appended += 1
            if why:
                self.failures.append(f"judge for {win['window']} failed: {why}")
            else:
                self.new_findings += [r for r in recs if r["kind"] == "finding"
                                      and r.get("verdict") == "real-defect"]
        sys.stdout.write(f"{win['window']}: {'judge-failed' if why else 'judged'}"
                         + (f" ({why})" if why else f", {len(recs) - 1} findings") + "\n")
        sys.stdout.flush()


def notify_line(f):
    claim = " ".join(str(f.get("claim") or "").split())
    return (f"PR #{f.get('pr')} [{f.get('severity') or '-'}] owner={f.get('code_owner') or '-'} "
            f"coverage={f.get('panel_coverage') or '-'}: {claim} "
            f"{(f.get('item') or {}).get('url') or '-'}")


# ---- commands --------------------------------------------------------------------------------------------------

USAGE = ("usage: lkml-gap-monitor.py scan [--json] [--no-fetch] [--now <ISO-8601>]\n"
         "       lkml-gap-monitor.py run [--no-fetch] [--max-judges N] [--now <ISO-8601>]\n"
         "       lkml-gap-monitor.py summary [--now <ISO-8601>]\n"
         "       lkml-gap-monitor.py -h|--help")


def parse_now(text):
    if not re.match(r"^\d{4}-\d\d-\d\d", text):
        raise UsageError(f"--now wants an ISO-8601 time, got {text!r}")
    when = parse_when(text)
    if when is None:
        raise UsageError(f"--now wants an ISO-8601 time, got {text!r}")
    return when


def parse_args(argv):
    opts = {"help": False, "cmd": None, "json": False, "no_fetch": False,
            "now": None, "max_judges": None}
    args = list(argv)
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-h", "--help"):
            opts["help"] = True
        elif a == "--json":
            opts["json"] = True
        elif a == "--no-fetch":
            opts["no_fetch"] = True
        elif a in ("--now", "--max-judges"):
            i += 1
            if i >= len(args):
                raise UsageError(f"{a} needs a value")
            if a == "--now":
                opts["now"] = parse_now(args[i])
            else:
                if not args[i].isdigit() or int(args[i]) < 1:
                    raise UsageError("--max-judges wants a positive integer")
                opts["max_judges"] = int(args[i])
        elif a.startswith("-"):
            raise UsageError(f"unknown option {a}")
        elif opts["cmd"] is None:
            opts["cmd"] = a
        else:
            raise UsageError(f"unexpected argument {a}")
        i += 1
    if opts["help"]:
        return opts
    if opts["cmd"] is None:
        raise UsageError("give a subcommand")
    if opts["cmd"] not in COMMANDS:
        raise UsageError(f"unknown subcommand {opts['cmd']}")
    allowed = COMMANDS[opts["cmd"]]
    for flag in ("json", "no_fetch", "max_judges"):
        if opts[flag] and flag not in allowed:
            raise UsageError(f"--{flag.replace('_', '-')} does not apply to {opts['cmd']}")
    return opts


def prepare(cfg, opts, now):
    """Fetch (unless told not to), build and classify. Returns the pieces
    scan and run both need."""
    failures = []
    state = cfg["state_dir"]
    if opts["no_fetch"]:
        if not os.path.isdir(os.path.join(state, "threads")):
            raise InputError(f"--no-fetch: no cache at {os.path.join(state, 'threads')}")
    else:
        fetch_threads(cfg, failures)
    raw, excluded = build_model(cfg, now, failures)
    if not opts["no_fetch"]:
        for pr, _sos, _ths in raw:
            fetch_forge(cfg, pr, failures)
    windows, skipped = assemble(cfg, now, raw, failures)
    recs = read_ledger(state)
    led = window_ledger(recs)
    rows = []
    for w in windows:
        annotate(w, cfg)
        rows.append((w, classify(w, cfg, led, now)))
    return rows, excluded, skipped, failures, recs, led


def cmd_scan(cfg, opts, now):
    rows, excluded, skipped, failures = prepare(cfg, opts, now)[:4]
    if opts["json"]:
        sys.stdout.write(json.dumps({
            "now": stamp(now), "lookback_days": cfg["lookback_days"],
            "windows": [r for _, r in rows], "excluded": excluded,
            "skipped": skipped, "fetch_failures": failures,
        }, indent=1) + "\n")
    else:
        for _, r in rows:
            sys.stdout.write(f"{r['window']}\t{r['class']}\t{r['why']}\n")
    sys.stdout.flush()
    for s in skipped:
        failures.append(f"window {s['window']} skipped: {s['reason']}")
    for f in failures:
        sys.stderr.write(f"Error: {f}\n")
    return 1 if failures else 0


def cmd_summary(cfg, opts, now):
    path = write_summary(cfg, read_ledger(cfg["state_dir"]), now)
    sys.stdout.write(f"wrote {path}\n")
    return 0


def check_run_config(cfg):
    if not cfg["checkout"]:
        raise ConfigError("run needs 'checkout' in the config: the path of a local clone "
                          "of the reviewed repository")
    rc, _o, _e = run_cmd(["git", "-C", cfg["checkout"], "rev-parse", "--is-inside-work-tree"])
    if rc != 0:
        raise ConfigError(f"checkout {cfg['checkout']} is not a git work tree")
    if not cfg["judge"]["model"]:
        raise ConfigError("run needs 'judge.model' in the config; no model is ever guessed")
    return load_template()


def cmd_run(cfg, opts, now):
    template = check_run_config(cfg)
    state = cfg["state_dir"]
    os.makedirs(state, exist_ok=True)
    lock_fd = os.open(os.path.join(state, "run.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise InputError(f"another run holds {os.path.join(state, 'run.lock')}")
    rows, excluded, skipped, failures, recs, led = prepare(cfg, opts, now)
    for s in skipped:
        failures.append(f"window {s['window']} skipped: {s['reason']}")
    for _, r in rows:
        sys.stdout.write(f"{r['window']}\t{r['class']}\t{r['why']}\n")
    sys.stdout.flush()

    # integration notes: counted, not judged
    seen_pr = set()
    for w, _r in rows:
        if w["pr"] in seen_pr:
            continue
        seen_pr.add(w["pr"])
        new = integration_records(w["pr"], w["files"], recs)
        if new:
            append_records(state, new)
            recs = recs + new

    # blocked windows first, then the judges
    work = [(w, r) for w, r in rows if r["class"] in ("due", "blocked")]
    cap = opts["max_judges"]
    ready, left = [], 0
    for w, r in work:
        if cap is not None and len(ready) >= cap:
            left += 1
            continue
        ok, note = ensure_sha(cfg, w)
        if ok:
            ready.append(w)
            continue
        failures.append(f"window {w['window']} blocked: {note}")
        if (led.get(w["window"]) or {}).get("newest") != "sha-unavailable":
            append_records(state, [{
                "schema": 1, "kind": "window", "window": w["window"], "pr": w["pr"],
                "status": "sha-unavailable", "attempt": 0, "items": [], "run_dir": None,
                "at": stamp(now), "head_matches": None, "notes": note,
                "signoff_at": stamp(w["signoff"]["at"])}])
    if left:
        sys.stdout.write(f"{left} due window(s) left for a later run (--max-judges {cap})\n")

    scratch = os.environ.get("LKML_GAP_MONITOR_SCRATCH_DIR") or SCRATCH_DEFAULT
    judging = Judging(cfg, now, scratch, template, led, state)
    interrupted = []

    def on_signal(signum, _frame):
        if judging.stop.is_set():
            signal.signal(signum, signal.SIG_DFL)
            os.kill(os.getpid(), signum)
            return
        interrupted.append(signum)
        judging.interrupt()
    old = {sg: signal.signal(sg, on_signal) for sg in (signal.SIGINT, signal.SIGTERM)}
    try:
        if ready:
            os.makedirs(scratch, exist_ok=True)
            judging.run_all(ready)
    finally:
        for sg, h in old.items():
            signal.signal(sg, h)
    failures += judging.failures
    if interrupted:
        failures.append("interrupted: judges still running were stopped and not recorded")

    recs = read_ledger(state)
    summary = write_summary(cfg, recs, now)
    if cfg["publish_cmd"]:
        rc, _o, err = run_cmd(cfg["publish_cmd"] + [summary])
        if rc != 0:
            failures.append(f"publish_cmd failed (exit {rc}): {last_line(err)}")
    if judging.new_findings and cfg["notify_cmd"]:
        # Judges finish in any order; the message reads in sign-off order.
        ordered = sorted(judging.new_findings, key=lambda f: (f["signoff_at"], f["window"]))
        text = "".join(notify_line(f) + "\n" for f in ordered)
        rc, _o, err = run_cmd(cfg["notify_cmd"], stdin_text=text)
        if rc != 0:
            failures.append(f"notify_cmd failed (exit {rc}): {last_line(err)}")
    sys.stdout.flush()
    for f in failures:
        sys.stderr.write(f"Error: {f}\n")
    return 1 if failures else 0


COMMANDS = {"scan": ("json", "no_fetch"), "run": ("no_fetch", "max_judges"), "summary": ()}
HANDLERS = {"scan": cmd_scan, "run": cmd_run, "summary": cmd_summary}


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
        cfg = load_config()
        now = opts["now"] or dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        return HANDLERS[opts["cmd"]](cfg, opts, now)
    except ConfigError as e:
        sys.stderr.write(f"Error: {e}\n")
        return 2
    except InputError as e:
        sys.stderr.write(f"Error: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
