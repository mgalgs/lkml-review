#!/usr/bin/env bash
# lkml-author-finalize.sh — Fold a wake's fixup! commits and make the
# cover true of the folded branch.
#
# Usage: lkml-author-finalize.sh --base <sha> --reply <file>
#            [--floor <sha>] [--repo <dir>] [--branch <ref>]
#        lkml-author-finalize.sh -h|--help
#
# An author wake can run as a pipeline of legs (code, then review by a
# fresh session) whose commits are `fixup!` commits, so each leg's review
# reads exactly the new work. This script runs ONCE, after the last leg,
# with no agent session alive: it folds the fixups into the commits they
# aim at, checks that nothing but history changed, and makes the cover the
# wake wrote true of the folded branch.
#
# Inputs, each a flag with an environment fallback, so a runner can call
# it bare:
#   --base <sha>    $FS_FINALIZE_BASE. The sha the wake started from: the
#                   previous version's review target.
#   --floor <sha>   $FS_FINALIZE_FLOOR, else --base. The lowest commit
#                   history may be rewritten down to. Folding never goes
#                   below it. With the frozen head as the floor, a fix to
#                   a commit an earlier version made folds into that
#                   commit.
#   --reply <file>  $FS_FINALIZE_REPLY. The cover the wake wrote. Writable.
#   --repo <dir>    The repository. Default: the current directory.
#   --branch <ref>  A local branch, `x` or `refs/heads/x`. Default: the
#                   branch checked out in --repo. It need not be checked
#                   out: the fold is built in a scratch detached worktree
#                   and the ref is moved at the end by compare-and-swap.
#                   The checked-out working tree and index are never
#                   touched; the tree is identical before and after, so a
#                   checked-out branch stays clean.
#
# The cover carries two lines this script reads, each alone on its line in
# the body: `Frozen-Head: <sha>` (the frozen head the version stands on)
# and `Described-Tip: <sha>` (the branch as the last leg that committed
# left it).
#
# Steps, in order; the first that fails refuses:
#   1. The inputs: the floor is --base or an ancestor of it; --base is an
#      ancestor of the branch; no merge commit lies above the floor. No
#      reply can cure these, so they come before anything read from it.
#   2. The cover: both lines are there, each a full sha naming a commit;
#      Described-Tip equals the branch's sha (otherwise a leg moved the
#      branch after the cover was written: the stale-cover refusal); and
#      Frozen-Head is the floor or an ancestor of it (above the floor the
#      cover is false; strictly below it folding stops at the floor, which
#      is said on stderr). A rewritten reply cures each of these: exit 2.
#   3. Fold: `git rebase -i --autosquash <floor>` with the todo list
#      accepted as generated, in the scratch worktree.
#   4. The tree must be identical before and after.
#   5. lkml-series-check.sh, with the cover's Frozen-Head as the boundary,
#      must pass on the result (a fixup! left behind, among others).
#   6. The cover is made true: `Subject:`'s 0/<K> (the commits above the
#      Frozen-Head), the range-diff in the first `## Since v<N>` section
#      (<Frozen-Head>..<base> against <Frozen-Head>..<new tip>; with
#      --base the Frozen-Head the previous series is empty and every
#      commit shows as added), every abbreviated or full sha in the body
#      that names a rewritten commit,
#      and Described-Tip. A cover with no 0/<K> or no `## Since` section
#      has nothing there for the fold to have made false: said on stderr,
#      not refused. A run that folded nothing writes nothing.
#
# Exit status: 0 done (or nothing to do); 2 when changing only the reply
# can fix a missing, invalid or false cover line (Frozen-Head or
# Described-Tip), so a runner may answer with a reply-only retry; 1 every
# other refusal, usage errors included (unlike lkml-series-check.sh, where
# 2 is usage). On ANY refusal
# the reason is the FIRST line of stderr, and the branch ref and the reply
# file are byte for byte as they were: the reply is written first and put
# back, mode included, if the compare-and-swap that moves the ref loses or
# the run exits any other way (TERM, INT, an error) before the ref moved.
# A run interrupted so is re-run with the same arguments. Only an
# untrappable kill (SIGKILL) between the two writes leaves a cover naming
# the folded tip over an unfolded branch, which a re-run refuses as stale.
#
# Idempotent. After a fold that rewrote --base itself, --base is no longer
# an ancestor of the branch; the ref move leaves a reflog entry naming the
# pre-fold tip, and when the branch's newest reflog entry is that record
# for the current tip, step 2 judges "--base is an ancestor" against the
# recorded pre-fold tip. With no such record step 2 is not relaxed.
#
# Nobody is at a terminal: no editor, pager or prompt, no hook of the
# repository (a private hooks directory replaces them) and no commit
# signing. It does run `git rebase` and `git worktree` in --repo, so a
# filter or merge driver its config wires in would run: call it where the
# wake's own legs ran, never on a repository you do not trust.
#
# Porcelain: its only caller is a runner outside this repository, which
# has no script_dir here to reach it through.

set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

usage() {
    sed -n '2,/^set -euo/{ /^#/s/^# \?//p }' "$0"
}

notes=()
refuse() { # refuse <exit> <reason> [detail...]
    local code="$1"; shift
    printf 'lkml-author-finalize: %s\n' "$1" >&2
    shift
    (( $# == 0 )) || printf '%s\n' "$@" >&2
    exit "$code"
}

for arg in "$@"; do
    case "$arg" in -h|--help) usage; exit 0 ;; esac
done

base_in="${FS_FINALIZE_BASE:-}"
floor_in="${FS_FINALIZE_FLOOR:-}"
reply="${FS_FINALIZE_REPLY:-}"
repo=""
branch_in=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base|--floor|--reply|--repo|--branch)
            [[ $# -ge 2 ]] || refuse 1 "$1 needs a value."
            case "$1" in
                --base) base_in="$2" ;;
                --floor) floor_in="$2" ;;
                --reply) reply="$2" ;;
                --repo) repo="$2" ;;
                --branch) branch_in="$2" ;;
            esac
            shift 2 ;;
        *) refuse 1 "unknown argument '$1'; see --help." ;;
    esac
done

[[ -n "$base_in" ]] || refuse 1 "no base: give --base or set FS_FINALIZE_BASE."
[[ -n "$reply" ]] || refuse 1 "no reply file: give --reply or set FS_FINALIZE_REPLY."
[[ -f "$reply" && -r "$reply" ]] || refuse 1 "the reply file $reply does not exist or is not readable."
[[ -w "$reply" ]] || refuse 1 "the reply file $reply is not writable."
[[ -n "$repo" ]] || repo="$PWD"
[[ -d "$repo" ]] || refuse 1 "--repo $repo is not a directory."

# Nobody is at a terminal. Every git call below goes through here.
export GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat GIT_EDITOR=true \
       GIT_SEQUENCE_EDITOR=true GIT_OPTIONAL_LOCKS=0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
tmp="$(mktemp -d)"
hooks="$tmp/hooks"
mkdir -p "$hooks"
export FIN_MAP="$tmp/rewrite.map"
: > "$FIN_MAP"
# The only hook that runs: git hands the old->new map of a rebase to
# post-rewrite on stdin, which is the exact answer to "which commit became
# which" (matching by subject or position would guess).
# shellcheck disable=SC2016  # the hook's own $FIN_MAP, expanded by it
printf '#!/bin/sh\ncat >> "$FIN_MAP"\n' > "$hooks/post-rewrite"
chmod +x "$hooks/post-rewrite"

g() {
    git -C "$repo" -c core.hooksPath="$hooks" -c commit.gpgsign=false \
        -c rebase.updateRefs=false -c rebase.autoStash=false \
        -c core.editor=true -c sequence.editor=true "$@" </dev/null
}

wt="$tmp/wt"
reply_pending=false  # the reply is rewritten and the ref has not moved
new_tip=""
cleanup() {
    local rc=$?
    trap - EXIT
    if $reply_pending && [[ "$(g rev-parse -q --verify "$branch_ref" 2>/dev/null)" != "$new_tip" ]]; then
        cp -p -- "$tmp/reply.orig" "$reply" || true
    fi
    if [[ -d "$wt" ]]; then
        g worktree remove --force "$wt" >/dev/null 2>&1 || true
    fi
    g worktree prune >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

g rev-parse --git-dir >/dev/null 2>&1 || refuse 1 "--repo $repo is not a git repository."
# The fold commits in --repo, so its identity is the one that matters.
if ! g var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    export GIT_COMMITTER_NAME="lkml-author-finalize" GIT_COMMITTER_EMAIL="lkml-author-finalize@localhost"
fi

commit_of() { g rev-parse --verify --quiet "$1^{commit}" 2>/dev/null; }
is_ancestor() { g merge-base --is-ancestor "$1" "$2" 2>/dev/null; }
is_sha() { [[ "$1" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; }

# --- the branch -----------------------------------------------------------
if [[ -z "$branch_in" ]]; then
    branch_ref="$(g symbolic-ref -q HEAD 2>/dev/null)" \
        || refuse 1 "no --branch given and HEAD is detached in $repo."
else
    branch_ref="$branch_in"
    [[ "$branch_ref" == refs/* ]] || branch_ref="refs/heads/$branch_ref"
fi
[[ "$branch_ref" == refs/heads/* ]] || refuse 1 "--branch $branch_in is not a local branch."
tip="$(g rev-parse --verify --quiet "$branch_ref^{commit}" 2>/dev/null)" \
    || refuse 1 "the branch $branch_ref does not exist in $repo."

base="$(commit_of "$base_in")" || refuse 1 "--base $base_in is not a commit in $repo."
floor_given="${floor_in:-$base_in}"
floor="$(commit_of "$floor_given")" || refuse 1 "--floor $floor_given is not a commit in $repo."

# --- 1. the shape of the inputs -------------------------------------------
# Must stay ahead of every exit 2: none of these is cured by a new reply.
is_ancestor "$floor" "$base" || refuse 1 "the floor $floor is neither --base nor an ancestor of it."
reflog_prev=""
base_ok=false
if is_ancestor "$base" "$tip"; then
    base_ok=true
else
    # A fold that rewrote --base leaves this record; see the header.
    rec="$(g log -g -1 --format='%H %gs' "$branch_ref" 2>/dev/null || true)"
    if [[ "$rec" =~ ^([0-9a-f]{40,64})\ lkml-author-finalize:\ folded\ ([0-9a-f]{40,64})$ ]] \
        && [[ "${BASH_REMATCH[1]}" == "$tip" ]]; then
        reflog_prev="$(commit_of "${BASH_REMATCH[2]}" || true)"
        [[ -n "$reflog_prev" ]] && is_ancestor "$base" "$reflog_prev" && base_ok=true
    fi
fi
$base_ok || refuse 1 "--base $base is not an ancestor of the branch $branch_ref."
[[ -z "$(g rev-list --merges "$floor..$tip")" ]] \
    || refuse 1 "a merge commit lies above the floor $floor; a series is linear."

# --- 2. the cover's two lines ---------------------------------------------
cover_py="$tmp/cover.py"
cat > "$cover_py" <<'PY'
import re, sys

HEAD = re.compile(r"^(Frozen-Head|Described-Tip):(.*)$")
RD_HEADER = re.compile(r"^(\s*)(?:\d+|-):\s+(?:[0-9a-f]+|-+)\s+[=!<>]\s+(?:\d+|-):\s+(?:[0-9a-f]+|-+)(?:\s.*)?$")
SINCE = re.compile(r"^##\s+Since\s+v\d+")


def split(text):
    i = text.find("\n\n")
    return (text, "") if i < 0 else (text[:i + 1], text[i + 1:])


def keyed(body, key):
    for line in body.split("\n"):
        mt = HEAD.match(line.strip(" \t\r"))
        if mt and mt.group(1) == key:
            return mt.group(2).strip(" \t\r")
    return None


def read(path):
    text = open(path, encoding="utf-8", errors="surrogateescape").read()
    body = split(text)[1]
    for key in ("Frozen-Head", "Described-Tip"):
        v = keyed(body, key)
        print(key + " " + ("-" if v is None else "+" + v))


def rewrite(path, out, tip, count, rd_path, map_path, base, notes_path):
    text = open(path, encoding="utf-8", errors="surrogateescape").read()
    head, body = split(text)
    notes = []
    new_head, n = re.subn(r"(?m)^(Subject:.*?\b0/)\d+(\])", lambda m: m.group(1) + count + m.group(2), head, count=1)
    if not n:
        notes.append("the cover has no 0/<K> subject: nothing to update there")
    rd = open(rd_path, encoding="utf-8", errors="surrogateescape").read().rstrip("\n").split("\n")
    pairs = {}
    for line in open(map_path).read().split("\n"):
        f = line.split()
        if len(f) >= 2 and f[0] != f[1]:
            pairs[f[0]] = f[1]
    lines = body.split("\n")
    start = next((i for i, l in enumerate(lines) if SINCE.match(l)), None)
    keep = set()  # line indexes not to rewrite shas in
    if start is None:
        notes.append("the cover has no '## Since v<N>' section: no range-diff to update")
    else:
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
        first = next((i for i in range(start + 1, end) if RD_HEADER.match(lines[i])), None)
        if first is None:
            ins = [""] + ["    " + l for l in rd] + [""]
            if lines[start + 1:start + 2] == [""]:
                ins = ins[1:]
            lines[start + 1:start + 1] = ins
            keep.update(range(start + 1, start + 1 + len(ins)))
        else:
            indent = RD_HEADER.match(lines[first]).group(1)
            last = first
            for i in range(first, end):
                l = lines[i]
                if RD_HEADER.match(l) or (l.strip() and len(l) - len(l.lstrip()) > len(indent)):
                    last = i
                elif l.strip():
                    break
            lines[first:last + 1] = [indent + l for l in rd]
            keep.update(range(first, first + len(rd)))
    tok = re.compile(r"(?<![0-9A-Za-z])[0-9a-f]{7,64}(?![0-9A-Za-z])")

    def sub(m):
        t = m.group(0)
        if base.startswith(t):
            return t
        hit = [o for o in pairs if o.startswith(t)]
        return pairs[hit[0]][:len(t)] if len(hit) == 1 else t

    for i, l in enumerate(lines):
        if i in keep or HEAD.match(l.strip(" \t\r")) and l.strip(" \t\r").startswith(("Frozen-Head", "Described-Tip")):
            continue
        lines[i] = tok.sub(sub, l)
    done = False
    for i, l in enumerate(lines):
        if l.strip(" \t\r").startswith("Described-Tip:"):
            j = l.index("Described-Tip:")
            lines[i] = l[:j] + "Described-Tip: " + tip
            done = True
            break
    if not done:
        raise SystemExit("no Described-Tip line")
    open(out, "w", encoding="utf-8", errors="surrogateescape").write(new_head + "\n".join(lines))
    open(notes_path, "w").write("".join(n + "\n" for n in notes))


if sys.argv[1] == "read":
    read(sys.argv[2])
else:
    rewrite(*sys.argv[2:])
PY

cover_read="$(python3 -I "$cover_py" read "$reply")" \
    || refuse 1 "the reply file $reply cannot be read as a cover."
cover_line() { # cover_line <key>: the value after its '+', empty when absent
    local v; v="$(sed -n "s/^$1 //p" <<<"$cover_read")"
    [[ "$v" == +* ]] && printf '%s' "${v#+}"
    return 0
}
cover_has() { [[ "$(sed -n "s/^$1 //p" <<<"$cover_read")" == +* ]]; }
cover_has Frozen-Head || refuse 2 "the cover must carry Frozen-Head: $floor alone on a line in its body."
cover_has Described-Tip || refuse 2 "the cover must carry Described-Tip: $tip alone on a line in its body."
frozen_in="$(cover_line Frozen-Head)"; frozen_in="${frozen_in,,}"
described="$(cover_line Described-Tip)"; described="${described,,}"
frozen=""; described_c=""
if is_sha "$frozen_in"; then frozen="$(commit_of "$frozen_in" || true)"; fi
[[ -n "$frozen" ]] || refuse 2 "the cover must carry Frozen-Head: $floor (a full sha naming a commit)."
if is_sha "$described"; then described_c="$(commit_of "$described" || true)"; fi
[[ -n "$described_c" ]] || refuse 2 "the cover must carry Described-Tip: $tip (a full sha naming a commit)."

[[ "$described_c" == "$tip" ]] \
    || refuse 2 "stale cover: it describes a different tip; the cover must carry Described-Tip: $tip."
if [[ "$frozen" != "$floor" ]]; then
    if is_ancestor "$frozen" "$floor"; then
        notes+=("note: the cover's Frozen-Head is below the floor; folding stops at the floor $floor.")
    else
        refuse 2 "the cover must carry Frozen-Head: $floor (or the full sha of an ancestor of it); $frozen is above the floor or unrelated to it."
    fi
fi

# --- 3. fold aside --------------------------------------------------------
fold_out="$tmp/fold.out"
g worktree prune >/dev/null 2>&1 || true
g worktree add --detach "$wt" "$tip" >"$fold_out" 2>&1 \
    || refuse 1 "cannot create the scratch worktree." "$(cat "$fold_out")"
git -C "$wt" -c core.hooksPath="$hooks" -c commit.gpgsign=false \
    -c rebase.updateRefs=false -c rebase.autoStash=false \
    -c core.editor=true -c sequence.editor=true \
    rebase -i --autosquash --no-fork-point "$floor" </dev/null >"$fold_out" 2>&1 \
    || refuse 1 "the fold failed (git rebase --autosquash onto $floor)." "$(cat "$fold_out")"
new_tip="$(git -C "$wt" rev-parse --verify HEAD)"

# --- 4. the tree is unchanged ---------------------------------------------
[[ "$(g rev-parse "$tip^{tree}")" == "$(g rev-parse "$new_tip^{tree}")" ]] \
    || refuse 1 "the fold changed the tree ($tip -> $new_tip); history may change, content may not."

# --- 5. the series check --------------------------------------------------
if ! check_out="$("$script_dir/lkml-series-check.sh" --repo "$repo" \
        --boundary "$frozen" "$new_tip" 2>&1)"; then
    refuse 1 "the folded series is not a clean re-roll (lkml-series-check.sh refused it)." "$check_out"
fi

flush_notes() { (( ${#notes[@]} == 0 )) || printf '%s\n' "${notes[@]}" >&2; }
if [[ "$new_tip" == "$tip" ]]; then
    flush_notes
    exit 0
fi

# --- 6. the cover is made true --------------------------------------------
count="$(g rev-list --count "$frozen..$new_tip")"
# The <base> <old-tip> <new-tip> form: with --base the frozen head the
# previous series is empty, which git rejects as a range spelled F..F;
# this form lists every new commit as added.
g range-diff --no-color "$frozen" "$base" "$new_tip" > "$tmp/rd.txt" 2>"$tmp/rd.err" \
    || refuse 1 "git range-diff failed." "$(cat "$tmp/rd.err")"
# Only the pairs whose new sha is in the folded series.
g rev-list "$floor..$new_tip" > "$tmp/new.list"
awk 'NR==FNR { keep[$1]=1; next } ($2 in keep) { last[$1]=$2 } END { for (o in last) print o, last[o] }' \
    "$tmp/new.list" "$FIN_MAP" > "$tmp/pairs.txt"
python3 -I "$cover_py" rewrite "$reply" "$tmp/cover.new" "$new_tip" "$count" \
    "$tmp/rd.txt" "$tmp/pairs.txt" "$base" "$tmp/notes.txt" \
    || refuse 1 "cannot rewrite the cover."
while IFS= read -r line; do notes+=("note: $line"); done < "$tmp/notes.txt"

# --- the two writes: reply first, then the ref by compare-and-swap --------
cp -p -- "$reply" "$tmp/reply.orig"
reply_pending=true
cat -- "$tmp/cover.new" > "$reply"
if ! g update-ref --create-reflog -m "lkml-author-finalize: folded $tip" \
        "$branch_ref" "$new_tip" "$tip" 2>"$tmp/ref.err"; then
    refuse 1 "the branch $branch_ref moved while folding; nothing changed." "$(cat "$tmp/ref.err")"
fi
reply_pending=false
flush_notes
