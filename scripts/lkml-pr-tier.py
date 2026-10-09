#!/usr/bin/env python3
"""lkml-pr-tier.py — size a review panel to a pull request: decide skip /
tier / roster / needs-env / budget from a git range plus a little metadata.

Usage: lkml-pr-tier.py <repo> <range> --meta <file>
       lkml-pr-tier.py -h|--help

  <repo>        path to a git checkout holding the PR's commits
  <range>       <base>..<head> or <base>...<head> (a bare ref is refused);
                the PR is the commits reachable from <head> and not from
                <base>, diffed against their merge base
  --meta <file> JSON object: "title" (string), "draft" (bool),
                "author-is-bot" (bool), "labels" (list of strings).
                Missing keys take the non-skipping value; unknown keys
                are ignored.

The vocabulary is TIER (quick < standard < full). It is not the
postmaster's per-wake classifier in the fleet file; do not conflate them.

Output is one compact JSON object on stdout, then a newline: decision
("review" or "skip"), skip_reason, tier, roster, needs_env, budget, a
one-line reason, the signals that fired, and the llm and push fields.

Order of evaluation:

  1. Skip conditions, before any rule: draft, bot author, a skip label.
  2. A force-full label gives `full` regardless of rules.
  3. Otherwise the rules in the tiers file run over the diff; the HIGHEST
     tier any matching rule names wins. If no matching rule names a
     tier, the configured `default-tier` applies (shipped: standard --
     doubt resolves upward).
  4. The roster is the tier's configured roster plus up to the tier's
     `extra-seats` seats picked by matching `add-seat` rules. Author and
     secretary are never in a roster.

PR text (title, labels) is attacker-controlled. It is data: it is never
interpolated into a shell, and anything echoed back is reduced to one
line with control characters stripped and a length cap. The reason string
is built from rule names and counts only.

Configuration: ~/.config/lkml/tiers.yaml, overridden by LKML_TIERS_FILE.
There is deliberately no fallback to any other location: a missing file
fails with the path it wanted. fleet/tiers.yaml in this repo is a fully
commented example. Globs match a whole repo-relative path: `**` spans
directories, `*` and `?` do not cross `/`, `[...]` is a character class.

Exit status: 0 an object was produced; 1 an input or config error (one
"Error:" line on stderr, nothing on stdout); 2 a usage error.

Python 3 with PyYAML (for the tiers file); everything else is stdlib.
"""

import json
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "Error: the tiers file is YAML, and parsing it needs the PyYAML\n"
        "python module, which this machine does not have. Install it\n"
        "(commonly packaged as python-yaml or python3-yaml).\n"
    )
    sys.exit(1)

USAGE = """\
Usage: lkml-pr-tier.py <repo> <range> --meta <file>
       lkml-pr-tier.py -h|--help"""

TIERS = ("quick", "standard", "full")
RANK = {t: i for i, t in enumerate(TIERS)}
FORBIDDEN_SEATS = ("author", "pr-author", "secretary")
SEAT_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
DEFAULT_SKIP_LABELS = ["lkml-skip"]
DEFAULT_FULL_LABELS = ["lkml-full", "lkml"]
TOP_KEYS = ("default-tier", "tiers", "labels", "docs-paths", "tests-paths",
            "dependency-manifests", "rules")
TIER_KEYS = ("roster", "needs-env", "budget", "extra-seats")
CONDITIONS = ("paths", "min-lines", "max-lines", "docs-only", "tests-only",
              "new-dependency")
EFFECTS = ("tier", "add-seat", "ambiguous")
REASON_CAP = 200


class InputError(Exception):
    pass


class UsageError(Exception):
    pass


# -- sanitizing -------------------------------------------------------

def sanitize_line(value, cap=REASON_CAP):
    """One line, controls stripped, whitespace collapsed, length-capped."""
    value = re.sub(r"\s+", " ", str(value))
    value = re.sub(r"[\x00-\x1f\x7f-\x9f]", "", value).strip()
    if len(value) > cap:
        value = value[:cap - 3].rstrip() + "..."
    return value


# -- config -----------------------------------------------------------

class DupKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses duplicate mapping keys (a duplicated key is
    a typo the operator would otherwise never see)."""


def _no_dup_mapping(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise InputError(f"duplicate key '{key}' "
                             f"(line {key_node.start_mark.line + 1})")
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


DupKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup_mapping)


def tiers_path():
    return os.environ.get("LKML_TIERS_FILE") or os.path.join(
        os.path.expanduser("~"), ".config", "lkml", "tiers.yaml")


def glob_to_regex(glob):
    out, i, n = [], 0, len(glob)
    while i < n:
        c = glob[i]
        if c == "*":
            if glob[i:i + 2] == "**":
                if glob[i:i + 3] == "**/":
                    out.append("(?:.*/)?")
                    i += 3
                else:
                    out.append(".*")
                    i += 2
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = glob.find("]", i + 2)
            if j < 0:
                out.append(re.escape(c))
            else:
                body = glob[i + 1:j]
                if body[0] in "!^":
                    body = "^" + body[1:]
                out.append("[" + body.replace("\\", "\\\\") + "]")
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


class Cfg:
    pass


def load_config():
    path = tiers_path()
    if not os.path.isfile(path):
        raise InputError(
            f"tiers file '{path}' does not exist; copy fleet/tiers.yaml "
            f"from the lkml-review checkout and edit it (LKML_TIERS_FILE "
            f"overrides the path)")

    def bad(where, msg):
        raise InputError(f"tiers file '{path}': {where}: {msg}")

    try:
        with open(path, encoding="utf-8") as fh:
            doc = yaml.load(fh, Loader=DupKeyLoader)
    except InputError as exc:
        raise InputError(f"tiers file '{path}': {exc}")
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as exc:
        raise InputError(f"tiers file '{path}': unreadable: "
                         f"{str(exc).splitlines()[0] if str(exc) else exc}")
    if not isinstance(doc, dict):
        bad("(top level)", "expected a mapping")
    for key in doc:
        if key not in TOP_KEYS:
            bad(key, "unknown key; the file takes " + ", ".join(TOP_KEYS))

    def seat(value, where):
        if not isinstance(value, str):
            bad(where, "expected a seat name")
        name = value.strip().lstrip("@")
        if not SEAT_RE.match(name):
            bad(where, f"'{value}' is not a valid seat name")
        if name in FORBIDDEN_SEATS:
            bad(where, f"'{name}' is not a panel member; author and "
                       f"secretary never sit on a roster")
        return name

    def str_list(value, where):
        if not isinstance(value, list) or not all(
                isinstance(v, str) and v for v in value):
            bad(where, "expected a list of non-empty strings")
        return value

    def globs(key):
        value = doc.get(key, [])
        return [(g, glob_to_regex(g)) for g in str_list(value, key)]

    cfg = Cfg()
    cfg.path = path

    cfg.default_tier = doc.get("default-tier")
    if cfg.default_tier not in TIERS:
        bad("default-tier", "takes " + ", ".join(TIERS))

    tiers = doc.get("tiers")
    if not isinstance(tiers, dict):
        bad("tiers", "expected a mapping of " + ", ".join(TIERS))
    for t in TIERS:
        if t not in tiers:
            bad(f"tiers.{t}", "missing; all of " + ", ".join(TIERS)
                + " are required")
    cfg.tiers = {}
    for t, body in tiers.items():
        if t not in TIERS:
            bad(f"tiers.{t}", "unknown tier; the tiers are "
                + ", ".join(TIERS))
        if not isinstance(body, dict):
            bad(f"tiers.{t}", "expected a mapping")
        for k in body:
            if k not in TIER_KEYS:
                bad(f"tiers.{t}.{k}", "unknown key; a tier takes "
                    + ", ".join(TIER_KEYS))
        roster = body.get("roster")
        if not isinstance(roster, list) or not roster:
            bad(f"tiers.{t}.roster", "expected a non-empty list of seats")
        seats = []
        for i, s in enumerate(roster):
            name = seat(s, f"tiers.{t}.roster[{i}]")
            if name in seats:
                bad(f"tiers.{t}.roster[{i}]", f"'{name}' listed twice")
            seats.append(name)
        env = body.get("needs-env", False)
        if not isinstance(env, bool):
            bad(f"tiers.{t}.needs-env", "expected true or false")
        budget = body.get("budget")
        if isinstance(budget, bool) or not isinstance(budget, int) \
                or budget <= 0:
            bad(f"tiers.{t}.budget", "expected a positive integer")
        extra = body.get("extra-seats", 0)
        if isinstance(extra, bool) or not isinstance(extra, int) or extra < 0:
            bad(f"tiers.{t}.extra-seats", "expected a non-negative integer")
        cfg.tiers[t] = {"roster": seats, "needs_env": env, "budget": budget,
                        "extra_seats": extra}

    labels = doc.get("labels", {})
    if labels is None:
        labels = {}
    if not isinstance(labels, dict):
        bad("labels", "expected a mapping with 'skip' and 'full'")
    for k in labels:
        if k not in ("skip", "full"):
            bad(f"labels.{k}", "unknown key; labels takes 'skip' and 'full'")

    def label_list(key, default):
        value = labels.get(key, default)
        if isinstance(value, str):
            value = [value]
        return [v.strip().lower() for v in str_list(value, f"labels.{key}")]

    cfg.skip_labels = label_list("skip", DEFAULT_SKIP_LABELS)
    cfg.full_labels = label_list("full", DEFAULT_FULL_LABELS)

    cfg.docs_paths = globs("docs-paths")
    cfg.tests_paths = globs("tests-paths")
    cfg.dep_manifests = globs("dependency-manifests")

    rules = doc.get("rules", [])
    if not isinstance(rules, list):
        bad("rules", "expected a list")
    cfg.rules, names = [], set()
    for i, r in enumerate(rules):
        where = f"rules[{i}]"
        if not isinstance(r, dict):
            bad(where, "expected a mapping")
        name = r.get("name")
        if not isinstance(name, str) or not name.strip():
            bad(f"{where}.name", "a rule needs a non-empty name")
        if name in names:
            bad(f"{where}.name", f"duplicate rule name '{name}'")
        names.add(name)
        where = f"rules[{name}]"
        for k in r:
            if k != "name" and k not in CONDITIONS + EFFECTS:
                bad(f"{where}.{k}", "unknown key; a rule takes "
                    + ", ".join(CONDITIONS + EFFECTS))
        rule = {"name": sanitize_line(name, 60), "paths": None,
                "min": None, "max": None, "docs_only": False,
                "tests_only": False, "new_dep": False,
                "tier": None, "add_seat": None, "ambiguous": False}
        if "paths" in r:
            rule["paths"] = [(g, glob_to_regex(g))
                             for g in str_list(r["paths"], f"{where}.paths")]
            if not rule["paths"]:
                bad(f"{where}.paths", "expected at least one glob")
        for key, slot in (("min-lines", "min"), ("max-lines", "max")):
            if key in r:
                v = r[key]
                if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                    bad(f"{where}.{key}", "expected a non-negative integer")
                rule[slot] = v
        for key, slot in (("docs-only", "docs_only"),
                          ("tests-only", "tests_only"),
                          ("new-dependency", "new_dep")):
            if key in r:
                if r[key] is not True:
                    bad(f"{where}.{key}", "takes true (omit the key "
                        "instead of setting false)")
                rule[slot] = True
        if not (rule["paths"] or rule["min"] is not None
                or rule["max"] is not None or rule["docs_only"]
                or rule["tests_only"] or rule["new_dep"]):
            bad(where, "has no condition; a rule that always matches "
                "is the default-tier's job")
        if "tier" in r:
            if r["tier"] not in TIERS:
                bad(f"{where}.tier", "takes " + ", ".join(TIERS))
            rule["tier"] = r["tier"]
        if "add-seat" in r:
            rule["add_seat"] = seat(r["add-seat"], f"{where}.add-seat")
        if "ambiguous" in r:
            if r["ambiguous"] is not True:
                bad(f"{where}.ambiguous", "takes true")
            rule["ambiguous"] = True
        if rule["tier"] is None and rule["add_seat"] is None:
            bad(where, "has no effect; it needs 'tier' or 'add-seat'")
        if rule["ambiguous"] and rule["tier"] is None \
                and rule["add_seat"] is None:
            bad(where, "'ambiguous' needs 'tier' or 'add-seat' beside it")
        cfg.rules.append(rule)
    return cfg


# -- metadata ---------------------------------------------------------

def read_meta(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise InputError(f"metadata file '{path}': {exc}")
    if not isinstance(doc, dict):
        raise InputError(f"metadata file '{path}': expected a JSON object")

    def typed(key, kind, default, what):
        if key not in doc or doc[key] is None:
            return default
        if not isinstance(doc[key], kind):
            raise InputError(f"metadata file '{path}': '{key}' must be {what}")
        return doc[key]

    labels = typed("labels", list, [], "a list of strings")
    if not all(isinstance(x, str) for x in labels):
        raise InputError(f"metadata file '{path}': 'labels' must be a "
                         f"list of strings")
    return {"title": sanitize_line(typed("title", str, "", "a string")),
            "draft": typed("draft", bool, False, "true or false"),
            "bot": typed("author-is-bot", bool, False, "true or false"),
            "labels": [l.strip().lower() for l in labels]}


# -- git --------------------------------------------------------------

def git(repo, *args):
    try:
        proc = subprocess.run(["git", "-C", repo, *args],
                              capture_output=True, check=False)
    except OSError as exc:
        raise InputError(f"cannot run git: {exc}")
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise InputError(f"git {args[0]} failed in '{repo}': "
                         f"{err[-1] if err else 'exit ' + str(proc.returncode)}")
    return proc.stdout.decode("utf-8", "replace")


def split_range(rng):
    for sep in ("...", ".."):
        if sep in rng:
            left, _, right = rng.partition(sep)
            if left and right and not left.startswith("-") \
                    and not right.startswith("-"):
                return left, right
    raise UsageError(f"range '{rng}' must be <base>..<head> or "
                     f"<base>...<head>")


def commits_of(repo, base, right):
    out = git(repo, "rev-list", "--reverse", "--no-merges",
              f"{base}..{right}", "--")
    return out.split()


def parse_numstat(text):
    diff = {}
    for rec in text.split("\0"):
        if not rec.strip():
            continue
        parts = rec.lstrip("\n").split("\t", 2)
        if len(parts) != 3:
            continue
        a, d, path = parts
        n = 0 if a == "-" or d == "-" else int(a) + int(d)
        diff[path] = diff.get(path, 0) + n
    return diff


def diff_of(repo, base, right):
    return parse_numstat(git(repo, "diff", "--numstat", "-z",
                             "--no-renames", base, right, "--"))


# -- rules ------------------------------------------------------------

def matches(globs, path):
    return any(rx.match(path) for _, rx in globs)


def signals_of(cfg, diff):
    paths = sorted(diff)
    return {
        "files": len(paths),
        "lines": sum(diff.values()),
        "docs_only": bool(paths) and bool(cfg.docs_paths)
        and all(matches(cfg.docs_paths, p) for p in paths),
        "tests_only": bool(paths) and bool(cfg.tests_paths)
        and all(matches(cfg.tests_paths, p) for p in paths),
        "new_dependency": any(matches(cfg.dep_manifests, p) for p in paths),
    }


def rule_matches(rule, sig, paths):
    if rule["paths"] is not None and not any(
            matches(rule["paths"], p) for p in paths):
        return None
    if rule["min"] is not None and sig["lines"] < rule["min"]:
        return None
    if rule["max"] is not None and sig["lines"] > rule["max"]:
        return None
    if rule["docs_only"] and not sig["docs_only"]:
        return None
    if rule["tests_only"] and not sig["tests_only"]:
        return None
    if rule["new_dep"] and not sig["new_dependency"]:
        return None
    # what fired, for the reason string: names and numbers only
    why = []
    if rule["paths"] is not None:
        why.append("paths")
    if rule["min"] is not None or rule["max"] is not None:
        why.append(f"lines {sig['lines']}")
    if rule["docs_only"]:
        why.append("docs-only")
    if rule["tests_only"]:
        why.append("tests-only")
    if rule["new_dep"]:
        why.append("new-dependency")
    return ", ".join(why)


def evaluate(cfg, diff, labels):
    """Tier one diff: rules, force-full, roster. Pure; no skip checks."""
    sig = signals_of(cfg, diff)
    paths = sorted(diff)
    matched = []
    for rule in cfg.rules:
        why = rule_matches(rule, sig, paths)
        if why is not None:
            matched.append((rule, why))
    forced = [l for l in labels if l in cfg.full_labels]
    named = [r["tier"] for r, _ in matched if r["tier"]]
    default_applied = False
    if forced:
        tier = "full"
    elif named:
        tier = max(named, key=RANK.get)
    else:
        tier, default_applied = cfg.default_tier, True
    roster = list(cfg.tiers[tier]["roster"])
    extras = []
    for rule, _ in matched:
        if len(extras) >= cfg.tiers[tier]["extra_seats"]:
            break
        s = rule["add_seat"]
        if s and s not in roster and s not in extras:
            extras.append(s)
    roster += extras
    ambiguous = (not forced) and any(r["ambiguous"] for r, _ in matched)
    if forced:
        reason = f"label {forced[0]} forces full"
        if matched:
            reason += "; rules: " + ", ".join(
                f"{r['name']} ({w})" for r, w in matched)
    elif matched and named:
        reason = "rules: " + ", ".join(
            f"{r['name']} ({w})" for r, w in matched)
    elif matched:
        reason = (f"no rule named a tier; default {tier}; seats from: "
                  + ", ".join(r["name"] for r, _ in matched))
    else:
        reason = f"no rule matched; default {tier}"
    return {
        "tier": tier, "roster": roster, "extras": extras,
        "ambiguous": ambiguous, "reason": reason, "paths": paths,
        "signals": {
            **sig,
            "labels": labels,
            "forced_full": bool(forced),
            "ambiguous": ambiguous,
            "default_tier_applied": default_applied,
            "rules_matched": [
                {"name": r["name"], "tier": r["tier"],
                 "add_seat": r["add_seat"], "ambiguous": r["ambiguous"]}
                for r, _ in matched],
            "extra_seats": extras,
        },
    }


def skip_of(cfg, meta):
    if meta["draft"]:
        return "draft"
    if meta["bot"]:
        return "bot-author"
    for label in meta["labels"]:
        if label in cfg.skip_labels:
            return "label:" + sanitize_line(label, 60)
    return None


def classify(cfg, repo, rng, meta):
    left, right = split_range(rng)
    skip = skip_of(cfg, meta)
    result = {"decision": "skip" if skip else "review", "skip_reason": skip,
              "tier": None, "roster": None, "needs_env": None,
              "budget": None, "reason": "", "title": meta["title"],
              "signals": None, "push": None}
    if skip:
        result["reason"] = f"skipped: {skip}"
        return result
    if not os.path.isdir(repo):
        raise InputError(f"repo '{repo}' is not a directory")
    git(repo, "rev-parse", "--git-dir")
    base = git(repo, "merge-base", left, right).strip()
    commits = commits_of(repo, base, right)
    if not commits:
        raise InputError(f"range '{rng}' holds no commits to review")
    ev = evaluate(cfg, diff_of(repo, base, right), meta["labels"])
    ev["signals"]["commits"] = len(commits)
    tier = cfg.tiers[ev["tier"]]
    result.update(tier=ev["tier"], roster=ev["roster"],
                  needs_env=tier["needs_env"], budget=tier["budget"],
                  reason=sanitize_line(ev["reason"]), signals=ev["signals"])
    return result


# -- command line -----------------------------------------------------

def parse_args(argv):
    pos, meta = [], None
    it = iter(argv)
    for a in it:
        if a in ("-h", "--help"):
            print(__doc__.rstrip())
            sys.exit(0)
        elif a == "--meta":
            meta = next(it, None)
            if meta is None:
                raise UsageError("--meta needs a file")
        elif a.startswith("-"):
            raise UsageError(f"unknown option '{a}'")
        else:
            pos.append(a)
    if len(pos) != 2:
        raise UsageError("expected <repo> <range>")
    if meta is None:
        raise UsageError("--meta <file> is required")
    return pos[0], pos[1], meta


def main(argv):
    try:
        repo, rng, meta_path = parse_args(argv)
        split_range(rng)
        cfg = load_config()
        result = classify(cfg, repo, rng, read_meta(meta_path))
    except UsageError as exc:
        sys.stderr.write(f"Error: {exc}\n{USAGE}\n")
        return 2
    except InputError as exc:
        sys.stderr.write(f"Error: {exc}\n")
        return 1
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
