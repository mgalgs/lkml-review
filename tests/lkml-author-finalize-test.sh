#!/usr/bin/env bash
# lkml-author-finalize-test.sh — Exercise lkml-author-finalize.sh.
#
# Every case builds a scratch repository: F (the frozen head, with a
# frozen commit below it), P1 and P2 (the previous version; --base is
# P2), W1 (this wake's own commit), then `fixup!` commits, and a cover in
# the persona's shape written over that tip. The real
# lkml-series-check.sh sits beside the script under test; the cases that
# need to interfere with it copy the script next to a stub.
#
# Every refusal goes through `refused`, which asserts the exit status, that
# the first stderr line carries the reason, and that the branch ref and
# the reply file are exactly as they were, with no rebase in progress and
# no worktree left behind.
#
# Usage: tests/lkml-author-finalize-test.sh

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fin="$repo_dir/scripts/lkml-author-finalize.sh"

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}
# holds <label> <command...>: ok when the command succeeds.
holds() { local l="$1"; shift; if "$@"; then ok "$l"; else no "$l"; fi; }
differs() { [[ "$1" != "$2" ]]; }
contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed."; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed."; exit 0; }
[[ -x "$fin" ]] || { echo "not executable: $fin" >&2; exit 1; }

work="$(mktemp -d)"; tmpdirs+=("$work")

# new_repo <name>: F <- P1 <- P2 <- W1 on branch `topic`, one file each.
# Sets REPO F P1 P2 W1 and leaves `topic` checked out. Frozen commit F0
# lies below F.
commit_file() { # commit_file <file> <content> <subject>
    printf '%s\n' "$2" > "$REPO/$1"
    git -C "$REPO" add -- "$1"
    git -C "$REPO" commit -q -m "$3"
}
new_repo() {
    REPO="$work/$1"
    git init -q -b topic "$REPO"
    git -C "$REPO" config user.name "Test"
    git -C "$REPO" config user.email "test@example.com"
    git -C "$REPO" config commit.gpgsign false
    commit_file f0.txt zero "frozen: the first frozen commit"
    commit_file f.txt frozen "frozen: the frozen head"
    F="$(git -C "$REPO" rev-parse HEAD)"
    commit_file p1.txt p1 "series: first patch of v2"
    P1="$(git -C "$REPO" rev-parse HEAD)"
    commit_file p2.txt p2 "series: second patch of v2"
    P2="$(git -C "$REPO" rev-parse HEAD)"
    commit_file w1.txt w1 "series: this wake's patch"
    W1="$(git -C "$REPO" rev-parse HEAD)"
}
fixup() { # fixup <target subject> <file> <content>
    printf '%s\n' "$3" >> "$REPO/$2"
    git -C "$REPO" add -- "$2"
    git -C "$REPO" commit -q -m "fixup! $1"
}
tip_of() { git -C "$REPO" rev-parse "${1:-topic}"; }

# write_cover <file> [<described-tip>] [<frozen-head>] [<previous tip>]:
# a re-roll cover over the current tip, with the real range-diff.
write_cover() {
    local file="$1" tip="${2:-$(tip_of)}" frozen="${3:-$F}" prev="${4:-$P2}" k
    k="$(git -C "$REPO" rev-list --count "$frozen..$tip")"
    {
        printf 'To: @core, @tests\nSubject: [PATCH v3 0/%s] example series\nReply-To-Id: m001\nVersion: 3\n\n' "$k"
        printf 'Frozen-Head: %s\nDescribed-Tip: %s\n\n' "$frozen" "$tip"
        printf 'Changelog:\n- accepted the leak point, fixed in %s\n' "$(git -C "$REPO" rev-parse --short=12 "$tip^")"
        printf -- '- the naming point is in %s, as in v2 (%s)\n\n' "$(git -C "$REPO" rev-parse --short=12 "${W1}")" "$(git -C "$REPO" rev-parse --short=12 "$P2")"
        printf '## Testing\nran: 12 passed, 0 failed\n\n## Since v2\n\n'
        git -C "$REPO" range-diff --no-color "$frozen" "$prev" "$tip" | sed 's/^/    /'
        printf '\npod/example-branch\n'
    } > "$file"
}

fin_run() { # fin_run <args...>: sets RC, ERR (stderr), first line in ERR1
    ERR="$work/err.$$"
    "$fin" "$@" >/dev/null 2>"$ERR" </dev/null; RC=$?
    ERR1="$(head -n1 "$ERR")"
}
git_state() { # a fingerprint of everything a refusal must not change
    git -C "$REPO" for-each-ref --format='%(refname) %(objectname)'
    git -C "$REPO" rev-parse HEAD
}
# reply_arg <args...>: the file the args pass as --reply, else $REPLY_FILE.
reply_arg() {
    local r="$REPLY_FILE"
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --reply && $# -ge 2 ]]; then r="$2"; shift; fi
        shift
    done
    printf '%s' "$r"
}
# refused <label> <rc> <phrase> <args...>: run, assert a refusal that
# changed nothing, the reply the run was given included.
refused() {
    local label="$1" rc="$2" phrase="$3"; shift 3
    local before after gd reply
    reply="$(reply_arg "$@")"
    cp -p -- "$reply" "$work/reply.before"
    before="$(git_state)"
    fin_run "$@"
    check "$label: exit $rc" "$rc" "$RC"
    contains "$label: first line says why" "$ERR1" "$phrase"
    if [[ "$rc" == 2 ]]; then
        holds "$label: first line is one short line" test "${#ERR1}" -lt 500
        check "$label: reason is on the first line" 1 "$(wc -l < "$ERR" | tr -d ' ')"
    fi
    after="$(git_state)"
    check "$label: refs unchanged" "$before" "$after"
    holds "$label: reply byte-identical" cmp -s -- "$work/reply.before" "$reply"
    check "$label: one worktree" 1 "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')"
    gd="$(git -C "$REPO" rev-parse --git-dir)"; [[ "$gd" == /* ]] || gd="$REPO/$gd"
    check "$label: no rebase in progress" "" "$(ls -d "$gd"/rebase-merge "$gd"/rebase-apply 2>/dev/null)"
    REFUSAL_LINES+=("$ERR1")
}
REFUSAL_LINES=()

# The standard scenario: two fixups, one aimed at this wake's commit and
# one at a commit from the previous version.
std() { # std <name>: sets REPLY_FILE; reply written over the fixed tip
    new_repo "$1"
    fixup "series: this wake's patch" w1.txt w1-fix
    fixup "series: first patch of v2" p1.txt p1-fix
    REPLY_FILE="$work/$1.reply"
    write_cover "$REPLY_FILE"
}

printf '\n== fold: both fixups, tree identical, cover true ==\n'
std fold
OLD="$(tip_of)"; OLD_TREE="$(git -C "$REPO" rev-parse "$OLD^{tree}")"
cp -- "$REPLY_FILE" "$work/fold.orig"
fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
check "exit 0" 0 "$RC"
NEW="$(tip_of)"
holds "the branch moved" differs "$NEW" "$OLD"
check "the tree is identical" "$OLD_TREE" "$(git -C "$REPO" rev-parse "$NEW^{tree}")"
check "no fixup! subject remains above the floor" 0 "$(git -C "$REPO" log --format=%s "$F..$NEW" | grep -c '^fixup!')"
check "three commits above the frozen head" 3 "$(git -C "$REPO" rev-list --count "$F..$NEW")"
holds "the floor is an ancestor" git -C "$REPO" merge-base --is-ancestor "$F" "$NEW"
check "Described-Tip is the new tip" "Described-Tip: $NEW" "$(grep '^Described-Tip:' "$REPLY_FILE")"
check "Frozen-Head is unchanged" "Frozen-Head: $F" "$(grep '^Frozen-Head:' "$REPLY_FILE")"
check "the commit count in the subject" "Subject: [PATCH v3 0/3] example series" "$(grep '^Subject:' "$REPLY_FILE")"
# The range-diff block equals a fresh one, modulo its indent; the prose
# before it and the branch name after it survive.
fresh="$(git -C "$REPO" range-diff --no-color "$F..$P2" "$F..$NEW")"
block="$(awk '/^## Since v2/{f=1; next} f && /^pod\//{exit} f && NF' "$REPLY_FILE" | sed 's/^    //')"
check "the range-diff is the fresh one" "$fresh" "$block"
check "the branch name survives" "pod/example-branch" "$(tail -n1 "$REPLY_FILE")"
contains "the prose survives" "$(cat "$REPLY_FILE")" "- accepted the leak point, fixed in"
# Shas in the changelog: this wake's commit and the fixup's target moved;
# v2's own commit is named as written.
stale=0; bad=0
while read -r tok; do
    full="$(git -C "$REPO" rev-parse --verify --quiet "$tok^{commit}")" || { bad=$(( bad + 1 )); continue; }
    if [[ "$full" != "$P2" ]] && ! git -C "$REPO" merge-base --is-ancestor "$full" "$NEW"; then stale=$(( stale + 1 )); fi
done < <(sed -n '/^Changelog:/,/^## Testing/p' "$REPLY_FILE" | grep -oE '\b[0-9a-f]{7,40}\b')
check "every sha in the changelog names the folded branch or v2" "0 0" "$stale $bad"
contains "the w1 token was rewritten" "$(sed -n '/^Changelog:/,/^## Testing/p' "$REPLY_FILE")" "$(git -C "$REPO" log -1 --format=%h --abbrev=12 --grep="this wake's patch" "$NEW")"
check "v2's sha is left as written" 1 "$(grep -c "$(git -C "$REPO" rev-parse --short=12 "$P2")" "$REPLY_FILE")"
cp -- "$REPLY_FILE" "$work/fold.after"; AFTER_REF="$(tip_of)"
fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
check "run twice: exit 0" 0 "$RC"
check "run twice: ref unchanged" "$AFTER_REF" "$(tip_of)"
holds "run twice: reply unchanged" cmp -s -- "$work/fold.after" "$REPLY_FILE"
# The record, not luck, is what made the second run pass.
git -C "$REPO" reflog delete "refs/heads/topic@{0}" 2>/dev/null
cp -p -- "$REPLY_FILE" "$work/reply.before"
refused "without the reflog record the rewritten base is refused" 1 "is not an ancestor" \
    --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"

printf '\n== an empty previous series: --base is the frozen head ==\n'
# The first wake on a thread, or the first fix wake after a human push.
std empty
OLD="$(tip_of)"; OLD_TREE="$(git -C "$REPO" rev-parse "$OLD^{tree}")"
write_cover "$REPLY_FILE" "$OLD" "$F" "$F"
fin_run --repo "$REPO" --base "$F" --reply "$REPLY_FILE"
check "an empty previous series: exit 0" 0 "$RC"
NEW="$(tip_of)"
holds "the branch moved" differs "$NEW" "$OLD"
check "the tree is identical" "$OLD_TREE" "$(git -C "$REPO" rev-parse "$NEW^{tree}")"
check "three commits above the frozen head, no fixup!" "3 0" \
    "$(git -C "$REPO" rev-list --count "$F..$NEW") $(git -C "$REPO" log --format=%s "$F..$NEW" | grep -c '^fixup!')"
check "Described-Tip is the new tip" "Described-Tip: $NEW" "$(grep '^Described-Tip:' "$REPLY_FILE")"
check "the commit count in the subject" "Subject: [PATCH v3 0/3] example series" "$(grep '^Subject:' "$REPLY_FILE")"
check "the reflog records the pre-fold tip" "lkml-author-finalize: folded $OLD" "$(git -C "$REPO" log -g -1 --format=%gs topic)"
# git's own two-range form, with a left range that is empty but valid.
fresh="$(git -C "$REPO" range-diff --no-color "$NEW..$F" "$F..$NEW")"
block="$(awk '/^## Since v2/{f=1; next} f && /^pod\//{exit} f && NF' "$REPLY_FILE" | sed 's/^    //')"
check "the range-diff shows every commit as new" "$fresh" "$block"
check "three added lines, in git's format" 3 "$(grep -cE '^-:  -+ > [0-9]+:  [0-9a-f]+ series: ' <<<"$block")"
fin_run --repo "$REPO" --base "$F" --reply "$REPLY_FILE"
check "run twice: exit 0, ref unchanged" "0 $NEW" "$RC $(tip_of)"

printf '\n== no floor: the floor is the base ==\n'
new_repo nofloor
fixup "series: this wake's patch" w1.txt w1-fix
REPLY_FILE="$work/nofloor.reply"; write_cover "$REPLY_FILE"
fin_run --repo "$REPO" --base "$P2" --reply "$REPLY_FILE"
check "frozen head below the base: exit 0" 0 "$RC"
contains "the note says folding stops at the base" "$(cat "$ERR")" "folding stops at the floor"
check "the base's commits keep their shas" "$P2" "$(git -C "$REPO" rev-parse topic~1)"
check "folded into the wake's commit" 1 "$(git -C "$REPO" rev-list --count "$P2..topic")"
fin_run --repo "$REPO" --base "$P2" --reply "$REPLY_FILE"
check "twice: exit 0" 0 "$RC"
new_repo nofloor2
fixup "series: first patch of v2" p1.txt p1-fix
REPLY_FILE="$work/nofloor2.reply"; write_cover "$REPLY_FILE"
refused "a fixup aimed below the base is left, so the series check refuses" 1 "not a clean re-roll" \
    --repo "$REPO" --base "$P2" --reply "$REPLY_FILE"
contains "the checker's violation follows" "$(cat "$ERR")" "fixup!"

printf '\n== stale cover ==\n'
std stale
fixup "series: this wake's patch" w1.txt later-leg
refused "the cover names an older tip" 2 "describes a different tip" \
    --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
contains "stale tip reason carries the current tip" "$ERR1" "$(tip_of)"
sed -i "s/^Described-Tip:.*/Described-Tip: $(tip_of)/" "$REPLY_FILE"
fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
check "correcting stale tip succeeds" 0 "$RC"

printf '\n== refusals of the inputs ==\n'
REFUSAL_LINES=()
std r1
other="$(git -C "$REPO" commit-tree -m other -p "$F" "$(git -C "$REPO" rev-parse "$F^{tree}")")"
refused "--base is not an ancestor of the branch" 1 "is not an ancestor" --repo "$REPO" --base "$other" --reply "$REPLY_FILE"
REPLY_FILE="$work/r1.nofh-badbase"; write_cover "$REPLY_FILE"
sed -i '/^Frozen-Head:/d' "$REPLY_FILE"
refused "missing Frozen-Head with sibling base is exit 1" 1 "is not an ancestor" \
    --repo "$REPO" --base "$other" --floor "$F" --reply "$REPLY_FILE"
printf 'Frozen-Head: %s\n' "$F" >> "$REPLY_FILE"
refused "correcting cover cannot repair sibling base" 1 "is not an ancestor" \
    --repo "$REPO" --base "$other" --floor "$F" --reply "$REPLY_FILE"
REPLY_FILE="$work/r1.reply"
refused "the floor is neither the base nor below it" 1 "floor" --repo "$REPO" --base "$P2" --floor "$W1" --reply "$REPLY_FILE"
refused "the cover's Frozen-Head is above the floor" 2 "$F" --repo "$REPO" --base "$P2" --floor "$F" \
    --reply "$(write_cover "$work/r1.above" "$(tip_of)" "$P1"; echo "$work/r1.above")"
REPLY_FILE="$work/r1.nofh"; write_cover "$REPLY_FILE"; sed -i '/^Frozen-Head:/d' "$REPLY_FILE"
refused "no Frozen-Head line" 2 "Frozen-Head: $F" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
printf 'Frozen-Head: %s\n' "$F" >> "$REPLY_FILE"
fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
check "adding Frozen-Head succeeds" 0 "$RC"
std r1more
REPLY_FILE="$work/r1.notip"; write_cover "$REPLY_FILE"; sed -i '/^Described-Tip:/d' "$REPLY_FILE"
refused "no Described-Tip line" 2 "Described-Tip: $(tip_of)" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
REPLY_FILE="$work/r1.badfh"; write_cover "$REPLY_FILE"; sed -i 's/^Frozen-Head:.*/Frozen-Head: invalid/' "$REPLY_FILE"
refused "invalid Frozen-Head" 2 "Frozen-Head: $F" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
REPLY_FILE="$work/r1.badtip"; write_cover "$REPLY_FILE"; sed -i 's/^Described-Tip:.*/Described-Tip: invalid/' "$REPLY_FILE"
refused "invalid Described-Tip" 2 "Described-Tip: $(tip_of)" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
REPLY_FILE="$work/r1.unrelated"; write_cover "$REPLY_FILE" "$(tip_of)" "$other"
refused "unrelated Frozen-Head" 2 "Frozen-Head: $F" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
new_repo merge
git -C "$REPO" checkout -q -b side "$P2"
commit_file s.txt side "series: side patch"
git -C "$REPO" checkout -q topic
git -C "$REPO" merge -q --no-ff -m "merge side" side
REPLY_FILE="$work/merge.reply"; write_cover "$REPLY_FILE"
refused "a merge commit above the floor" 1 "merge commit" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"

printf '\n== the fold or the series check refuses ==\n'
std frozenfix
fixup "frozen: the frozen head" f.txt f-fix
REPLY_FILE="$work/frozenfix.reply"; write_cover "$REPLY_FILE"
refused "a fixup aimed at a frozen commit" 1 "not a clean re-roll" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
contains "the checker's violation line follows" "$(cat "$ERR")" "fixup! frozen: the frozen head"
new_repo conflict
commit_file c.txt one "series: c from v2"
git -C "$REPO" rev-parse HEAD > "$work/conflict.c1"
commit_file c.txt two "series: c edited again"
P2="$(git -C "$REPO" rev-parse HEAD)"
commit_file w2.txt w2 "series: wake patch"
printf 'uno\n' > "$REPO/c.txt"; git -C "$REPO" commit -q -a -m "fixup! series: c from v2"
REPLY_FILE="$work/conflict.reply"; write_cover "$REPLY_FILE"
refused "a fold that conflicts" 1 "the fold failed" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"

# A git that moves the tree after the rebase.
new_repo sneaky
fixup "series: this wake's patch" w1.txt w1-fix
REPLY_FILE="$work/sneaky.reply"; write_cover "$REPLY_FILE"
mkdir -p "$work/sneakybin"; real_git="$(command -v git)"
cat > "$work/sneakybin/git" <<EOF
#!/usr/bin/env bash
"$real_git" "\$@"; rc=\$?
[ \$rc -eq 0 ] || exit \$rc
dir=.; is_rebase=0; args=("\$@"); i=0
while [ \$i -lt \${#args[@]} ]; do
    case "\${args[\$i]}" in
        -C) dir="\${args[\$((i+1))]}"; i=\$((i+1)) ;;
        -c) i=\$((i+1)) ;;
        rebase) is_rebase=1 ;;
    esac
    i=\$((i+1))
done
if [ \$is_rebase = 1 ]; then
    ( cd "\$dir" && echo sneak >> w1.txt && "$real_git" add w1.txt && "$real_git" commit -q -m sneak )
fi
exit 0
EOF
chmod +x "$work/sneakybin/git"
PATH="$work/sneakybin:$PATH" refused "a git that changes the tree during the fold" 1 "changed the tree" \
    --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"

printf '\n== cover shapes ==\n'
std prose
python3 - "$work/prose.reply" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
i = t.index("## Since v2"); j = t.index("pod/example-branch")
open(p, "w").write(t[:i] + "## Since v2\n\nThe trees are not identical; see the commits.\n\n" + t[j:])
PY
fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$work/prose.reply"
check "a Since section holding only a sentence: exit 0" 0 "$RC"
contains "the range-diff is inserted under the heading" "$(sed -n '/^## Since v2/,$p' "$work/prose.reply")" "    1:  "
contains "the sentence is kept" "$(cat "$work/prose.reply")" "The trees are not identical"
std bare
sed -i 's/^Subject: .*/Subject: [PATCH v3] example series/; /^## Since v2/,$d' "$work/bare.reply"
printf 'Described-Tip: x\n' >/dev/null
fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$work/bare.reply"
check "no 0/<K> and no Since section: exit 0" 0 "$RC"
contains "a note for the missing count" "$(cat "$ERR")" "no 0/<K>"
contains "a note for the missing section" "$(cat "$ERR")" "no '## Since"
check "Described-Tip still updated" "Described-Tip: $(tip_of)" "$(grep '^Described-Tip:' "$work/bare.reply")"

printf '\n== branch checked out or not ==\n'
std away
git -C "$REPO" checkout -q -b side "$F"
SIDE="$(tip_of side)"; OLD="$(tip_of)"
fin_run --repo "$REPO" --branch topic --base "$P2" --floor "$F" --reply "$REPLY_FILE"
check "not checked out: exit 0" 0 "$RC"
holds "not checked out: the branch moved" differs "$(tip_of)" "$OLD"
check "HEAD and the other branch did not move" "$SIDE $SIDE" "$(tip_of HEAD) $(tip_of side)"
std full
OLD="$(tip_of)"
fin_run --repo "$REPO" --branch refs/heads/topic --base "$P2" --floor "$F" --reply "$REPLY_FILE"
check "the full ref spelling: exit 0, moved" "0 moved" "$RC $([[ "$(tip_of)" != "$OLD" ]] && echo moved)"
std here
fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
check "checked out: exit 0" 0 "$RC"
check "checked out: git status is clean" "" "$(git -C "$REPO" status --porcelain)"

printf '\n== flags, environment, defaults ==\n'
new_repo env
fixup "series: this wake's patch" w1.txt w1-fix
REPLY_FILE="$work/env.reply"; write_cover "$REPLY_FILE"
( cd "$REPO" && FS_FINALIZE_BASE="$P2" FS_FINALIZE_REPLY="$REPLY_FILE" "$fin" >/dev/null 2>"$work/err" </dev/null ); RC=$?
check "bare call with the two variables: exit 0" 0 "$RC"
check "the floor defaulted to the base: one commit above it" 1 "$(git -C "$REPO" rev-list --count "$P2..topic")"
std env2
( cd "$REPO" && FS_FINALIZE_BASE="$F" FS_FINALIZE_FLOOR="$F" FS_FINALIZE_REPLY="$REPLY_FILE" "$fin" --base "$P2" >/dev/null 2>"$work/err" </dev/null ); RC=$?
check "FS_FINALIZE_FLOOR is used, and a --base flag beats the variable: exit 0" 0 "$RC"
check "the fixup aimed below the base folded" 0 "$(git -C "$REPO" log --format=%s "$F..topic" | grep -c '^fixup!')"
# The committer identity is probed in --repo, not where the caller stands.
noident="$work/noident.gitconfig"; printf '[user]\n\tuseConfigOnly = true\n' > "$noident"
std ident1
git -C "$REPO" config --unset user.name; git -C "$REPO" config --unset user.email
git init -q "$work/caller"
git -C "$work/caller" config user.name "Caller"; git -C "$work/caller" config user.email "caller@example.com"
( cd "$work/caller" && GIT_CONFIG_GLOBAL="$noident" "$fin" --repo "$REPO" --base "$P2" --floor "$F" \
    --reply "$REPLY_FILE" >/dev/null 2>"$work/err" </dev/null ); RC=$?
check "a target with no identity, called from a repository with one: exit 0" 0 "$RC"
check "the fallback identity committed the fold" "lkml-author-finalize" "$(git -C "$REPO" log -1 --format=%cn topic)"
std ident2
mkdir -p "$work/outside"
( cd "$work/outside" && GIT_CONFIG_GLOBAL="$noident" GIT_CEILING_DIRECTORIES="$work" "$fin" --repo "$REPO" \
    --base "$P2" --floor "$F" --reply "$REPLY_FILE" >/dev/null 2>"$work/err" </dev/null ); RC=$?
check "a target with an identity, called from outside any repository: exit 0" 0 "$RC"
check "the target's own identity committed the fold" "Test <test@example.com>" "$(git -C "$REPO" log -1 --format='%cn <%ce>' topic)"
std usage
fin_run --reply "$REPLY_FILE" --repo "$REPO"
check "no base: exit 1" 1 "$RC"; contains "no base: says so" "$ERR1" "no base"
fin_run --base "$P2" --bogus --reply "$REPLY_FILE" --repo "$REPO"
check "unknown flag: exit 1" 1 "$RC"; contains "unknown flag: says so" "$ERR1" "unknown argument"
fin_run --base "$P2" --reply "$work/nope" --repo "$REPO"
check "missing reply: exit 1" 1 "$RC"; contains "missing reply: says so" "$ERR1" "does not exist"
mkdir "$work/notrepo"
fin_run --base "$P2" --reply "$REPLY_FILE" --repo "$work/notrepo"
check "not a repository: exit 1" 1 "$RC"; contains "not a repository: says so" "$ERR1" "not a git repository"
git -C "$REPO" checkout -q --detach
fin_run --base "$P2" --reply "$REPLY_FILE" --repo "$REPO"
check "detached HEAD, no --branch: exit 1" 1 "$RC"; contains "detached: says so" "$ERR1" "detached"
check "--help: exit 0 and the usage" "0 Usage: lkml-author-finalize.sh --base <sha> --reply <file>" \
    "$("$fin" --help >"$work/help" 2>&1; echo $?) $(sed -n '/^Usage:/p' "$work/help" | head -n1)"

printf '\n== nobody at a terminal ==\n'
std hooks
for h in pre-rebase post-checkout post-rewrite; do
    printf '#!/bin/sh\ntouch "%s/hook-ran"\nexit 1\n' "$work" > "$REPO/.git/hooks/$h"; chmod +x "$REPO/.git/hooks/$h"
done
git -C "$REPO" config core.editor false; git -C "$REPO" config core.pager false
git -C "$REPO" config commit.gpgsign true; git -C "$REPO" config gpg.program false
OLD="$(tip_of)"
GIT_EDITOR=false GIT_SEQUENCE_EDITOR=false "$fin" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE" >/dev/null 2>"$work/err" <&-; RC=$?
check "hooks, editors, a signing program that fails: exit 0" 0 "$RC"
holds "folded" differs "$(tip_of)" "$OLD"
holds "no repository hook ran" test ! -e "$work/hook-ran"

printf '\n== interrupted and partial runs ==\n'
# A checker that is part of the script's own directory, replaced by a stub.
stub_dir="$work/stub"; mkdir -p "$stub_dir"
cp -- "$fin" "$stub_dir/lkml-author-finalize.sh"
std killed
cp -p -- "$REPLY_FILE" "$work/reply.before"; before="$(git_state)"
cat > "$stub_dir/lkml-series-check.sh" <<EOF
#!/usr/bin/env bash
while [ ! -s "$work/fin.pid" ]; do sleep 0.05; done
kill -TERM "\$(cat "$work/fin.pid")"
exit 0
EOF
chmod +x "$stub_dir/lkml-series-check.sh"; rm -f "$work/fin.pid"
"$stub_dir/lkml-author-finalize.sh" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE" >/dev/null 2>&1 </dev/null &
echo $! > "$work/fin.pid"; wait $!; RC=$?
holds "killed after the fold: non-zero exit ($RC)" test "$RC" -ne 0
check "killed: refs unchanged" "$before" "$(git_state)"
holds "killed: reply unchanged" cmp -s -- "$work/reply.before" "$REPLY_FILE"
check "killed: no worktree left" 1 "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')"
# A branch that moves between the fold and the ref move.
std race
other="$(git -C "$REPO" commit-tree -m raced -p "$(tip_of)" "$(git -C "$REPO" rev-parse "topic^{tree}")")"
cat > "$stub_dir/lkml-series-check.sh" <<EOF
#!/usr/bin/env bash
git -C "$REPO" update-ref refs/heads/topic "$other"
exit 0
EOF
cp -p -- "$REPLY_FILE" "$work/reply.before"
"$stub_dir/lkml-author-finalize.sh" --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE" >/dev/null 2>"$work/err" </dev/null; RC=$?
check "the branch moved under the fold: exit 1" 1 "$RC"
contains "says so first" "$(head -n1 "$work/err")" "moved while folding"
holds "the reply is put back" cmp -s -- "$work/reply.before" "$REPLY_FILE"
check "the branch is where the other writer put it" "$other" "$(tip_of)"
# A registration left by a killed run does not block the next one.
std stalewt
git -C "$REPO" worktree add -q --detach "$work/dead" "$(tip_of)"; rm -rf -- "$work/dead"
fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
check "a stale worktree registration: exit 0" 0 "$RC"
# TERM between the two writes: the reply is rewritten, and a git standing
# in for update-ref signals the script. With <real> the ref then moves as
# well; without, the signal lands before it does.
term_git() { # term_git <dir> <real|none>
    mkdir -p "$1"
    cat > "$1/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
    *" update-ref "*)
        if [ ! -e "$1/fired" ]; then
            touch "$1/fired"
            kill -TERM "\$PPID"
            [ "$2" = real ] && exec "$real_git" "\$@"
            exit 1
        fi ;;
esac
exec "$real_git" "\$@"
EOF
    chmod +x "$1/git"
}
std between
OLD="$(tip_of)"; chmod 0640 "$REPLY_FILE"
cp -p -- "$REPLY_FILE" "$work/reply.before"; before="$(git_state)"
term_git "$work/termbin" none
PATH="$work/termbin:$PATH" fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
holds "TERM between the writes: the signal fired" test -e "$work/termbin/fired"
check "TERM between the writes: exit 143" 143 "$RC"
check "TERM between the writes: refs unchanged" "$before" "$(git_state)"
holds "TERM between the writes: reply byte-identical" cmp -s -- "$work/reply.before" "$REPLY_FILE"
check "TERM between the writes: reply mode kept" 640 "$(stat -c %a "$REPLY_FILE")"
check "TERM between the writes: no worktree left" 1 "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')"
fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
check "the re-run with the same arguments: exit 0" 0 "$RC"
NEW="$(tip_of)"
holds "the re-run folded" differs "$NEW" "$OLD"
check "the re-run's cover names the folded tip" "Described-Tip: $NEW" "$(grep '^Described-Tip:' "$REPLY_FILE")"
# The signal lands as the ref moves: the fold stands, cover and ref agree.
std landed
OLD="$(tip_of)"
term_git "$work/termbin2" real
PATH="$work/termbin2:$PATH" fin_run --repo "$REPO" --base "$P2" --floor "$F" --reply "$REPLY_FILE"
NEW="$(tip_of)"
holds "TERM as the ref moves: the ref moved" differs "$NEW" "$OLD"
check "TERM as the ref moves: the cover names it" "Described-Tip: $NEW" "$(grep '^Described-Tip:' "$REPLY_FILE")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
