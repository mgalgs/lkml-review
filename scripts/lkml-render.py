#!/usr/bin/env python3
"""lkml-render.py — render one or more lkml-mode series mailboxes as a
single-file HTML page, or as plain text for agents.

Usage: lkml-render.py <series-dir> [<series-dir> ...] > out.html
       lkml-render.py --text <series-dir> [<series-dir> ...] > out.txt
       lkml-render.py --text --version N <series-dir> > out.txt

The HTML is one file: all markup and styles are inlined. The only
external dependency is the typefaces, loaded from the Google Fonts
CDN (Archivo, Source Serif 4, JetBrains Mono); on a machine without
network the page renders in the local fallback stacks the --ui / --read
/ --mono tokens declare.

The default HTML render is the human view: a sticky state rail (the
version list with the current version marked aria-current, a
reviewer-to-verdict matrix, a per-patch verdict matrix, and an
open-thread counter block) beside a main column that carries, in
order, a blocking banner (a standing NAK, or every open thread sitting
on one patch), the auto-summary card when a per-version results file
exists, and the thread itself. The thread is an expandable trace: every
message collapses to one scannable line (persona monogram, name, short
id, verdict chip, subject) and opens in place. Depth is an indent plus
a hairline rail. Patch bodies show the stat line with the diff folded.
Verdicts are chips that encode strength in form as well as hue: a
solid green Reviewed-by, the same hue hollow for the weaker Acked-by,
amber for Changes-requested, hollow amber for a Question, and a solid
red NAK. The blue accent is structural chrome only, never a verdict.
An unrecorded model is stamped 'model unknown' in the warning colour on
purpose -- surfacing a real defect, not hiding it. Fleet-store messages
carry no model header at all (that format never stamps one), so their
model chip is omitted instead: uniform absence is not an anomaly.

--text is the agent view and a stable interface consumed by
lkml-round.sh and lkml-summarize.sh: the same thread selection and
ordering as plain text on stdout, with message bodies indented under
their headers (so a body cannot forge a message header) and [PATCH]
message bodies cut at their first diff --git line, so the commit
message and diffstat stay and the diff goes (it lives in the series
branch). The HTML path may be redesigned freely; --text must not
change out from under the panel scripts.

Every HTML render also embeds one <script type="application/json"
id="lkml-thread"> block, just before </body>: schema "lkml-thread/1",
a reproducible rendered_at stamp, and one entry per SERIES_DIR with its
version/cover list, every parsed message (id, persona, role, model,
date, tags, patch position, verbatim body), and that dir's exact
--text render under "text". It lets an agent read the whole thread
without parsing the HTML and without lkml-review installed. Like
--text, this block is a stable interface: the HTML's visible layout
and CSS may still be redesigned freely, but the block cannot change
shape without bumping the schema id.

--text --version N restricts the render to one version's own section
(exactly what the whole-series --text render prints for that version,
byte for byte) plus, only when any exist, a late-replies block:
messages that structurally belong to an earlier version's thread but
were posted while vN was current -- a reviewer answering a still-open
point on an old thread rather than the new one. Valid only with --text
and exactly one SERIES_DIR; an unknown N refuses, naming the versions
that do exist.

A series dir is either $LKML_MAILBOX_ROOT/<series> (it holds cur/*.msg,
the old layout) or a fork-sandbox agent-mail thread dir,
<mail-root>/threads/<thread-id> (it holds NNN-<uuid>.msg directly, the
fleet-store layout); build() tells the two apart by the presence of
cur/. Reads only; never runs git.

--assume-root-version N applies to the fleet layout only. A thread
kicked off before lkml-fleet-kickoff.sh stamped a version marker has a
root whose Subject carries no '[PATCH vN 0/M]' bracket, so it opens no
version and its whole subtree renders under none -- which
require_full_coverage refuses outright, leaving the thread unrenderable
however many marked versions are posted into it later. The flag says
which version that root opened and is read as the missing marker,
nothing else: version boundaries, tallies and chips all flow through
the usual logic. A root that does carry a marker keeps it and the flag
is ignored. Without the flag the render is byte-identical, refusal
included, and the flag never disarms require_full_coverage -- a genuine
cycle or orphan still fails loudly.

SOURCE_DATE_EPOCH, when set, pins the 'rendered' stamp to that epoch (UTC)
so repeated HTML renders are reproducible; without it the stamp is the
local wall clock. It affects only the HTML backend; --text is
unaffected.

When a series dir holds results-v<N>.md (the per-version results file,
written by the summarizer; a results-v<N>.json may sit next to it and
is ignored except for the card's presence when the .md is absent), the
HTML render adds an auto-summary card above the thread: the "# Summary"
section sits in the visible card head, the "# Details" section inside a
fold, and 7-hex message-id tokens that match a message in the mailbox
link to that message. --text prints the same sections as a bare
'results' block (no links); an empty section is omitted in both
backends. Without any results file there is no card at all.

When a series dir holds results-series.md (the whole-series narrative,
written by the summarizer's --series mode), the HTML render adds a
page-level card directly above the series' own shell. Its id autolink
map covers ALL versions' messages in the series dir. --text prints it
as a 'series-summary' block at the very top, before the first version
section. Without the file the render is byte-identical to a mailbox
without it.
"""
import html
import base64
import json
import mimetypes
import os
import re
import sys
import argparse
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

TAG_ORDER = ["Reviewed-by", "Acked-by", "Tested-by", "Changes-requested", "Question", "NAK"]
TAG_CLASS = {
    "Reviewed-by": "t-rev", "Acked-by": "t-ack", "Tested-by": "t-test", "Changes-requested": "t-chg",
    "Question": "t-q", "NAK": "t-nak",
}
TAG_GLYPH = {"Reviewed-by": "R", "Acked-by": "A", "Tested-by": "T", "Changes-requested": "C",
             "Question": "?", "NAK": "N"}

# Verdict strength order, strongest first: a NAK outranks a
# Changes-requested, which outranks a Question, which outranks a
# sign-off; among the sign-offs Reviewed-by is the strongest claim,
# then Acked-by, then Tested-by (the same strength the chips encode
# in form: solid green over hollow green).
TAG_PRIORITY = ["NAK", "Changes-requested", "Question", "Reviewed-by", "Acked-by", "Tested-by"]
# Tags that close a thread (the sign-offs). A thread whose subtree
# carries none of these is still open.
POSITIVE_TAGS = {"Reviewed-by", "Acked-by", "Tested-by"}
# Chip class and label per tag. Strength is encoded in form as well as
# hue: Reviewed-by is solid green, Acked-by the same hue but hollow,
# Changes-requested amber, Question hollow amber, NAK solid red.
CHIP_CLASS = {
    "Reviewed-by": "reviewed", "Acked-by": "acked", "Tested-by": "tested",
    "Changes-requested": "changes", "Question": "question", "NAK": "nak",
}
CHIP_LABEL = {
    "Reviewed-by": "reviewed-by", "Acked-by": "acked-by", "Tested-by": "tested-by",
    "Changes-requested": "changes", "Question": "question", "NAK": "nak",
}
# A small hand-picked palette for persona monograms: a stable hash of the
# persona name picks one, so any roster renders, the same persona gets
# the same colour twice in one page, and the colour is stable between
# runs for the same persona (djb2 over the name, not the per-process
# randomized hash()).
MONOGRAM_PALETTE = [
    "#6d3fb8", "#1f7a5f", "#b4560e", "#2b3a42",
    "#b32218", "#2f6fec", "#7a5c10", "#5c3d7a",
]


def inline_attachment(ref, attachment_root):
    """Resolve an X-Attachment value (e.g. 'attachments/foo.patch')
    against ATTACHMENT_ROOT into a data: URI, containment-checked with
    realpath so a hand-written or stale reference cannot escape the
    dir. Returns (href, mime); href is None when the reference does not
    resolve to a real file inside attachment_root -- the caller renders
    that as present/missing, not as a link either way."""
    rel = ref.removeprefix("attachments/") if ref.startswith("attachments/") else ""
    candidate = os.path.normpath(os.path.join(attachment_root, rel)) if rel else ""
    root_real = os.path.realpath(attachment_root)
    candidate_real = os.path.realpath(candidate) if candidate else ""
    inside = candidate and os.path.commonpath((candidate_real, root_real)) == root_real
    mime = "application/octet-stream"
    if inside and os.path.isfile(candidate_real):
        with open(candidate_real, "rb") as f:
            data = f.read()
        mime = mimetypes.guess_type(candidate_real)[0] or mime
        return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}", mime
    return None, mime


def read_msg(path, attachment_root):
    with open(path, encoding="utf-8", errors="replace") as f:
        raw = f.read()
    head, _, body = raw.partition("\n\n")
    hdr = {}
    attachments = []
    for line in head.splitlines():
        k, _, v = line.partition(": ")
        if k == "X-Attachment":
            attachments.append(v.strip())
        else:
            hdr[k] = v
    mid = strip_id(hdr.get("Message-ID", ""))
    parent = strip_id(hdr.get("In-Reply-To", ""))
    try:
        seq = int(hdr.get("X-Seq", "0"))
    except ValueError:
        seq = 0
    try:
        date = parsedate_to_datetime(hdr.get("Date", ""))
    except Exception:
        date = None
    tags = [t.strip() for t in hdr.get("X-Tags", "").split(",") if t.strip()]
    # The mailbox writes attachments/<basename>. inline_attachment is
    # defensive in case a hand-written message contains an unsafe or
    # stale reference.
    rendered_attachments = []
    for ref in attachments:
        href, mime = inline_attachment(ref, attachment_root)
        rendered_attachments.append({"ref": ref, "href": href, "mime": mime})
    return {
        "id": mid, "parent": parent, "seq": seq, "date": date,
        "from": hdr.get("From", ""), "subject": hdr.get("Subject", ""),
        "persona": hdr.get("X-AI-Persona", ""), "harness": hdr.get("X-AI-Harness", ""),
        "network": hdr.get("X-AI-Network", ""),
        "model": hdr.get("X-AI-Model", ""), "version": int(hdr.get("X-Version", "1") or 1),
        "depth": int(hdr.get("X-Depth", "0") or 0), "tags": tags, "body": body,
        "attachments": rendered_attachments,
        "children": [],
    }


def strip_id(v):
    v = v.strip()
    if v.startswith("<"):
        v = v[1:]
    if v.endswith(">"):
        v = v[:-1]
    return v.split("@", 1)[0]


def fleet_body_tags(body):
    """Verdict tags for a fleet-format message, parsed OUT OF THE BODY
    (this format stamps no X-Tags header). Ports lkml-fleet-status.sh's
    fs_body_tags awk exactly: quoted/blank lines are skipped, the three
    '-by' trailers count if ANY surviving line starts with 'Name:', the
    three verdict-only trailers count only if the FIRST or LAST
    surviving line starts with the name followed by whitespace, a
    punctuation mark, or end of line."""
    lines = [ln for ln in body.splitlines()
             if ln.strip() and not re.match(r"^\s*>", ln)]
    if not lines:
        return []
    trailers = TAG_ORDER[:3]   # Reviewed-by, Acked-by, Tested-by
    verdicts = TAG_ORDER[3:]   # Changes-requested, Question, NAK
    seen = [t for t in trailers if any(ln.startswith(t + ":") for ln in lines)]
    first, last = lines[0], lines[-1]
    for v in verdicts:
        pat = re.compile(r"^" + re.escape(v) + r"([\s:.!,]|$)")
        if pat.match(first) or pat.match(last):
            seen.append(v)
    return seen


COVER_BRACKET_RE = re.compile(r"^\[([^\]]*)\]")


def is_cover_subject(subject):
    """True when SUBJECT's leading bracket carries the word PATCH --
    '[PATCH ...]', but also qualified forms real list traffic (and
    lkml-fleet-kickoff.sh's own subject pass-through, see its --version
    header comment) uses verbatim: '[RFC PATCH v3 0/2]', '[PATCH
    net-next v2 0/2]'. Anchored on the word, not a literal '[PATCH '
    prefix, so a qualifier before or after PATCH does not drop a real
    series cover out of the render. Strips 'Re: ' layers first, the same
    normalization fleet_version does -- nothing on this transport
    enforces an un-prefixed Subject on a version-opening post (a wake
    stanza's Subject is passed to `mail reply --subject` verbatim, and
    every persona file models a reply as 'Subject: Re: ...'), so a cover
    that arrives as 'Re: [PATCH v3 0/1] ...' must still be recognized as
    one."""
    subj = subject
    while subj.startswith("Re: "):
        subj = subj[4:]
    mm = COVER_BRACKET_RE.match(subj)
    return bool(mm and re.search(r"\bPATCH\b", mm.group(1)))


def fleet_version(subject, default=1):
    """The version marker from a fleet message's own subject (stripped
    of any Re: layers): the v<N> token inside a leading bracket that
    carries the word PATCH, or `default` when the bracket carries no
    such token or no PATCH word at all -- fleet messages carry no
    X-Version header, unlike the old layout. Every caller but one takes
    the default of 1; build_fleet_layout's --assume-root-version check
    passes None, to tell an unmarked subject apart from one that really
    says v1. NOT the same parse as lkml-fleet-status.sh's
    fs_subject_versions(): that one greps v[0-9]+ across the WHOLE
    subject and returns every match it finds, where this one looks only
    inside the leading bracket and returns a single value. The narrower
    parse here is deliberate -- it is immune to a stray 'v4l2' or 'v6.12'
    token elsewhere in the subject that --allow-ambiguous-version lets
    through -- but it means the two parses can disagree on a subject
    fs_subject_versions() would call ambiguous. A qualifier before or
    after PATCH ('[RFC PATCH v3 0/2]', '[PATCH net-next v2 0/2]') must
    not make the parse fall back to 1, the same reason is_cover_subject
    does not require a literal '[PATCH ' prefix. The leading
    non-alphanumeric guard on 'v' keeps a token like 'v4' inside a word
    (e.g. an 'IPv4' mention) from being mistaken for a version marker."""
    subj = subject
    while subj.startswith("Re: "):
        subj = subj[4:]
    mm = COVER_BRACKET_RE.match(subj)
    if not mm or not re.search(r"\bPATCH\b", mm.group(1)):
        return default
    vm = re.search(r"(?:^|[^A-Za-z0-9])v(\d+)", mm.group(1))
    return int(vm.group(1)) if vm else default


PATCH_INDEX_RE = re.compile(r"^\[PATCH (?:v\d+ )?(\d+)/(\d+)\]")


def patch_index_total(subject):
    """(i, K) from a '[PATCH vN i/K] ...' subject (Re: layers stripped),
    or None when the subject is not that shape. A cover ('.../0/K') and
    a patch ('.../i/K', i >= 1) both match this -- is_cover_subject
    cannot tell them apart (it only checks for the word PATCH in the
    bracket), so callers that need the distinction compare the index."""
    subj = subject
    while subj.startswith("Re: "):
        subj = subj[4:]
    mm = PATCH_INDEX_RE.match(subj)
    return (int(mm.group(1)), int(mm.group(2))) if mm else None


def esc(s):
    return html.escape(s, quote=True)


def inline(s):
    s = esc(s)
    s = re.sub(r"`([^`]+)`", r"<code class=\"inline\">\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    return s


TRAILER_RE = re.compile(r"^(Reviewed-by|Acked-by|Tested-by|Reported-by|Changes-requested|Question)(:.*)?$")
NAK_RE = re.compile(r"^NAK([\s:.!,].*)?$")


def render_prose(text):
    """Small markdown: headings, fences, quotes, lists, paragraphs, trailers."""
    out = []
    lines = text.splitlines()
    i = 0
    para = []

    def flush_para():
        nonlocal para
        if para:
            out.append("<p>" + " ".join(inline(x) for x in para) + "</p>")
            para = []

    while i < len(lines):
        ln = lines[i]
        if ln.startswith("```"):
            flush_para()
            j = i + 1
            block = []
            while j < len(lines) and not lines[j].startswith("```"):
                block.append(lines[j])
                j += 1
            out.append("<pre class=\"code\">" + esc("\n".join(block)) + "</pre>")
            i = j + 1
            continue
        if ln.startswith(">"):
            flush_para()
            block = []
            while i < len(lines) and lines[i].startswith(">"):
                block.append(re.sub(r"^>\s?", "", lines[i]))
                i += 1
            out.append("<blockquote>" + render_prose("\n".join(block)) + "</blockquote>")
            continue
        m = re.match(r"^(#{1,6})\s+(.*)$", ln)
        if m:
            flush_para()
            lvl = min(len(m.group(1)) + 2, 6)
            out.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>")
            i += 1
            continue
        if re.match(r"^\s*([-*]|\d+\.)\s+", ln):
            flush_para()
            items = []
            ordered = bool(re.match(r"^\s*\d+\.", ln))
            while i < len(lines) and re.match(r"^\s*([-*]|\d+\.)\s+", lines[i]):
                item = re.sub(r"^\s*([-*]|\d+\.)\s+", "", lines[i])
                i += 1
                while i < len(lines) and lines[i].startswith(("  ", "\t")) and lines[i].strip():
                    item += " " + lines[i].strip()
                    i += 1
                items.append("<li>" + inline(item) + "</li>")
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(items) + f"</{tag}>")
            continue
        if TRAILER_RE.match(ln) or NAK_RE.match(ln):
            flush_para()
            name = ln.split(":", 1)[0].split(" ", 1)[0]
            cls = TAG_CLASS.get(name, "t-q")
            out.append(f"<p class=\"trailer {cls}\">{esc(ln)}</p>")
            i += 1
            continue
        if not ln.strip():
            flush_para()
            i += 1
            continue
        para.append(ln)
        i += 1
    flush_para()
    return "\n".join(out)


def render_diff(text):
    out = []
    for ln in text.splitlines():
        cls = ""
        if ln.startswith("diff --git"):
            cls = "d-file"
        elif ln.startswith("+++") or ln.startswith("---"):
            cls = "d-meta"
        elif ln.startswith("@@"):
            cls = "d-hunk"
        elif ln.startswith("+"):
            cls = "d-add"
        elif ln.startswith("-"):
            cls = "d-del"
        out.append(f"<span class=\"{cls}\">{esc(ln)}</span>" if cls else esc(ln))
    return "<pre class=\"diff\">" + "\n".join(out) + "</pre>"


def render_patch_body(body):
    """A [PATCH] message body is format-patch output: mail headers, commit
    message, '---', diffstat + diff. Show the message as prose and fold
    the diff under the stat line."""
    msg, sep, diff = body.partition("\n---\n")
    # drop format-patch's own From/From:/Date:/Subject: header block
    parts = msg.split("\n\n", 1)
    commit_msg = parts[1] if len(parts) == 2 and parts[0].startswith("From ") else msg
    out = [render_prose(commit_msg)]
    if sep:
        stat, _, rest = diff.partition("\n\ndiff --git")
        out.append("<pre class=\"stat\">" + esc(stat.strip()) + "</pre>")
        if rest:
            out.append("<details class=\"fold\"><summary>show diff</summary>"
                       + render_diff("diff --git" + rest) + "</details>")
    return "\n".join(out)


def strongest_tag(tags):
    """The strongest tag in a set, per TAG_PRIORITY, or None."""
    for t in TAG_PRIORITY:
        if t in tags:
            return t
    return None


def chip_html(tag):
    """The verdict chip for one tag; '' when the tag maps to no chip.
    A message with no verdict renders no chip at all, never an empty
    one."""
    cls = CHIP_CLASS.get(tag)
    if not cls:
        return ""
    return f'<span class="chip {cls}">{CHIP_LABEL[tag]}</span>'


def mono_color(persona):
    """A stable palette index per persona name (djb2; not hash(), which
    is salted per process)."""
    if not persona:
        return 0
    h = 5381
    for ch in persona:
        h = ((h * 33) + ord(ch)) & 0xFFFFFFFF
    return h % len(MONOGRAM_PALETTE)


def monogram(persona):
    """The monogram letters for a persona: the first letter of each
    word, two wide ('core-team' -> 'CT'), or the first two characters
    of one long word; 'AI' for an un-stamped message."""
    if not persona:
        return "AI"
    words = [w for w in re.split(r"[-_ ]+", persona) if w]
    letters = "".join(w[0] for w in words)[:2] or persona[:2]
    return letters.upper()


def badge(persona):
    cls = "" if persona else " mono-none"
    return f'<span class="mono-badge{cls} p-color-{mono_color(persona)}">{esc(monogram(persona))}</span>'


def build_old_layout(series_dir):
    name = os.path.basename(series_dir.rstrip("/"))
    cur = os.path.join(series_dir, "cur")
    msgs = {}
    for fn in sorted(os.listdir(cur)):
        if fn.endswith(".msg"):
            m = read_msg(os.path.join(cur, fn), os.path.join(series_dir, "attachments"))
            msgs[m["id"]] = m
    roots = []
    for m in msgs.values():
        p = msgs.get(m["parent"]) if m["parent"] else None
        if p:
            p["children"].append(m)
        else:
            roots.append(m)
    for m in msgs.values():
        m["children"].sort(key=lambda x: (x["seq"], x["date"] or datetime.min))
    roots.sort(key=lambda x: (x["version"], x["seq"]))
    # The old layout has no nested-version-boundary concept: every
    # posting is already its own structural root, so "version roots"
    # (what render_series/render_text_series iterate to find each
    # version's own top-level messages) is just `roots` itself.
    return name, msgs, roots, roots


def fleet_addr_list(raw):
    """An address-list header value split into bare seat names
    ('@core, @docs' -> ['core', 'docs']), the same '@' stripping
    read_fleet_msg gives From:. Used both for To:/Cc: and for the
    thread root's X-Seats -- the same canonical address-list format,
    per fork-sandbox-mail.sh's mail_validate_addr_list."""
    return [a.strip().removeprefix("@") for a in raw.split(",") if a.strip()]


FLEET_MSG_RE = re.compile(r"^\d{3}-.*\.msg$")


def fleet_msg_paths(thread_dir):
    """.msg files directly in a fleet thread dir, sorted by the NNN-
    arrival prefix: Date has only 1s resolution and two replies can
    land in the same second, so the filename, not Date, is the
    authoritative sibling order. The other entries a real thread dir
    holds -- attachments/ and the NNN.seq sequence-number reservation
    dirs mail_place_message() mkdir's and never removes -- never match
    FLEET_MSG_RE and are silently skipped. (Router state lives at
    $FORK_SANDBOX_MAIL_ROOT/.postmaster/, one level up from the threads/
    dir entirely, never inside a thread dir.)"""
    return sorted(fn for fn in os.listdir(thread_dir) if FLEET_MSG_RE.match(fn))


def read_fleet_msg(path, seq, attachment_root):
    """One fleet-store message: <mail-root>/threads/<tid>/NNN-<uuid>.msg,
    RFC-5322-shaped. Message-ID/In-Reply-To are bare uuids (opaque,
    compared as-is -- no angle brackets to strip). From is '@name'; the
    leading '@' is stripped into the seat name build() and who_of() both
    key off (stored in both 'from' and 'persona' so who_of needs no
    change). No X-AI-Persona/Harness/Model/Network headers exist in this
    format -- render_message's fleet branch covers the model chip.
    X-Tags does not exist either -- tags come from the body via
    fleet_body_tags, the same trailers lkml-fleet-status.sh reads.
    depth and version are filled in by build_fleet_layout (depth needs
    the whole tree; version reads the subject via fleet_version).
    Attachments live at <tid>/attachments/<basename>, the same
    attachments/<basename> shape the old layout uses, just rooted at
    the thread dir instead of the series dir -- inline_attachment
    resolves them the same way in both layouts; only the displayed
    label differs (the bare basename here, ref elsewhere). x_seats is
    the raw X-Seats header value, unparsed: only render_series may
    interpret it, and only when this message is the thread root."""
    with open(path, encoding="utf-8", errors="replace") as f:
        raw = f.read()
    head, _, body = raw.partition("\n\n")
    hdr = {}
    attachments = []
    for line in head.splitlines():
        k, _, v = line.partition(": ")
        if k == "X-Attachment":
            v = v.strip()
            ref = v.removeprefix("attachments/") if v.startswith("attachments/") else v
            href, mime = inline_attachment(v, attachment_root)
            attachments.append({"ref": ref, "href": href, "mime": mime})
        else:
            hdr[k] = v
    who = hdr.get("From", "").strip().removeprefix("@")
    subject = hdr.get("Subject", "")
    try:
        date = parsedate_to_datetime(hdr.get("Date", ""))
    except Exception:
        date = None
    return {
        "id": hdr.get("Message-ID", "").strip(),
        "parent": hdr.get("In-Reply-To", "").strip(),
        "seq": seq, "date": date,
        "from": who, "subject": subject,
        "persona": who, "harness": "", "network": "", "model": "",
        "version": fleet_version(subject),
        "depth": 0, "tags": fleet_body_tags(body), "body": body,
        "attachments": attachments, "children": [], "fleet": True,
        "to": fleet_addr_list(hdr.get("To", "")),
        "cc": fleet_addr_list(hdr.get("Cc", "")),
        "x_seats": hdr.get("X-Seats"),
    }


def build_fleet_layout(series_dir, assume_root_version=None):
    name = os.path.basename(series_dir.rstrip("/"))
    attachment_root = os.path.join(series_dir, "attachments")
    msgs = {}
    for fn in fleet_msg_paths(series_dir):
        m = read_fleet_msg(os.path.join(series_dir, fn), int(fn[:3]), attachment_root)
        if not m["id"] or m["id"] in msgs:
            raise ValueError(
                f"{series_dir}: {fn} has a missing or duplicate Message-ID "
                f"({m['id'] or '<empty>'}); cannot key the thread tree on it"
            )
        msgs[m["id"]] = m
    roots = []
    for m in msgs.values():
        p = msgs.get(m["parent"]) if m["parent"] else None
        if p:
            p["children"].append(m)
        else:
            roots.append(m)
    # The author posts a version's cover and every one of its patches
    # with the SAME Reply-To-Id -- the wake's trigger -- because an
    # outbox file cannot reference a sibling file's not-yet-assigned id
    # (fleet/personas/author.md, decision 1). Structurally that makes a
    # patch a SIBLING of its cover, not a child of it: without this
    # repair each '[PATCH vN i/K]' patch would open its own version
    # (the depth reset below fires on any child whose version exceeds
    # its parent's), landing with zero patches and its diff unfolded --
    # the same body-size failure this whole posting format exists to
    # cure. Re-parent a patch under its sibling cover before depth is
    # computed, so it renders at depth 1 exactly like a patch nested
    # under its cover already is (the kickoff's own cover-then-reply
    # posting, where this loop is a no-op: the cover is each patch's
    # direct parent there, not a sibling to search for).
    for m in list(msgs.values()):
        idx = patch_index_total(m["subject"])
        p = msgs.get(m["parent"]) if m["parent"] else None
        if not idx or idx[0] == 0 or p is None:
            continue
        cover = next((s for s in p["children"]
                      if s is not m and s["version"] == m["version"]
                      and patch_index_total(s["subject"]) == (0, idx[1])), None)
        if cover is None:
            continue
        p["children"].remove(m)
        cover["children"].append(m)
        m["parent"] = cover["id"]
    for m in msgs.values():
        m["children"].sort(key=lambda x: (x["seq"], x["date"] or datetime.min))

    # An unmarked root opens no version, so its whole subtree renders
    # under none; --assume-root-version supplies the missing marker (a
    # real one wins). THE root only -- an orphan whose In-Reply-To did
    # not resolve is a root here too, and must still fail the coverage
    # guard rather than be read as a cover.
    if assume_root_version is not None:
        for r in roots:
            if r["parent"] or fleet_version(r["subject"], default=None) is not None:
                continue
            r["version"] = assume_root_version
            r["assumed_cover"] = True

    # A message whose OWN subject is a fresh [PATCH ...] cover starts a
    # new version's thread section even when it is structurally a reply
    # (the thread id is fixed to the root message, so v2 and later are
    # always replies, never roots): its depth resets to 0 the same way
    # a real root's does, and it is collected into version_roots
    # alongside the true root(s), so every version-scoped walk
    # downstream (tally, open-thread detection, the trace render) can
    # start from its own cover and see its own subtree numbered from 0.
    # Walking down from `roots` (never from a raw depth==0 scan over
    # ALL messages) is what keeps a reference cycle out of
    # version_roots: two messages that are each other's In-Reply-To are
    # each other's children and neither is a root, so this walk never
    # reaches either one, and require_full_coverage catches the drop.
    version_roots = []

    def set_depth(m, d, is_version_root):
        m["depth"] = d
        if is_version_root:
            version_roots.append(m)
        for c in m["children"]:
            # Boundary is version-based, not subject-shape-based: a
            # reply whose OWN version exceeds its parent's opens a new
            # version regardless of a 'Re: ' prefix -- is_cover_subject
            # alone would miss a real v3 posted as 'Re: [PATCH v3 0/1]
            # ...' (see is_cover_subject's docstring) and silently fold
            # it into the previous version's thread and tally. Both
            # sides' "version" fields already come from fleet_version,
            # which strips 'Re: ' layers itself, so this comparison is
            # immune to the prefix on its own. This is also how
            # lkml-fleet-status.sh attributes messages to versions --
            # by the version marker in the message's own Subject, not
            # by whether that Subject looks like a fresh cover.
            opens_version = c["version"] > m["version"]
            set_depth(c, 0 if opens_version else d + 1, opens_version)
    for r in roots:
        set_depth(r, 0, True)
    roots.sort(key=lambda x: (x["version"], x["seq"]))
    version_roots.sort(key=lambda x: (x["version"], x["seq"]))
    return name, msgs, roots, version_roots


def build(series_dir, assume_root_version=None):
    # assume_root_version is a fleet-path escape hatch; the old layout
    # has a real X-Version header, so it ignores the flag, not errors.
    if os.path.isdir(os.path.join(series_dir, "cur")):
        return build_old_layout(series_dir)
    if os.path.isdir(series_dir) and any(
            FLEET_MSG_RE.match(fn) for fn in os.listdir(series_dir)):
        return build_fleet_layout(series_dir, assume_root_version)
    return build_old_layout(series_dir)


def require_fleet_covers(series_dir, msgs, covers):
    """A fleet thread that parsed real messages but found no [PATCH ...]
    cover among its version roots (the structural root plus any later
    reply that itself opens a new version) is not a render bug to paper
    over -- it is either a genuine non-series discussion or a cover
    subject this render mis-parsed, and either way a silent
    zero-message page is the false green CLAUDE.md warns about: --text
    is the interface lkml-round.sh and lkml-summarize.sh consume, and
    an empty render is indistinguishable from a quiet round to them.
    The old layout raises the same way it always has (FileNotFoundError
    on a missing cur/), so this only adds a diagnostic where fleet
    parsing used to have none at all."""
    if covers or not msgs:
        return
    if not any(m.get("fleet") for m in msgs.values()):
        return
    raise ValueError(
        f"{series_dir}: fleet thread has {len(msgs)} message(s) but no "
        "[PATCH ...] cover letter at the root; not a series lkml-render "
        "can show"
    )


def require_full_coverage(series_dir, msgs, rendered_ids):
    """Every message build() parsed must show up under some version's
    render, or the thread tree is silently dropping one -- a reference
    cycle (each message resolves as the other's child, so neither
    becomes a root and neither is reachable from one), or a root whose
    own version matches no [PATCH ...] cover's version (an unresolvable
    In-Reply-To, or a stray subject on an orphaned reply). Both are
    exit-0-with-a-message-missing today; a standing NAK silently
    dropped is exactly the false green CLAUDE.md warns about. This
    fires for the old layout too (the same silent-drop shape is
    possible there), not just fleet threads."""
    missing = set(msgs) - rendered_ids
    if not missing:
        return
    raise ValueError(
        f"{series_dir}: {len(missing)} of {len(msgs)} parsed message(s) never "
        "rendered under any version (an unreachable reference cycle, or a "
        "root whose version matches no [PATCH ...] cover): "
        + ", ".join(sorted(m[:7] for m in missing))
    )


def subtree(m):
    yield m
    for c in m["children"]:
        yield from subtree(c)


def subtree_before(m, stop_ids):
    """Walk a thread, stopping before any nested patch root or, for a
    fleet thread, any nested reply that itself opens a new version."""
    yield m
    for c in m["children"]:
        if c["id"] in stop_ids:
            continue
        yield from subtree_before(c, stop_ids)


def tally(cover, boundary_ids=frozenset()):
    """Latest tag per persona per patch (and the cover), in cover order.
    boundary_ids is every OTHER version's cover id (empty for the old
    layout, where a later version is never nested under this one) --
    the walk stops there so a later version's messages, and its own
    cover, are never counted as this version's patches or replies."""
    rows = []
    personas = {}
    # A child's subject starting with '[PATCH' is a same-version patch
    # in both layouts now: the old layout's real '[PATCH vN i/M]'
    # message always shares its cover's one X-Version, and a fleet
    # patch does too once build_fleet_layout's sibling repair has
    # re-parented it here. The only other child this can match is a
    # later version's own cover reply ('[PATCH v3 0/1] ...'), which
    # never shares THIS cover's version -- the version check is what
    # tells the two apart.
    targets = [cover] + [c for c in cover["children"]
                         if c["subject"].startswith("[PATCH") and c["version"] == cover["version"]]
    patch_roots = {c["id"] for c in targets[1:]}
    for t in targets:
        latest = {}
        stop = (patch_roots | boundary_ids) if t is cover else boundary_ids
        walk = subtree_before(t, stop)
        for m in walk:
            if m is t or not m["tags"] or m["persona"] == t["persona"]:
                continue
            if m["persona"] not in latest or m["seq"] > latest[m["persona"]][0]:
                latest[m["persona"]] = (m["seq"], m["id"], m["tags"])
            personas[m["persona"]] = (m["harness"], m["model"])
        rows.append((t, latest))
    return rows, personas


def patch_label(m):
    """The patch subject in canonical lore style: '[PATCH vN i/M] subject'.
    N comes from the subject's own prefix; a series posted as bare
    '[PATCH i/M]' (no version) falls back to the message's own X-Version.
    i is zero-padded to the width of M, lore-style (02/14, 03/24), even
    when the source subject was not padded. An already-canonical subject
    round-trips byte-identical; a subject with no [PATCH] prefix is
    returned verbatim.

    A subject wrapped in a 'Re: ' carrier (a reply whose stored subject is
    'Re: [PATCH ...]', however many 'Re: ' layers deep) is normalized the
    same way and comes back under a single 'Re: '. Collapsing the Re: run
    is part of the PATCH normalization: a no-prefix subject stays verbatim,
    'Re: Re: ' and all."""
    subj = m["subject"]
    re_prefix = ""
    while subj.startswith("Re: "):
        re_prefix = "Re: "
        subj = subj[4:]
    mm = re.match(r"^\[PATCH (?:v(\d+) )?(\d+)/(\d+)\]\s*(.*)$", subj)
    if not mm:
        return m["subject"]
    version = mm.group(1) or str(m["version"])
    idx = mm.group(2).zfill(len(mm.group(3)))
    return re_prefix + f"[PATCH v{version} {idx}/{mm.group(3)}] {mm.group(4)}"


def is_patch(m):
    return m["depth"] == 1 and m["subject"].startswith("[PATCH") and m["body"].startswith("From ")


def who_of(m):
    return esc(m["from"].split(" (AI persona)")[0].split(" <")[0]) or esc(m["persona"])


def reviewer_rollup(version_msgs, author, tally_rows):
    """One entry per non-author persona, sorted by persona slug (the same
    order the matrix's columns are in): display name, harness, network,
    model, message count in this version, and how many patches
    their LATEST tag is a Reviewed-by / NAK. The verdict counts reuse the
    tally's latest-tag-per-persona-per-patch supersession instead of
    counting every tag ever posted -- a NAK withdrawn by a later
    Reviewed-by on the same patch is not an open NAK, and this page
    reports current state, not history."""
    open_verdicts = {}
    for _t, latest in tally_rows:
        for p, (_seq, _mid, tags) in latest.items():
            v = open_verdicts.setdefault(p, [0, 0])
            if "Reviewed-by" in tags:
                v[0] += 1
            if "NAK" in tags:
                v[1] += 1
    out = []
    for m in version_msgs:
        p = m["persona"]
        if not p or p == author:
            continue
        r = next((x for x in out if x["persona"] == p), None)
        if r is None:
            r = {"persona": p, "name": "", "harness": m["harness"], "network": m["network"],
                 "model": m["model"], "count": 0, "rev": 0, "nak": 0}
            out.append(r)
        if not r["name"]:
            r["name"] = m["from"].split(" (AI persona)")[0].split(" <")[0]
        r["count"] += 1
    for r in out:
        if not r["name"]:
            r["name"] = r["persona"]
        r["rev"], r["nak"] = open_verdicts.get(r["persona"], (0, 0))
    out.sort(key=lambda r: r["persona"])
    return out


def persona_brief_path(series_dir, persona):
    """The on-disk persona brief for a message's X-AI-Persona value, or
    None. The header comes straight out of the .msg file, which a
    hand-written message can set to anything, including traversal or an
    absolute path; keep the read inside <series>/personas/ the way the
    attachment reader does."""
    personas_dir = os.path.join(series_dir, "personas")
    brief_path = os.path.normpath(os.path.join(personas_dir, persona + ".md"))
    personas_real = os.path.realpath(personas_dir)
    brief_real = os.path.realpath(brief_path)
    if (os.path.commonpath((brief_real, personas_real)) == personas_real
            and os.path.isfile(brief_real)):
        return brief_real
    return None


def persona_role(series_dir, persona):
    """The persona brief's 'role:' frontmatter field, or None. The rail's
    reviewer rows show it under the name; a brief without the field (or
    with no brief at all) shows the persona slug instead."""
    path = persona_brief_path(series_dir, persona)
    if not path:
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    m = re.match(r"\A---\n(.*?)\n---", text, re.DOTALL)
    if not m:
        return None
    for ln in m.group(1).splitlines():
        if ln.startswith("role:"):
            role = ln[5:].strip()
            return role or None
    return None


def read_results_file(series_dir, filename):
    """A results markdown file in <series> split into ("# Summary" body,
    "# Details" body), or None when absent. The filename is fixed by
    the caller (never a message-derived value), and the path is
    realpath-contained in the series dir the way persona_brief_path and
    the attachment reader contain theirs, so a file planted as a
    symlink outside the mailbox cannot steer the read."""
    path = os.path.join(series_dir, filename)
    series_real = os.path.realpath(series_dir)
    path_real = os.path.realpath(path)
    if (os.path.commonpath((path_real, series_real)) == series_real
            and os.path.isfile(path_real)):
        with open(path_real, encoding="utf-8", errors="replace") as f:
            return split_results(f.read())
    return None


def read_results(series_dir, version):
    """The per-version results file <series>/results-v<N>.md (N built
    from the integer version), or None when absent. A companion
    results-v<N>.json may sit next to it; has_results_json reports on
    it separately."""
    return read_results_file(series_dir, f"results-v{version}.md")


def has_results_json(series_dir, version):
    """True when <series>/results-v<N>.json exists (realpath-contained
    the same way the .md reader is). The card renders the .md's text;
    the .json only keeps the card present when the .md was never
    written, so a run that produced a results file renders a card
    rather than a bare thread."""
    path = os.path.join(series_dir, f"results-v{version}.json")
    series_real = os.path.realpath(series_dir)
    path_real = os.path.realpath(path)
    return (os.path.commonpath((path_real, series_real)) == series_real
            and os.path.isfile(path_real))


def read_series_results(series_dir):
    """The whole-series results file <series>/results-series.md (written
    by the summarizer's --series mode), or None when absent."""
    return read_results_file(series_dir, "results-series.md")


def split_results(text):
    """Split a results file into ("# Summary" body, "# Details" body).
    The bodies are verbatim, stripped of nothing but trailing newlines.
    A missing '# Summary' means the summary is everything above the
    '# Details' header (the whole file when there is no header at
    all); a missing '# Details' means the details body is empty.
    Each body ends where the other section's header sits,
    in either order, so a # Details that precedes # Summary cannot
    swallow the summary header and body into the details."""
    lines = text.splitlines()
    s = next((i for i, ln in enumerate(lines) if ln == "# Summary"), None)
    d = next((i for i, ln in enumerate(lines) if ln == "# Details"), None)
    if s is None:
        s = -1
    if d is None:
        d = len(lines)
    end_s = d if d > s else len(lines)
    end_d = s if s > d else len(lines)
    return "\n".join(lines[s + 1:end_s]).rstrip("\n"), "\n".join(lines[d + 1:end_d]).rstrip("\n")


def id_prefix_map(msgs):
    """Seven-hex message-id prefix to full id, for the results card's
    autolinker. Ambiguous prefixes (two messages sharing their first
    seven hex characters) are dropped rather than guessed at."""
    by_prefix = {}
    for m in msgs.values():
        p = m["id"][:7]
        if len(p) == 7:
            by_prefix.setdefault(p, set()).add(m["id"])
    return {p: next(iter(full)) for p, full in by_prefix.items() if len(full) == 1}


HEX_TOKEN_RE = re.compile(r"(?<![0-9a-fA-F])[0-9a-f]{7}(?![0-9a-fA-F])")


def link_ids(escaped, id_map):
    """Turn bare 7-hex message-id tokens in already-escaped text into
    links to the #m-<id> anchors the renderer itself constructs. The
    match runs on the ESCAPED text and inserts only those anchors, so a
    results file cannot smuggle markup through the linker; a token that
    matches no id (or matches ambiguously) stays plain text."""
    def sub(match):
        full = id_map.get(match.group(0))
        return f'<a href="#m-{esc(full)}">{match.group(0)}</a>' if full else match.group(0)
    return HEX_TOKEN_RE.sub(sub, escaped)


def render_summary_card(series_dir, version, id_map, series_name):
    """The per-version auto-summary card, rendered when the version's
    results file exists (results-v<N>.md, or a bare results-v<N>.json
    when the .md is absent). The '# Summary' section sits visible in
    the card body, only the '# Details' section inside the fold, and
    7-hex message-id tokens autolink to the thread's #m-<id> anchors.
    Empty sections are omitted; with NO results file this returns ""
    -- no card at all, not an empty one. The id is namespaced per
    series (a multi-series page carries the same version twice)."""
    res = read_results(series_dir, version)
    if res is None and not has_results_json(series_dir, version):
        return ""
    summary, details = res if res is not None else ("", "")
    card = (f'  <section class="panel summary" id="{esc(series_name)}-summary-v{version}">\n'
            f'    <div class="summary-head"><h2>Where this stands</h2>'
            f'<span class="chip pending">auto-summary \u00b7 v{version}</span></div>\n')
    if summary:
        card += f'    <div class="summary-body">{link_ids(render_prose(summary), id_map)}</div>\n'
    if details:
        card += (f'    <details class="results-fold">\n'
                 f'      <summary>show details</summary>\n'
                 f'      <pre class="results-details">{link_ids(esc(details), id_map)}</pre>\n'
                 f'    </details>\n')
    return card + '  </section>'


def render_series_card(series_dir, id_map):
    """The page-level series summary card, placed directly above the
    series' own shell: the same treatment as the per-version card
    (Summary visible, Details inside the fold, autolinked, empty
    sections omitted), but the head reads 'Series summary' and the
    wrapper carries results-series, so the card can be styled
    independently later without markup surgery. The id_map must cover
    ALL versions' messages (the caller builds it over the whole series
    dir). Returns "" when the file is absent."""
    res = read_series_results(series_dir)
    if res is None:
        return ""
    summary, details = res
    card = (f'  <section class="panel summary results-series">\n'
            f'    <div class="summary-head"><h2>Series summary</h2>'
            f'<span class="chip pending">series</span></div>\n')
    if summary:
        card += f'    <div class="summary-body">{link_ids(render_prose(summary), id_map)}</div>\n'
    if details:
        card += (f'    <details class="results-fold">\n'
                 f'      <summary>show details</summary>\n'
                 f'      <pre class="results-details">{link_ids(esc(details), id_map)}</pre>\n'
                 f'    </details>\n')
    return card + '  </section>'


def render_banner(naks, nak_names, nak_patch_idx, n_open, open_patch_idx):
    """The blocking banner, when something blocks: a standing NAK
    (critical styling), or every open thread sitting on a single
    patch (warning styling). '' when neither applies."""
    if naks:
        where = "patch " + ", ".join(str(i) for i in nak_patch_idx) if nak_patch_idx else "the series"
        h = f"A NAK stands on {where}" if naks == 1 else f"{naks} NAKs stand on {where}"
        body = (f"{', '.join(nak_names)} {'stands' if naks == 1 else 'stand'} as "
                f"{'a NAK' if naks == 1 else 'NAKs'}. Nothing merges until "
                f"{'it is' if naks == 1 else 'they are'} resolved or withdrawn.")
        return (f'<div class="banner crit">\n  <span class="bar"></span>\n  <div>\n'
                f'    <h2>{esc(h)}</h2>\n    <p>{esc(body)}</p>\n  </div>\n</div>')
    if n_open >= 2 and open_patch_idx is not None:
        h = f"All {n_open} open threads sit on patch {open_patch_idx}"
        body = (f"Every open thread is on patch {open_patch_idx}; the rest of the "
                f"series is signed off. Convergence is a revise away rather than "
                f"an argument.")
        return (f'<div class="banner">\n  <span class="bar"></span>\n  <div>\n'
                f'    <h2>{esc(h)}</h2>\n    <p>{esc(body)}</p>\n  </div>\n</div>')
    return ""


def render_versions_panel(versions, current, version_counts, series_name):
    rows = []
    for v in versions:
        cur = ' aria-current="true"' if v == current else ""
        if len(versions) == 1:
            label = "first posting"
        elif v == versions[0]:
            label = "first posting"
        elif v == versions[-1]:
            label = "latest posting"
        else:
            label = "interim"
        rows.append(f'<a class="vrow" href="#{esc(series_name)}-v{v}"{cur}>'
                    f'<span class="vn">v{v}</span><span>{label}</span>'
                    f'<span class="vmeta">{version_counts[v]} msg</span></a>')
    return (f'    <section class="panel">\n'
            f'      <p class="eyebrow">versions</p>\n'
            f'      <nav class="versions">\n        ' + "\n        ".join(rows) + "\n      </nav>\n"
            f'    </section>')


def render_reviewer_panel(series_dir, version, reviewer_entries, strongest):
    if not reviewer_entries:
        return ""
    rows = []
    for r in reviewer_entries:
        role = persona_role(series_dir, r["persona"]) or r["persona"]
        small = f'<small>{esc(role)}</small>'
        tag = strongest.get(r["persona"])
        chip = chip_html(tag) if tag else '<span class="chip pending">pending</span>'
        rows.append(f'        <div class="mrow">\n'
                    f'          {badge(r["persona"])}\n'
                    f'          <span class="who">{esc(r["name"])}{small}</span>\n'
                    f'          {chip}\n'
                    f'        </div>')
    return (f'    <section class="panel">\n'
            f'      <p class="eyebrow">where each reviewer stands \u00b7 v{version}</p>\n'
            f'      <div class="matrix">\n' + "\n".join(rows) + "\n      </div>\n"
            f'    </section>')


def render_patch_panel(series_dir, version, rows, reviewer_entries):
    patches = rows[1:]
    if not patches:
        return ""
    roles = {r["persona"]: (persona_role(series_dir, r["persona"]) or r["persona"])
             for r in reviewer_entries}
    rows_html = []
    for i, (patch, latest) in enumerate(patches, start=1):
        # The row is numbered from the SUBJECT's index, not its
        # position: with a gapped mailbox (1/2 and 3/2) the second
        # row is patch 3, and a positional badge would disagree with
        # the banner. A subject without an index falls back to the
        # position, marked '?' so the fallback is visible.
        subj_idx = patch_index(patch)
        num = str(subj_idx) if subj_idx is not None else f"{i}?"
        pos = [p for p, (_s, _m, tags) in latest.items()
               if any(t in POSITIVE_TAGS for t in tags)]
        names = [roles.get(p, p) for p in pos]
        if len(names) == 1:
            sub = f"{names[0]} signed off"
        elif names:
            sub = " + ".join(names)
        else:
            sub = "no sign-offs"
        tag = strongest_tag([t for _p, _m, tags in latest.values() for t in tags])
        chip = chip_html(tag) if tag else '<span class="chip pending">pending</span>'
        subj = re.sub(r"^Re: ", "", patch_label(patch))
        mm = re.match(r"^\[PATCH v\d+ \d+/\d+\]\s*(.*)$", subj)
        title = mm.group(1).strip() if mm else subj.strip() or f"patch {i}"
        rows_html.append(f'        <div class="mrow">\n'
                         f'          <span class="mono-badge mono-none">{num}</span>\n'
                         f'          <span class="who">{esc(title[:60])}<small>{esc(sub)}</small></span>\n'
                         f'          {chip}\n'
                         f'        </div>')
    return (f'    <section class="panel">\n'
            f'      <p class="eyebrow">per patch \u00b7 v{version}</p>\n'
            f'      <div class="matrix">\n' + "\n".join(rows_html) + "\n      </div>\n"
            f'    </section>')


def render_counts_panel(n_open, n_signoffs, max_depth, n_naks):
    def state(n, warn_when, ok_when):
        if warn_when(n):
            return " is-warn"
        if ok_when(n):
            return " is-ok"
        return ""
    return (f'    <section class="panel">\n'
            f'      <p class="eyebrow">what is unresolved</p>\n'
            f'      <div class="counts">\n'
            f'        <div class="count{state(n_open, lambda n: n > 0, lambda n: False)}"><b>{n_open}</b><span>open threads</span></div>\n'
            f'        <div class="count{state(n_signoffs, lambda n: False, lambda n: n > 0)}"><b>{n_signoffs}</b><span>sign-offs</span></div>\n'
            f'        <div class="count"><b>{max_depth}</b><span>deepest depth</span></div>\n'
            f'        <div class="count{state(n_naks, lambda n: n > 0, lambda n: False)}"><b>{n_naks}</b><span>NAKs standing</span></div>\n'
            f'      </div>\n'
            f'    </section>')


def open_threads_of(version_msgs, patch_root_ids, root_ids):
    """The open threads: the topmost reply of each reply chain (a message
    whose parent is a patch root or a series root, so a nested chain
    under a patch is ONE thread, not one per message) whose subtree
    carries no sign-off tag anywhere."""
    out = []
    for m in version_msgs:
        if m["depth"] < 1 or m["id"] in patch_root_ids:
            continue
        if m["parent"] not in patch_root_ids and m["parent"] not in root_ids:
            continue
        if any(any(t in POSITIVE_TAGS for t in x["tags"]) for x in subtree(m)):
            continue
        out.append(m)
    return out


def patch_index(patch):
    """The 1-based position of a patch root from its subject, or None."""
    mm = re.match(r"^\[PATCH v\d+ (\d+)/", patch_label(patch))
    return int(mm.group(1)) if mm else None


def render_message(m, depth=0, series_name=""):
    """One message of the thread as a collapsed <details>: monogram,
    name, short id, verdict chip, subject as the scannable line; the
    body opens in place. data-depth drives the indent and the hairline
    rail (a depth-0 message gets neither -- the CSS styles
    [data-depth="1"] and above, capping the indent at depth 6). An
    unrecorded model is stamped
    'model unknown' in the warning colour: surfacing a real defect,
    deliberately, not hiding it."""
    chip = chip_html(strongest_tag(m["tags"]))
    model = m["model"]
    if model:
        model_chip = f'<span class="model">{esc(model)}</span>'
    elif m.get("fleet"):
        model_chip = ""
    else:
        model_chip = '<span class="model unknown">model unknown</span>'
    if m["body"].strip():
        body_html = render_patch_body(m["body"]) if is_patch(m) else render_prose(m["body"])
    else:
        body_html = (f'<p class="placeholder">No body. Open this thread in the mailbox: '
                     f'<code class="inline">lkml-mailbox.sh show {esc(series_name)} {esc(m["id"])}</code></p>')
    attachment_html = ""
    if m["attachments"]:
        items = []
        for attachment in m["attachments"]:
            label = esc(attachment["ref"])
            if attachment["href"]:
                link = (f'<a download href="{esc(attachment["href"])}">{label}</a>'
                        f' <span class="attachment-type">({esc(attachment["mime"])})</span>')
                if attachment["mime"].startswith("image/") and attachment["mime"] != "image/svg+xml":
                    link += f'<br><img class="attachment-preview" src="{esc(attachment["href"])}" alt="{label}">'
            else:
                link = f"{label} <span class=\"attachment-missing\">(unavailable)</span>"
            items.append(f"<li>{link}</li>")
        attachment_html = ('<div class="attachments"><span class="attachment-label">attachments</span><ul>'
                           + "".join(items) + "</ul></div>")
    return (
        f'<details class="msg" data-depth="{depth}" id="m-{esc(m["id"])}">\n'
        f'  <summary>\n'
        f'    {badge(m["persona"])}\n'
        f'    <span class="line">\n'
        f'      <span class="from">{who_of(m)} <span class="id">{esc(m["id"][:7])}</span>{chip}</span>\n'
        f'      <span class="gist">{esc(patch_label(m))}</span>\n'
        f'    </span>\n'
        f'    <span class="meta">{model_chip}</span>\n'
        f'  </summary>\n'
        f'  <div class="body">{body_html}{attachment_html}</div>\n'
        f'</details>'
    )


def render_trace(m, depth=0, series_name="", stop_ids=frozenset()):
    """The thread as a flat pre-order list of collapsed <details>, one
    per message, in reply order: the trace is the list, the depth is
    the indent (render_message's data-depth), and every message opens
    in place regardless of nesting. stop_ids is every OTHER version's
    cover id (empty for the old layout): a fleet thread's later
    versions are nested replies in the same tree, and each version's
    own section renders only up to the next one's cover, not into it."""
    out = [render_message(m, depth, series_name)]
    for c in m["children"]:
        if c["id"] in stop_ids:
            continue
        out.append(render_trace(c, depth + 1, series_name, stop_ids))
    return "\n".join(out)


def render_series(series_dir, assume_root_version=None):
    name, msgs, roots, all_version_roots = build(series_dir, assume_root_version)
    id_map = id_prefix_map(msgs)
    # all_version_roots is roots widened, for a fleet thread, to every
    # nested reply that itself opens a new version (build_fleet_layout
    # resets such a reply's depth to 0 for exactly this reason -- the
    # thread id is fixed to the root message, so v2 and later are
    # always replies there, never roots); for the old layout it is
    # exactly `roots`.
    covers = [m for m in all_version_roots
              if is_cover_subject(m["subject"]) or m.get("assumed_cover")]
    require_fleet_covers(series_dir, msgs, covers)
    fleet_cover_ids = {c["id"] for c in covers if c.get("fleet")}
    versions = sorted({c["version"] for c in covers})
    current = versions[-1] if versions else 1
    # The current version's state drives the rail, the banner and the
    # state chip: the page reports where the series stands NOW.
    version_data = {}
    for v in versions:
        cover = next(c for c in covers if c["version"] == v)
        version_roots = [r for r in all_version_roots if r["version"] == v]
        local_root_ids = {r["id"] for r in version_roots}
        version_msgs = [m for root in version_roots
                        for m in subtree_before(root, fleet_cover_ids)]
        rows, _personas = tally(cover, fleet_cover_ids)
        patch_root_ids = {t[0]["id"] for t in rows[1:]}
        reviewer_entries = reviewer_rollup(version_msgs, cover["persona"], rows)
        # The strongest latest tag per persona across the version's
        # rows (latest per patch already, so a withdrawn NAK is not
        # counted as standing).
        strongest = {}
        for _t, latest in rows:
            for p, (_seq, _mid, tags) in latest.items():
                s = strongest_tag(tags)
                if s and (p not in strongest or TAG_PRIORITY.index(s) < TAG_PRIORITY.index(strongest[p])):
                    strongest[p] = s
        d1map = {}

        def d1walk(m, cur_d1):
            if m["depth"] == 1:
                cur_d1 = m
            d1map[m["id"]] = cur_d1
            for c in m["children"]:
                d1walk(c, cur_d1)

        for r in version_roots:
            d1walk(r, None)
        opens = open_threads_of(version_msgs, patch_root_ids, local_root_ids)
        n_open = len(opens)
        # The banner names the patch every open thread sits on; that is
        # one patch only when EVERY open thread parents to a patch and
        # they all agree (an untagged orphan reply to the cover anchors
        # nowhere, so its presence keeps the banner quiet).
        patch_msgs = {t["id"]: t for t, _l in rows[1:]}
        open_pidx = set()
        all_on_patch = True
        for m in opens:
            p = patch_msgs.get(m["parent"])
            if p is None:
                all_on_patch = False
                break
            open_pidx.add(patch_index(p))
        open_pidx.discard(None)
        open_patch_idx = (next(iter(open_pidx))
                          if all_on_patch and len(open_pidx) == 1 else None)
        naks = sum(r["nak"] for r in reviewer_entries)
        nak_names = sorted(r["persona"] for r in reviewer_entries if r["nak"])
        nak_d1 = set()
        for _t, latest in rows:
            for _p, (_seq, _mid, tags) in latest.items():
                if "NAK" in tags:
                    d1 = d1map.get(_mid)
                    if d1 is not None:
                        nak_d1.add(d1["id"])
        # A NAK whose depth-1 ancestor is not a patch root (a reply to
        # the cover, or nested under one) anchors to no patch: the
        # banner already falls back to "the series", so the index skips
        # it rather than looking it up in the patch rows.
        nak_idx = sorted(i for i in (patch_index(patch_msgs[k]) for k in nak_d1 if k in patch_msgs) if i)
        version_data[v] = {
            "cover": cover, "rows": rows, "version_roots": version_roots,
            "version_msgs": version_msgs, "reviewer_entries": reviewer_entries,
            "strongest": strongest, "n_open": n_open,
            "open_patch_idx": open_patch_idx,
            "n_naks": naks, "nak_idx": nak_idx, "nak_names": nak_names,
        }
    rendered_ids = {m["id"] for d in version_data.values() for m in d["version_msgs"]}
    require_full_coverage(series_dir, msgs, rendered_ids)
    cur = version_data.get(current)
    n_replies_cur = (sum(1 for m in cur["version_msgs"] if m["depth"] >= 1 and not is_patch(m))
                     if cur else 0)
    n_msgs_cur = len(cur["version_msgs"]) if cur else 0

    # Masthead: the series' own cover subject (its leading bracket --
    # '[PATCH vN 0/M]', or a qualified form like '[RFC PATCH v3 0/2]'
    # -- is the numbering, not the title). covers is already filtered
    # to is_cover_subject, so any leading bracket here is a PATCH one.
    series_title = name
    if covers:
        cover_subj = covers[0]["subject"]
        mm = re.match(r"^\[[^\]]*\]\s*(.*)$", cover_subj)
        if mm and mm.group(1).strip():
            series_title = mm.group(1).strip()
    state = ""
    if cur:
        s = strongest_tag([t for _t, latest in cur["rows"]
                           for _p, _m, tags in latest.values() for t in tags])
        # The seated panel comes from the thread ROOT's X-Seats header,
        # stamped once at kickoff time by lkml-fleet-kickoff.sh --seats,
        # never from a version's own To:/Cc: -- those name wave one on
        # this transport (fleet.yaml's lists expand long after the
        # cover is posted), not the panel, and a list address like
        # @panel is never in-band as a From: either. A later reply's
        # own X-Seats is never read: the store accepts arbitrary X-*
        # headers on any message, so honoring one there would let a
        # single seat shrink the panel underneath the verdict. Trust is
        # anchored to the root message's author (kickoff-posted covers
        # are host- or CI-authored) -- not self-certifying, not
        # tamper-proof, just as trustworthy as whoever posted the root.
        # `roots` is sorted by (version, seq) for display, not arrival
        # -- picking [0] would let a second structural root (a
        # truncated/corrupted store's orphaned reply, see
        # require_full_coverage) with a lower version marker in its own
        # Subject outrank the real kickoff. The genuine root is
        # whichever structural root actually arrived first.
        seated = None
        root = min(roots, key=lambda r: r["seq"]) if roots else None
        if root is not None and root.get("fleet"):
            x_seats = root.get("x_seats")
            if x_seats:
                seated = set(fleet_addr_list(x_seats))
        silent = set()
        if cur["cover"].get("fleet") and seated is not None:
            replied = {m["persona"] for m in cur["version_msgs"] if m["persona"]}
            silent = seated - replied - {cur["cover"]["persona"]}
        if s == "NAK":
            state = '<span class="chip nak">nak</span>'
        elif s == "Changes-requested":
            state = '<span class="chip changes">changes requested</span>'
        elif s == "Question":
            state = '<span class="chip question">question</span>'
        elif s is not None and not silent and (not cur["cover"].get("fleet") or seated is not None):
            state = '<span class="chip reviewed">converged</span>'
        else:
            state = '<span class="chip pending">pending</span>'
    masthead = (f'<header class="masthead">\n'
                f'  <div class="masthead-in">\n'
                f'    <div class="grow">\n'
                f'      <p class="eyebrow">lkml-mode series \u00b7 {esc(name)} \u00b7 v{current} \u00b7 {n_replies_cur} replies</p>\n'
                f'      <h1>{esc(series_title)}</h1>\n'
                f'      <p class="sub">{len(versions)} version{"s" if len(versions) != 1 else ""} \u00b7 {n_msgs_cur} messages in v{current}</p>\n'
                f'    </div>\n'
                f'    <div class="facts">\n'
                f'      <div class="fact"><span class="eyebrow">version</span><b>v{current}</b></div>\n'
                f'      <div class="fact"><span class="eyebrow">replies</span><b>{n_replies_cur}</b></div>\n'
                f'      <div class="fact"><span class="eyebrow">state</span><b>{state}</b></div>\n'
                f'    </div>\n'
                f'  </div>\n'
                f'</header>')

    parts = [f'<div class="series" id="{esc(name)}">\n  {masthead}\n']
    card = render_series_card(series_dir, id_map)
    if card:
        parts.append(card + "\n")
    if cur:
        counts = render_counts_panel(cur["n_open"],
                                     sum(1 for m in cur["version_msgs"]
                                         if m["depth"] >= 1 and any(t in POSITIVE_TAGS for t in m["tags"])),
                                     max((m["depth"] for m in cur["version_msgs"]), default=0),
                                     cur["n_naks"])
        rail = [render_versions_panel(versions, current,
                                      {v: len(d["version_msgs"]) for v, d in version_data.items()},
                                      name),
                render_reviewer_panel(series_dir, current, cur["reviewer_entries"], cur["strongest"]),
                render_patch_panel(series_dir, current, cur["rows"], cur["reviewer_entries"]),
                counts]
        banner = render_banner(cur["n_naks"], cur["nak_names"], cur["nak_idx"],
                               cur["n_open"], cur["open_patch_idx"])
        sump = render_summary_card(series_dir, current, id_map, name)
        shell = '  <div class="shell">\n\n  <aside class="rail">\n' + "\n".join(p for p in rail if p) + "\n  </aside>\n\n  <main class=\"main\">\n"
        if banner:
            shell += banner + "\n"
        if sump:
            shell += sump + "\n"
        for v in versions:
            d = version_data[v]
            thread = "\n".join(render_trace(r, 0, name, fleet_cover_ids) for r in d["version_roots"])
            maxd = max((m["depth"] for m in d["version_msgs"]), default=0)
            shell += (f'    <section class="section" id="{esc(name)}-v{v}">\n'
                      f'      <div class="trace-head"><h2>Thread \u00b7 v{v}</h2>'
                      f'<span class="eyebrow">{len(d["version_msgs"])} messages \u00b7 depth {maxd} \u00b7 click any line to open</span></div>\n'
                      f'      <div class="trace">\n{thread}\n      </div>\n'
                      f'    </section>\n')
        shell += '  </main>\n  </div>\n'
        parts.append(shell)
    parts.append('</div>')
    footer = f"{name} \u00b7 v{current} \u00b7 {n_replies_cur} replies"
    # id_map is returned, not recomputed by the caller: it covers ALL
    # versions' messages in the series dir (build() read every .msg
    # file), which is exactly the map the series card needs, and a
    # second build() would re-parse the whole mailbox for it.
    return name, "\n".join(parts), id_map, footer


CSS = """
:root {
  --ground:      #f6f8f9;
  --surface:     #ffffff;
  --surface-2:   #eef1f3;
  --ink:         #0f1417;
  --ink-2:       #47555c;
  --ink-3:       #71828b;
  --rule:        #d9e0e4;
  --rule-soft:   #e8edef;

  --accent:      #2f6fec;
  --accent-soft: #e4ecfd;
  --ok:          #1f7a5f;
  --ok-soft:     #ddf1e9;
  --warn:        #b4560e;
  --warn-soft:   #fbeade;
  --crit:        #b32218;
  --crit-soft:   #fbe3e0;

  --add:         #1f6e3d;
  --del:         #a8261f;
  --hunk:        #5a6c9e;

  --mono: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
  --ui:   "Archivo", ui-sans-serif, system-ui, sans-serif;
  --read: "Source Serif 4", Georgia, "Times New Roman", serif;

  --r: 10px;
  --shadow: 0 1px 2px rgba(15,20,23,.05), 0 8px 24px -16px rgba(15,20,23,.18);
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground:      #0b1013;
    --surface:     #121a1e;
    --surface-2:   #182328;
    --ink:         #e7eef1;
    --ink-2:       #a2b2ba;
    --ink-3:       #778890;
    --rule:        #24333a;
    --rule-soft:   #1b262b;

    --accent:      #7ea8ff;
    --accent-soft: #16273f;
    --ok:          #63c9a4;
    --ok-soft:     #102a22;
    --warn:        #e79a5c;
    --warn-soft:   #2c1d11;
    --crit:        #f08b80;
    --crit-soft:   #2f1512;

    --add:         #7bd88f;
    --del:         #f08a84;
    --hunk:        #8fa0d6;

    --shadow: 0 1px 2px rgba(0,0,0,.4), 0 8px 24px -16px rgba(0,0,0,.7);
  }
}

:root[data-theme="dark"] {
    --ground:      #0b1013;
    --surface:     #121a1e;
    --surface-2:   #182328;
    --ink:         #e7eef1;
    --ink-2:       #a2b2ba;
    --ink-3:       #778890;
    --rule:        #24333a;
    --rule-soft:   #1b262b;

    --accent:      #7ea8ff;
    --accent-soft: #16273f;
    --ok:          #63c9a4;
    --ok-soft:     #102a22;
    --warn:        #e79a5c;
    --warn-soft:   #2c1d11;
    --crit:        #f08b80;
    --crit-soft:   #2f1512;

    --add:         #7bd88f;
    --del:         #f08a84;
    --hunk:        #8fa0d6;

    --shadow: 0 1px 2px rgba(0,0,0,.4), 0 8px 24px -16px rgba(0,0,0,.7);
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--ground);
  color: var(--ink);
  font-family: var(--ui);
  font-size: 15px;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}

a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }

:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 4px; }

.eyebrow {
  font-size: 10.5px; font-weight: 600; letter-spacing: .1em;
  text-transform: uppercase; color: var(--ink-3); margin: 0;
}

.masthead { border-bottom: 1px solid var(--rule); background: var(--surface); }
.masthead-in {
  max-width: 1240px; margin: 0 auto; padding: 20px 24px 18px;
  display: flex; flex-wrap: wrap; gap: 16px 28px; align-items: flex-end;
}
.masthead h1 {
  font-size: 21px; font-weight: 700; letter-spacing: -.015em;
  margin: 4px 0 0; text-wrap: balance;
}
.masthead .sub { font-family: var(--mono); font-size: 12px; color: var(--ink-2); margin: 6px 0 0; }
.masthead .grow { flex: 1 1 260px; }

.facts { display: flex; gap: 22px; flex-wrap: wrap; }
.fact { display: flex; flex-direction: column; gap: 3px; }
.fact b { font-family: var(--mono); font-size: 13px; font-weight: 500; font-variant-numeric: tabular-nums; }

.series { scroll-margin-top: 1rem; }

.shell {
  max-width: 1240px; margin: 0 auto; padding: 22px 24px 40px;
  display: grid; grid-template-columns: 286px minmax(0, 1fr); gap: 26px; align-items: start;
}
@media (max-width: 900px) {
  .shell { grid-template-columns: minmax(0, 1fr); }
  .rail { position: static !important; }
}

.rail { position: sticky; top: 22px; display: flex; flex-direction: column; gap: 14px; min-width: 0; }

.panel {
  background: var(--surface); border: 1px solid var(--rule);
  border-radius: var(--r); padding: 14px 15px; box-shadow: var(--shadow);
}
.panel > .eyebrow { margin-bottom: 11px; }

.versions { display: flex; flex-direction: column; gap: 2px; }
.vrow {
  display: grid; grid-template-columns: 30px minmax(0,1fr) auto;
  align-items: center; gap: 9px; padding: 7px 8px; border-radius: 7px;
  border: 1px solid transparent; font-size: 13px; color: var(--ink-2); text-decoration: none;
}
.vrow:hover { background: var(--surface-2); color: var(--ink); }
.vrow .vn { font-family: var(--mono); font-weight: 700; font-size: 12px; color: var(--ink-3); }
.vrow .vmeta { font-size: 11.5px; color: var(--ink-3); font-variant-numeric: tabular-nums; }
.vrow[aria-current="true"] {
  background: var(--accent-soft);
  border-color: color-mix(in srgb, var(--accent) 34%, transparent);
  color: var(--ink);
}
.vrow[aria-current="true"] .vn { color: var(--accent); }

.matrix { display: flex; flex-direction: column; gap: 1px; }
.mrow {
  display: grid; grid-template-columns: 22px minmax(0,1fr) auto;
  align-items: center; gap: 9px; padding: 6px 2px;
}
.mrow + .mrow { border-top: 1px solid var(--rule-soft); }
.who { font-size: 13px; font-weight: 500; min-width: 0; overflow: hidden; text-overflow: ellipsis; }
.who small {
  display: block; font-size: 10.5px; font-weight: 400;
  color: var(--ink-3); letter-spacing: .01em;
}

.mono-badge {
  width: 22px; height: 22px; border-radius: 6px; display: grid; place-items: center;
  font-family: var(--mono); font-size: 10.5px; font-weight: 700;
  color: #fff; background: var(--ink-2); flex: none;
}
/* Stable persona monogram palette: one slot per persona name, chosen by
   a hash of the name (lkml-render.py's mono_color), so any roster
   renders and the colour is stable across a page and between runs. */
.p-color-0 { background: #6d3fb8; }
.p-color-1 { background: #1f7a5f; }
.p-color-2 { background: #b4560e; }
.p-color-3 { background: #2b3a42; }
.p-color-4 { background: #b32218; }
.p-color-5 { background: #2f6fec; }
.p-color-6 { background: #7a5c10; }
.p-color-7 { background: #5c3d7a; }
.mono-none { background: var(--ink-2); }

.chip {
  font-family: var(--ui); font-size: 10.5px; font-weight: 600; letter-spacing: .04em;
  text-transform: uppercase; padding: 3px 7px; border-radius: 999px;
  border: 1px solid transparent; white-space: nowrap; flex: none;
}
/* Strength is encoded in form as well as hue: Reviewed-by is solid
   green, Acked-by the same hue hollow (it is genuinely the weaker
   claim), Changes-requested amber, Question hollow amber, NAK solid
   red. The blue accent is chrome only, never a verdict. */
.chip.reviewed { background: var(--ok); color: #fff; border-color: var(--ok); }
.chip.acked    { background: var(--ok-soft); color: var(--ok); border-color: color-mix(in srgb, var(--ok) 40%, transparent); }
.chip.changes  { background: var(--warn-soft); color: var(--warn); border-color: color-mix(in srgb, var(--warn) 40%, transparent); }
.chip.question { background: transparent; color: var(--warn); border-color: color-mix(in srgb, var(--warn) 40%, transparent); }
.chip.nak      { background: var(--crit); color: #fff; border-color: var(--crit); }
.chip.tested   { background: var(--surface-2); color: var(--ink-2); border-color: var(--rule); }
.chip.pending  { background: var(--surface-2); color: var(--ink-3); border-color: var(--rule); }

.counts { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.count { border: 1px solid var(--rule); border-radius: 8px; padding: 9px 10px; background: var(--surface); }
.count b {
  display: block; font-family: var(--mono); font-size: 19px; font-weight: 700;
  line-height: 1.1; font-variant-numeric: tabular-nums;
}
.count.is-warn { border-color: color-mix(in srgb, var(--warn) 40%, transparent); background: var(--warn-soft); }
.count.is-warn b { color: var(--warn); }
.count.is-ok { border-color: color-mix(in srgb, var(--ok) 40%, transparent); background: var(--ok-soft); }
.count.is-ok b { color: var(--ok); }
.count span { font-size: 11px; color: var(--ink-2); }

.main { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.section { display: flex; flex-direction: column; gap: 7px; min-width: 0; scroll-margin-top: 1rem; }

.banner {
  display: flex; gap: 12px; align-items: flex-start; border-radius: var(--r);
  padding: 13px 15px; border: 1px solid color-mix(in srgb, var(--warn) 42%, transparent);
  background: var(--warn-soft);
}
.banner .bar { width: 3px; align-self: stretch; border-radius: 2px; background: var(--warn); flex: none; }
.banner h2 { font-size: 13.5px; font-weight: 700; margin: 0 0 3px; color: var(--warn); letter-spacing: -.005em; }
.banner p { margin: 0; font-size: 13px; color: var(--ink-2); }
.banner.crit { border-color: color-mix(in srgb, var(--crit) 42%, transparent); background: var(--crit-soft); }
.banner.crit .bar { background: var(--crit); }
.banner.crit h2 { color: var(--crit); }

.summary { padding: 0; overflow: hidden; }
.summary-head {
  padding: 14px 17px 12px; border-bottom: 1px solid var(--rule-soft);
  display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap;
}
.summary-head h2 { font-size: 15px; font-weight: 700; margin: 0; letter-spacing: -.01em; }
.summary-body {
  padding: 15px 17px; font-family: var(--read); font-size: 16.5px;
  line-height: 1.6; color: var(--ink); max-width: 68ch;
}
.summary-body p { margin: 0 0 .8em; }
.summary-body p:last-child { margin-bottom: 0; }
.summary-body strong { font-weight: 600; }
.results-fold { border-top: 1px solid var(--rule-soft); }
.results-fold summary {
  cursor: pointer; padding: 9px 17px; list-style: none;
  font-family: var(--mono); font-size: 11px; letter-spacing: .06em;
  text-transform: uppercase; color: var(--ink-3);
}
.results-fold summary:hover { background: var(--surface-2); }
.results-fold summary::-webkit-details-marker { display: none; }
.results-details {
  margin: 0 17px 15px; padding: 12px 14px; background: var(--surface-2);
  border-radius: 8px; font-family: var(--mono); font-size: 11.5px; line-height: 1.5;
  white-space: pre-wrap; overflow-wrap: anywhere; color: var(--ink-2);
}

.trace { display: flex; flex-direction: column; gap: 7px; }
.trace-head { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; margin-bottom: 3px; }
.trace-head h2 { font-size: 15px; font-weight: 700; margin: 0; letter-spacing: -.01em; }

.msg {
  position: relative; background: var(--surface); border: 1px solid var(--rule);
  border-radius: 9px; box-shadow: var(--shadow);
}
/* The indent steps 19px per level below the posting and caps at 6:
   a depth-7-or-deeper reply keeps the depth-6 indent rather than
   flushing left. The cap rule matches every depth; the explicit ones
   below, at equal specificity and later in the sheet, win. */
.msg[data-depth] { margin-left: 114px; }
.msg[data-depth="0"] { margin-left: 0; }
.msg[data-depth="1"] { margin-left: 19px; }
.msg[data-depth="2"] { margin-left: 38px; }
.msg[data-depth="3"] { margin-left: 57px; }
.msg[data-depth="4"] { margin-left: 76px; }
.msg[data-depth="5"] { margin-left: 95px; }
.msg[data-depth="6"] { margin-left: 114px; }
.msg[data-depth]::before {
  content: ""; position: absolute; left: -10px; top: 15px; bottom: 15px;
  width: 1px; background: var(--rule);
}
.msg[data-depth="0"]::before { content: none; }

.msg > summary {
  cursor: pointer; list-style: none; display: grid;
  grid-template-columns: 22px minmax(0, 1fr) auto;
  align-items: center; gap: 10px; padding: 10px 13px; border-radius: 9px;
}
.msg > summary::-webkit-details-marker { display: none; }
.msg > summary:hover { background: var(--surface-2); }
.msg[open] > summary { border-bottom: 1px solid var(--rule-soft); border-radius: 9px 9px 0 0; }

.line { min-width: 0; }
.line .from { font-size: 13px; font-weight: 600; display: flex; align-items: center; gap: 7px; flex-wrap: wrap; }
.line .from .id { font-family: var(--mono); font-size: 10.5px; font-weight: 400; color: var(--ink-3); }
.line .gist { font-size: 12.5px; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.msg[open] .line .gist { white-space: normal; overflow: visible; }

.meta { display: flex; align-items: center; gap: 8px; }
.model {
  font-family: var(--mono); font-size: 10px; color: var(--ink-3);
  white-space: nowrap; border: 1px solid var(--rule); border-radius: 4px; padding: 2px 5px;
}
.model.unknown { color: var(--crit); border-color: color-mix(in srgb, var(--crit) 40%, transparent); }
@media (max-width: 700px) { .model { display: none; } }

.body { padding: 14px 15px 16px; font-family: var(--read); font-size: 16px; line-height: 1.62; max-width: 68ch; }
.body p { margin: 0 0 .75em; }
.body p:last-child { margin-bottom: 0; }
/* Markdown headings from a message body are content, not page chrome:
   they keep the message's own voice (prose family, normal case,
   inherited color). The uppercase-mono eyebrow treatment lives on
   .eyebrow, fold summaries, and panel heads only. */
.body h3 { margin: 1.2rem 0 .5rem; font-size: 1.05rem; font-weight: 600; }
.body h4,.body h5,.body h6 { margin: 1.2rem 0 .5rem; font-size: .95rem; font-weight: 600; }
.body ul,.body ol { margin: 0 0 .8rem; padding-left: 1.4rem; }
.body li { margin: .15rem 0; }
.body code,.body code.inline {
  font-family: var(--mono); font-size: .86em; background: var(--surface-2);
  border: 1px solid var(--rule-soft); border-radius: 4px; padding: .08em .32em;
}
.body blockquote {
  margin: 0 0 .8em; padding-left: 12px; border-left: 2px solid var(--rule);
  color: var(--ink-3); font-style: italic;
}
.body blockquote p { margin: 0 0 .5em; }
.body blockquote p:last-child { margin: 0; }
.body .placeholder { font-family: var(--ui); font-size: 12.5px; color: var(--ink-3); }
.body pre.code {
  margin: 0 0 .9rem; padding: 12px 14px; background: var(--surface-2);
  border-radius: 8px; font-family: var(--mono); font-size: 12px; line-height: 1.5;
  overflow-x: auto;
}
pre.stat {
  margin: 0; font-family: var(--mono); font-size: 11.5px; line-height: 1.62;
  overflow-x: auto; padding: 12px 15px; background: var(--surface-2);
  color: var(--ink-2); border-radius: 9px 9px 0 0;
}
.fold summary {
  cursor: pointer; list-style: none; padding: 8px 15px;
  font-family: var(--mono); font-size: 11px; letter-spacing: .06em;
  text-transform: uppercase; color: var(--ink-3); background: var(--surface-2);
  border-bottom: 1px solid var(--rule-soft);
}
.fold summary::-webkit-details-marker { display: none; }
.fold summary:hover { color: var(--ink); }
.diff {
  margin: 0; padding: 12px 15px; font-family: var(--mono); font-size: 11.5px; line-height: 1.62;
  overflow-x: auto; background: var(--surface-2); color: var(--ink-2);
}
.d-add{color:var(--add)} .d-del{color:var(--del)} .d-hunk{color:var(--hunk)}
.d-file{font-weight:700;color:var(--ink)} .d-meta{color:var(--ink-3)}

/* Trailers in a body read as verdict chips in the same semantic
   colour; the blue accent never colours a verdict. */
.trailer {
  font-family: var(--ui); font-size: 11.5px; font-weight: 600; letter-spacing: .04em;
  text-transform: uppercase; padding: 2px 8px; border-radius: 999px;
  display: inline-block; margin: 0 0 .5em .4rem; border: 1px solid transparent;
}
.t-rev{background:var(--ok);color:#fff;border-color:var(--ok)}
.t-ack{background:var(--ok-soft);color:var(--ok);border-color:color-mix(in srgb, var(--ok) 40%, transparent)}
.t-test{background:var(--surface-2);color:var(--ink-2);border-color:var(--rule)}
.t-chg{background:var(--warn-soft);color:var(--warn);border-color:color-mix(in srgb, var(--warn) 40%, transparent)}
.t-q{background:transparent;color:var(--warn);border-color:color-mix(in srgb, var(--warn) 40%, transparent)}
.t-nak{background:var(--crit);color:#fff;border-color:var(--crit)}

.attachments {
  margin-top: 1rem; padding: 9px 11px; background: var(--surface-2);
  border-radius: 8px; font-family: var(--mono); font-size: 11.5px;
}
.attachment-label {
  display: block; color: var(--ink-3); text-transform: uppercase;
  letter-spacing: .08em; font-size: 10.5px;
}
.attachments ul { margin: .4rem 0 0; padding-left: 1.1rem; }
.attachments a { color: var(--accent); }
.attachment-type, .attachment-missing { color: var(--ink-3); }
.attachment-preview { display: block; max-width: 100%; max-height: 24rem; margin-top: .5rem; }

footer.foot {
  max-width: 1240px; margin: 0 auto; padding: 24px 24px 40px;
  color: var(--ink-3); font-size: 11.5px; font-family: var(--mono);
}
"""

def text_body(m):
    """The message body for --text mode. Cover letters and replies go
    out in full; a [PATCH] message (is_patch: a depth-1 [PATCH]-
    subjected message with a format-patch body) keeps the commit
    message and the diffstat -- the format-patch body separates them
    from the diff at the first 'diff --git' line, and the diff lives
    in git on the series branch, so it is summarized, not inlined. A
    reply that happens to carry a [PATCH] subject (the reply Subject:
    is optional and used verbatim) goes out in full. The cover letter
    is itself a [PATCH x 0/N] subject but, like every reply, goes out
    in full."""
    if not is_patch(m):
        return m["body"].rstrip("\n")
    lines = m["body"].splitlines()
    cut = next((i for i, ln in enumerate(lines) if ln == "---"), None)
    if cut is None:
        return m["body"].rstrip("\n")
    msg = lines[:cut]
    # drop format-patch's own From/From:/Date:/Subject: header block
    if msg and msg[0].startswith("From "):
        blank = next((i for i, ln in enumerate(msg) if not ln.strip()), 0)
        msg = msg[blank + 1:]
    # format-patch puts the diffstat between '---' and the first
    # 'diff --git'; keep it (the HTML render does) and summarize only
    # the diff itself. Trim only newlines: a diffstat's first line
    # carries the leading space its | column is aligned on, and
    # .strip() would dedent just that line.
    rest = lines[cut + 1:]
    d = next((i for i, ln in enumerate(rest) if ln.startswith("diff --git")), None)
    stat = "\n".join(rest[:d] if d is not None else rest).strip("\n")
    diff = rest[d:] if d is not None else []
    out = "\n".join(msg).strip("\n")
    if stat:
        out += "\n" + stat
    if diff:
        out += f"\n[diff omitted: {len(diff)} lines -- see the series branch]"
    return out


def render_text_message_body(out, m, header_line):
    """The part of a --text message block after its header line:
    separator, the given header line verbatim, the From/Subject/Tags/
    Attachments lines, then the body. Shared by a numbered thread
    message (render_text_message) and a late-reply entry
    (render_text_late_message) -- only the header line differs between
    the two, so it is a parameter rather than built here.

    The body is indented under its header: a message block here is
    the 72-dash separator, the header line, the From/Subject/Tags
    lines, then the body, and a body that carried a line of 72
    dashes and its own header-shaped line would otherwise read as a
    second message. Every body line is prefixed, so the header
    grammar stays unforgeable from the body; the prefix is uniform,
    so the diffstat's fixed-width alignment survives it."""
    out.append("-" * 72)
    out.append(header_line)
    line = f"From: {m['from']}"
    meta = []
    if m["persona"]:
        meta.append(f"persona: {m['persona']}")
    if m["harness"]:
        # The seat's network fact rides on the harness value in the same
        # 'pi, sealed' spelling the launch line and the seats announce
        # use: a sealed pi seat and a networked one both stamp harness
        # 'pi', so harness alone no longer shows the zero-cost local
        # seat. A message with no X-AI-Network header at all (a
        # pre-axis archive) renders exactly as before -- absence is not
        # a value.
        if m["network"] == "sealed":
            meta.append(f"harness: {m['harness']}, sealed")
        else:
            meta.append(f"harness: {m['harness']}")
    if m["model"]:
        meta.append(f"model: {m['model']}")
    if meta:
        line += "  [" + " · ".join(meta) + "]"
    out.append(line)
    out.append(f"Subject: {patch_label(m)}")
    if m["tags"]:
        out.append("Tags: " + ", ".join(m["tags"]))
    if m["attachments"]:
        out.append("Attachments: " + ", ".join(a["ref"] for a in m["attachments"]))
    body = text_body(m)
    if body:
        out.extend("  " + ln for ln in body.split("\n"))
    else:
        out.append("")


def render_text_message(out, m, nums, depth, stop_ids=frozenset()):
    """One message of the --text thread: a numbered header ending in
    the message's own short id (the same 7-hex Message-ID prefix the
    HTML render's line shows -- it goes last so every existing
    substring match on the earlier fields still holds), then its body
    via render_text_message_body. `nums` maps id to (number, parent
    number) from a pre-order walk, so this prints the thread in the
    same order the HTML render nests it in. stop_ids is every OTHER
    version's cover id (empty for the old layout): a fleet thread's
    later versions are nested replies in the same tree, and each
    version's own section prints only up to the next one's cover, not
    into it."""
    num, parent_num = nums[m["id"]]
    rel = f" · reply to #{parent_num}" if parent_num else ""
    render_text_message_body(out, m, f"== #{num}{rel} · depth {depth} · id {m['id'][:7]}")
    for c in m["children"]:
        if c["id"] in stop_ids:
            continue
        render_text_message(out, c, nums, depth + 1, stop_ids)


def render_text_late_message(out, m, home_version):
    """One late-reply entry under a --version block: same body grammar
    as render_text_message via render_text_message_body, but the header
    names the earlier version whose thread this message structurally
    belongs to (home_version) and its parent's short id instead of a
    thread-local number. No recursion into m['children'] -- each late
    child is itself a late message, filed and printed independently by
    the late-reply filter, never nested here."""
    render_text_message_body(
        out, m,
        f"== late · in v{home_version} thread · reply to {m['parent'][:7]} · depth {m['depth']} · id {m['id'][:7]}")


def fit_tally_label(label, budget):
    """Truncate a text-tally row label to at most `budget` columns, always
    marking the cut with a trailing ellipsis. When the [PATCH vN i/M]
    prefix fits the budget it survives intact and the cut lands on the
    SUBJECT part; a smaller budget cuts the prefix itself, and a zero
    budget drops the label entirely (the tag columns, not the label,
    are the overflow then). Either way the returned label never takes
    more than `budget` columns. Never falls back to the bare 'Patch vN
    i/M' form."""
    if len(label) <= budget:
        return label
    if budget <= 0:
        return ""
    mm = re.match(r"^(\[PATCH v\d+ \d+/\d+\] )(.*)$", label)
    if mm and budget > len(mm.group(1)) + 1:
        keep = budget - len(mm.group(1)) - 1
        return mm.group(1) + mm.group(2)[:keep] + "\u2026"
    return label[:budget - 1] + "\u2026"


def render_text_tally(out, rows, pcols):
    """The per-version tally as a fixed-width table: a row per patch
    (same labels as the HTML rows), a column per listed reviewer, cells
    the same latest-tag-per-reviewer-per-patch letters. The first column
    sizes from the longest label; when that would push the table past
    ~120 columns, the subject part of the label is truncated (the
    prefix intact) rather than the table."""
    grid = [["patch"] + list(pcols)]
    for t, latest in rows:
        label = "cover" if t is rows[0][0] else patch_label(t)
        grid.append([label] + [TAG_GLYPH.get(latest[p][2][0], "·") if p in latest else "·" for p in pcols])
    widths = [max(len(row[i]) for row in grid) for i in range(len(grid[0]))]
    # Gap is two spaces between columns; the label column alone absorbs
    # the overflow, so the tag columns stay readable. Floor at zero: when
    # the tag columns alone eat the whole 120, no label can fit and the
    # overflow lives in the configured panel width, not in a mangled
    # label (a negative slice would chop the label's END and push the
    # rows far past 120).
    budget = max(0, 120 - sum(widths[1:]) - 2 * (len(widths) - 1))
    if widths[0] > budget:
        for row in grid:
            row[0] = fit_tally_label(row[0], budget)
        widths[0] = max(len(row[0]) for row in grid)
    out.append("Latest tag per reviewer per patch. R reviewed, A acked, "
               "C changes requested, ? question, N nak.")
    for row in grid:
        out.append("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip())


def render_text_reviewers(out, name, series_dir, reviewer_entries):
    """One block per reviewer, in the box's order. No brief inlining in
    text mode -- just a pointer to the file, when it exists."""
    out.append("reviewers")
    for r in reviewer_entries:
        out.append(f"  {r['name']} ({r['persona']})")
        # The sealed fact in the same 'pi, sealed' spelling as the
        # per-message meta line: a message with no X-AI-Network header
        # (a pre-axis archive) renders exactly as before.
        harness = f"{r['harness']}, sealed" if r["network"] == "sealed" else r["harness"]
        meta = " · ".join(x for x in (harness, r["model"]) if x)
        if meta:
            out.append(f"    {meta}")
        counts = [f"{r['count']} message" + ("s" if r["count"] != 1 else "")]
        if r["rev"]:
            counts.append(f"{r['rev']} Reviewed-by")
        if r["nak"]:
            counts.append(f"{r['nak']} NAK")
        out.append(f"    {', '.join(counts)}")
        if persona_brief_path(series_dir, r["persona"]):
            out.append(f"    brief: {name}/personas/{r['persona']}.md")


def compute_version_sections(series_dir, assume_root_version=None):
    """Everything a --text render needs per version, computed once: the
    mailbox, the cover/version bookkeeping render_text_series and
    render_text_one_version both need, and per-version tally/reviewer
    data. Shared so --version reuses the exact same per-version
    computation the whole-series render does, rather than slicing that
    render's text."""
    name, msgs, _roots, all_version_roots = build(series_dir, assume_root_version)
    covers = [m for m in all_version_roots
              if is_cover_subject(m["subject"]) or m.get("assumed_cover")]
    require_fleet_covers(series_dir, msgs, covers)
    fleet_cover_ids = {c["id"] for c in covers if c.get("fleet")}
    # One section per DISTINCT version, the same dedup render_series
    # does for the HTML backend: the old layout guarantees one cover per
    # version (lkml-mailbox.sh's init refuses a second), but the fleet
    # store enforces nothing of the kind -- `mail reply --subject` takes
    # any string, so a resend or a reviewer echoing the cover subject
    # verbatim can produce a second cover at a version already open.
    # Iterating `covers` directly would render that version's whole
    # section twice, once per cover, with tallies that disagree because
    # each cover's own children differ -- worse than picking one.
    versions = sorted({c["version"] for c in covers})
    version_data = {}
    rendered_ids = set()
    for v in versions:
        cover = next(c for c in covers if c["version"] == v)
        version_roots = [r for r in all_version_roots if r["version"] == v]
        version_msgs = [m for root in version_roots
                        for m in subtree_before(root, fleet_cover_ids)]
        rendered_ids.update(m["id"] for m in version_msgs)
        rows, personas = tally(cover, fleet_cover_ids)
        reviewer_entries = reviewer_rollup(version_msgs, cover["persona"], rows)
        # One matrix column per reviewer the box lists, same set and
        # (alphabetical) order as the HTML table.
        pcols = sorted(set(personas) | {r["persona"] for r in reviewer_entries})
        version_data[v] = {
            "cover": cover, "version_roots": version_roots,
            "version_msgs": version_msgs, "rows": rows,
            "personas": personas, "reviewer_entries": reviewer_entries,
            "pcols": pcols,
        }
    return name, msgs, versions, version_data, fleet_cover_ids, rendered_ids


def render_text_version_lines(series_dir, name, v, d, fleet_cover_ids):
    """One version's own section, exactly as the whole-series --text
    render prints it: counts header, tally, reviewers, results block if
    any, then the numbered thread. `d` is version_data[v] from
    compute_version_sections. Shared by render_text_series (the
    whole-thread render) and render_text_one_version (--version N), so
    a version's section is byte-identical either way."""
    rows = d["rows"]
    version_msgs = d["version_msgs"]
    # The same counts the HTML header shows, computed the same way:
    # patches from the tally's targets, replies as everything at
    # depth >= 1 that is not a patch.
    n_replies = sum(1 for m in version_msgs if m["depth"] >= 1 and not is_patch(m))
    n_patches = len(rows) - 1
    reviewer_entries = d["reviewer_entries"]
    lines = [f"{name} v{v}",
             f"{n_patches} patches · {n_replies} replies · {len(reviewer_entries)} reviewers",
             ""]
    render_text_tally(lines, rows, d["pcols"])
    lines.append("")
    if reviewer_entries:
        render_text_reviewers(lines, name, series_dir, reviewer_entries)
        lines.append("")
    # The Results card's sections as a text block in the same
    # position: bare 'results' header, then the section labels
    # ('# Summary', '# Details') and the verbatim bodies. The
    # labels sit at column 0 -- like the 'results' header and the
    # message headers -- while every body line carries its
    # two-space prefix, so a body line that reads '# Summary' or
    # '# Details' cannot forge a label (the same rule that keeps a
    # body line from forging a message header). An empty section
    # omits its label and body, the way the HTML card omits its
    # empty details fold. No links in text mode.
    res = read_results(series_dir, v)
    if res is not None:
        lines.append("results")
        if res[0]:
            lines.append("# Summary")
            lines.extend("  " + ln for ln in res[0].split("\n"))
        if res[1]:
            if res[0]:
                lines.append("")
            lines.append("# Details")
            lines.extend("  " + ln for ln in res[1].split("\n"))
        lines.append("")
    # Number the thread pre-order, matching the HTML nesting order.
    nums = {}
    counter = [0]

    def assign(m, parent_id):
        counter[0] += 1
        nums[m["id"]] = (counter[0], parent_id and nums[parent_id][0])
        for c in m["children"]:
            if c["id"] in fleet_cover_ids:
                continue
            assign(c, m["id"])

    for root in d["version_roots"]:
        assign(root, None)
    for root in d["version_roots"]:
        render_text_message(lines, root, nums, 0, fleet_cover_ids)
    return lines


def render_text_series(series_dir, assume_root_version=None):
    """One series dir as plain text: a header with the same counts the
    HTML header shows, then every message in thread order."""
    name, msgs, versions, version_data, fleet_cover_ids, rendered_ids = \
        compute_version_sections(series_dir, assume_root_version)
    sections = []
    # The whole-series results file, if any: a 'series-summary' block
    # at the very top, before the first version section, with the same
    # column-0 labels / two-space body rules as the per-version
    # 'results' block (a body line cannot forge a label, no links in
    # text mode, empty sections omit their label and body).
    series_res = read_series_results(series_dir)
    if series_res is not None:
        lines = ["series-summary"]
        if series_res[0]:
            lines.append("# Summary")
            lines.extend("  " + ln for ln in series_res[0].split("\n"))
        if series_res[1]:
            if series_res[0]:
                lines.append("")
            lines.append("# Details")
            lines.extend("  " + ln for ln in series_res[1].split("\n"))
        sections.append("\n".join(lines))
    for v in versions:
        sections.append("\n".join(render_text_version_lines(series_dir, name, v, version_data[v], fleet_cover_ids)))
    require_full_coverage(series_dir, msgs, rendered_ids)
    return "\n\n".join(sections) + ("\n" if sections else "")


def render_text_late_replies(msgs, versions, version_data, home_version, v):
    """Messages that render in an EARLIER version's section (their
    structural home) but were posted while v was the current version:
    seq > cover(v).seq and, when a later version exists, seq <
    cover(v+1).seq. X-Seq is a nanosecond epoch stamped at post time
    (old layout) or the file's arrival-order prefix (fleet layout, via
    read_fleet_msg/build_fleet_layout) -- either way strictly
    increasing within one mailbox, so seq order is post order."""
    idx = versions.index(v)
    lo = version_data[v]["cover"]["seq"]
    hi = version_data[versions[idx + 1]]["cover"]["seq"] if idx + 1 < len(versions) else None
    late = [m for m in msgs.values()
            if home_version.get(m["id"]) is not None
            and home_version[m["id"]] < v
            and m["seq"] > lo
            and (hi is None or m["seq"] < hi)]
    late.sort(key=lambda m: m["seq"])
    return late


def render_text_one_version(series_dir, version, assume_root_version=None):
    """--text --version N: that version's own section (byte-identical
    to the corresponding slice of the full --text render), followed,
    only when any exist, by a block of messages filed on an earlier
    version's thread while N was current (render_text_late_replies) --
    a reviewer answering a still-open point on an older thread files
    its reply there, and dropping it would report a clean version that
    is not clean."""
    name, msgs, versions, version_data, fleet_cover_ids, rendered_ids = \
        compute_version_sections(series_dir, assume_root_version)
    if version not in version_data:
        raise ValueError(
            f"{series_dir}: no v{version} in this series (versions present: "
            + ", ".join(str(v) for v in versions) + ")"
        )
    home_version = {}
    for v in versions:
        for m in version_data[v]["version_msgs"]:
            home_version[m["id"]] = v
    lines = render_text_version_lines(series_dir, name, version, version_data[version], fleet_cover_ids)
    late = render_text_late_replies(msgs, versions, version_data, home_version, version)
    if late:
        lines.append("")
        lines.append(f"late replies (posted during v{version}, filed on earlier versions' threads)")
        for m in late:
            render_text_late_message(lines, m, home_version[m["id"]])
    require_full_coverage(series_dir, msgs, rendered_ids)
    return "\n".join(lines) + "\n"


def message_json(m, series_dir):
    """One message of the lkml-thread/1 block. `from` and `role` use the
    persona, not the display name that who_of escapes for HTML: the
    consumer gets the raw persona slug (or the From: name part when no
    persona is stamped) and the role_of-lookup keyed on that persona.
    Body and subject are verbatim -- raw, not escaped, not rendered."""
    date = m["date"]
    if date is not None:
        if date.tzinfo is None:
            date = date.replace(tzinfo=timezone.utc)
        date_s = date.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        date_s = None
    name_part = m["from"].split(" (AI persona)")[0].split(" <")[0]
    from_field = m["persona"] if m["persona"] else name_part
    return {
        "id": m["id"],
        "short_id": m["id"][:7],
        "parent_id": m["parent"] or None,
        "version": m["version"],
        "from": from_field,
        "role": persona_role(series_dir, m["persona"]),
        "model": m["model"] or None,
        "date": date_s,
        "subject": m["subject"],
        "tags": m["tags"],
        "is_patch": is_patch(m),
        "patch_index": patch_index(m) if is_patch(m) else None,
        "body": m["body"],
    }


def series_json(series_dir, assume_root_version=None):
    """The lkml-thread/1 entry for one series dir: every parsed message
    (all versions, late replies included, ordered by (seq, date, id) as
    parsed), the version/cover list, and the exact --text render for
    this dir. render_text_series is the coverage authority
    (require_full_coverage / require_fleet_covers); a series --text
    cannot render raises here too, rather than embedding a block for a
    page whose own HTML render already failed the same check."""
    name, msgs, versions, version_data, _fleet_cover_ids, _rendered_ids = \
        compute_version_sections(series_dir, assume_root_version)
    text = render_text_series(series_dir, assume_root_version)
    messages = sorted(msgs.values(), key=lambda m: (m["seq"], m["date"] or datetime.min, m["id"]))
    return {
        "name": name,
        "versions": [{"n": v, "cover_id": version_data[v]["cover"]["id"]} for v in versions],
        "messages": [message_json(m, series_dir) for m in messages],
        "text": text,
    }


def render_thread_json_block(series_list, rendered_at):
    """The <script type="application/json" id="lkml-thread"> block: the
    lkml-thread/1 schema, so an agent can read the thread without
    parsing the HTML and without lkml-review installed. Serialized with
    ensure_ascii=False (bodies are agent-written and may hold non-ASCII
    prose) and then &, < and > are escaped to \\u0026/\\u003c/\\u003e in
    the SERIALIZED string -- valid JSON string escapes that json.loads
    decodes straight back to the original byte, and the only thing
    standing between a body containing '</script>' and injected markup.
    U+2028/U+2029 ride the same \\uXXXX mechanism, out of caution for
    any consumer that treats this as JS source rather than JSON."""
    obj = {"schema": "lkml-thread/1", "rendered_at": rendered_at, "series": series_list}
    raw = json.dumps(obj, ensure_ascii=False)
    # \u003c/\u003e/\u0026 are valid JSON string escapes (unlike the HTML
    # entities &lt;/&gt;/&amp;, which are literal text inside a <script>
    # element -- the browser never decodes them there, so an HTML-entity
    # substitution would corrupt every body that uses one of these three
    # bytes and break the round trip through json.loads). Escaping here
    # is what keeps a body containing '</script>' from ever placing a
    # literal '<' in the page; \u2028/\u2029 ride the same mechanism.
    raw = (raw.replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
              .replace("\u2028", "\\u2028").replace("\u2029", "\\u2029"))
    return f'<script type="application/json" id="lkml-thread">{raw}</script>'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("series_dirs", nargs="+", metavar="SERIES_DIR",
                        help="lkml-mode series mailbox directory")
    parser.add_argument("--title", default="Review Threads",
                        help="document title and masthead (default: %(default)s)")
    parser.add_argument("-o", "--output", metavar="FILE",
                        help="write HTML to FILE instead of stdout")
    parser.add_argument("--assume-root-version", type=int, metavar="N",
                        help="fleet threads only: when the thread's root message "
                             "carries no [PATCH vN ...] version marker, read it as "
                             "the cover that opened version N (a thread kicked off "
                             "before the marker was stamped); a root that does "
                             "carry a marker keeps it")
    parser.add_argument("--text", action="store_true",
                        help="render the threads as plain text to stdout "
                             "(for agents; bodies indented under their headers, and "
                             "[PATCH] bodies keep the commit message and diffstat, "
                             "the diff cut at the first diff --git line)")
    parser.add_argument("--version", type=int, metavar="N",
                        help="with --text and exactly one SERIES_DIR: print only "
                             "that version's own section, plus, when any exist, "
                             "the late-replies block for messages filed on an "
                             "earlier version's thread during vN's window")
    args = parser.parse_args(argv)
    if args.version is not None and not args.text:
        parser.error("--version is only valid with --text")
    if args.text:
        # One flag, one backend: plain text to stdout, UTF-8, no ANSI.
        # -o is the HTML interface and is refused, not silently ignored;
        # --title is likewise ignored here.
        if args.output:
            parser.error("--text renders to stdout and cannot be combined with -o/--output")
        if args.version is not None and len(args.series_dirs) != 1:
            parser.error("--version takes exactly one SERIES_DIR")
        sys.stdout.reconfigure(encoding="utf-8")
        if args.version is not None:
            sys.stdout.write(render_text_one_version(args.series_dirs[0], args.version, args.assume_root_version))
            return
        parts = [render_text_series(d, args.assume_root_version).rstrip("\n")
                 for d in args.series_dirs]
        # A blank line between series, like the one between version
        # sections within a series, so two series do not run together.
        sys.stdout.write("\n\n".join(parts) + ("\n" if parts else ""))
        return
    series = []
    footers = []
    json_series = []
    for d in args.series_dirs:
        name, sec, _id_map, footer = render_series(d, args.assume_root_version)
        series.append((name, sec))
        footers.append(footer)
        json_series.append(series_json(d, args.assume_root_version))
    # SOURCE_DATE_EPOCH pins the stamp (UTC) so renders are reproducible.
    sde = os.environ.get("SOURCE_DATE_EPOCH")
    if sde:
        now = datetime.fromtimestamp(int(sde), timezone.utc).strftime("%Y-%m-%d %H:%M")
        rendered_at = datetime.fromtimestamp(int(sde), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        now = datetime.now().strftime("%Y-%m-%d %H:%M")
        rendered_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    json_block = render_thread_json_block(json_series, rendered_at)
    if len(series) == 1:
        # The single series' own masthead IS the page masthead; a second
        # generic header would only duplicate it.
        head = ""
    else:
        toc = " \u00b7 ".join(f'<a href="#{esc(n)}">{esc(n)}</a>' for n, _s in series)
        head = ('<div class="masthead">\n  <div class="masthead-in">\n'
                f'    <div class="grow"><h1>{esc(args.title)}</h1>'
                f'<p class="sub">{toc}</p></div>\n'
                f'    <div class="facts"><div class="fact">'
                f'<span class="eyebrow">rendered</span><b>{now}</b></div></div>\n'
                '  </div>\n</div>\n')
    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(args.title)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700&family=Source+Serif+4:ital,opsz,wght@0,8..60,400;0,8..60,600;1,8..60,400&family=JetBrains+Mono:wght@400;500;700&display=swap">
<style>{CSS}</style>
</head>
<body>
{head}{''.join(s for _n, s in series)}
<footer class="foot">{esc("  \u00b7  ".join(footers))} \u00b7 rendered {now}</footer>
{json_block}
</body>
</html>
"""
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(document)
    else:
        sys.stdout.write(document)


if __name__ == "__main__":
    main()
