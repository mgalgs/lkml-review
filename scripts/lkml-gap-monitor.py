#!/usr/bin/env python3
"""lkml-gap-monitor.py — find the feedback a pull request drew after its
review panel signed off.

Usage: lkml-gap-monitor.py scan [--json] [--no-fetch] [--now <ISO-8601>]
       lkml-gap-monitor.py -h|--help

A panel signs off on a pull request; afterwards people and other review
agents still comment. Every real defect found after the sign-off is a gap
in the panel. This tool finds the sign-offs, pulls the later feedback and
works out which sign-off windows hold something worth judging.

`scan` fetches (unless --no-fetch), builds one window per sign-off and
prints one line per window inside the lookback, tab separated:

    <pr>:<sign-off message id> <class> <why>

`--json` prints one object instead (windows, excluded, skipped,
fetch_failures). `scan` launches nothing and writes nothing but the
fetch cache. Classes:

    due          an unjudged trigger is present and the quiet period is over
    waiting      an unjudged trigger is present, the quiet period is not over
    judged       nothing new since the last judging
    author-only  only the pull request author's own comments
    xref-only    cross-references, none of them passing the rule
    empty        nothing that could trigger
    blocked      the reviewed sha was not available to judge against
    failed       judging attempts used up

Configuration is read from ~/.config/lkml/gap-monitor.yaml, or from the
file named by LKML_GAP_MONITOR_FILE. There is no fallback location: a
missing file is an error that names the path. An unknown key is an error.
Keys:

    repo                forge slug, owner/name (required)
    checkout            path of a local clone of the reviewed repository
    state_dir           default ${XDG_STATE_HOME:-~/.local/state}/lkml/gap-monitor
    mail_cmd            default "fork-sandbox mail --remote"
    forge_cmd           default "gh api"; only GET paths are passed, with
                        at most --paginate --slurp before the path
    judge:              model, harness (claude), concurrency (2),
                        wait_timeout (7200), max_attempts (2), run_args []
    sha_fetch_cmd, bot_markers, exclude_tier_reason, xref_pattern,
    quiet_hours (6), lookback_days (14), notify_cmd, publish_cmd

Commands are argv lists, or strings split with shlex; none is run through
a shell.

What counts. A sign-off is a message from the thread's secretary whose
trailing Panel-* lines say Panel-Status: CONVERGED and Panel-Verdict:
SIGNED-OFF or RESPIN; the reviewed sha is the last token of its
X-Review-Target header. A window runs from one sign-off to the pull
request's next one (any thread), or to now. Feedback belongs to the
latest sign-off before it. A trigger is a review body, inline comment or
issue comment from someone other than the pull request's author that is
not automation, not an integration note and not trivial, or a later
issue or pull request citing this one that reads as a fix or bug report.
A window is due once its newest non-automation item is older than
quiet_hours.

State lives under state_dir: threads/ and forge/ (the fetch cache) and
ledger.jsonl (read here, to know what was already judged).

Exit status: 0 done; 1 a fetch failed or a window could not be read; 2
usage or configuration error.
"""

import datetime as dt
import json
import os
import re
import shlex
import subprocess
import sys
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

USAGE = ("usage: lkml-gap-monitor.py scan [--json] [--no-fetch] "
         "[--now <ISO-8601>]\n"
         "       lkml-gap-monitor.py -h|--help")

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


# ---- commands -----------------------------------------------------------------------------------

def parse_args(argv):
    opts = {"help": False, "cmd": None, "json": False, "no_fetch": False, "now": None}
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
        elif a == "--now":
            i += 1
            if i >= len(args):
                raise UsageError("--now needs a value")
            when = args[i]
            opts["now"] = parse_now(when)
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
    for flag in ("json", "no_fetch"):
        if opts[flag] and flag not in allowed:
            raise UsageError(f"--{flag.replace('_', '-')} does not apply to {opts['cmd']}")
    return opts


def parse_now(text):
    if not re.match(r"^\d{4}-\d\d-\d\d", text):
        raise UsageError(f"--now wants an ISO-8601 time, got {text!r}")
    when = parse_when(text)
    if when is None:
        raise UsageError(f"--now wants an ISO-8601 time, got {text!r}")
    return when


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
    led = window_ledger(read_ledger(state))
    rows = []
    for w in windows:
        annotate(w, cfg)
        rows.append((w, classify(w, cfg, led, now)))
    return rows, excluded, skipped, failures


def cmd_scan(cfg, opts, now):
    rows, excluded, skipped, failures = prepare(cfg, opts, now)
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


COMMANDS = {"scan": ("json", "no_fetch")}
HANDLERS = {"scan": cmd_scan}


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
