#!/usr/bin/env bash
# lkml-author-finalize-bundle-test.sh — Exercise the standalone bundle.
# Usage: bash tests/lkml-author-finalize-bundle-test.sh

set -uo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
gen="$root/scripts/lkml-author-finalize-bundle.sh"
direct="$root/scripts/lkml-author-finalize.sh"
real_git="$(command -v git)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1: expected '$2', got '$3'"; fi; }
holds() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

mkdir "$work/stage" "$work/bin"
"$gen" --output "$work/stage/finalize" >/dev/null
cp "$work/stage/finalize" "$work/bin/finalize"
bundle="$work/bin/finalize"
shell='sh'
if command -v dash >/dev/null 2>&1; then shell=dash; fi
shell_path="$(command -v "$shell")"
printf 'bundle shell: %s\n' "$shell"
"$gen" --check "$bundle" >/dev/null; check '--check fresh' 0 "$?"
"$gen" --output "$work/stage/second" >/dev/null
holds 'second --output identical' cmp -s "$bundle" "$work/stage/second"
mkdir "$work/stage/directory"
"$gen" --output "$work/stage/directory" >"$work/output.out" 2>"$work/output.err"; check '--output rejects directory' 1 "$?"
holds 'directory stays empty' test -z "$(ls -A "$work/stage/directory")"
ln -s "$work/stage/directory" "$work/stage/directory-link"
"$gen" --output "$work/stage/directory-link" >"$work/output.out" 2>"$work/output.err"; check '--output rejects directory symlink' 1 "$?"
holds 'directory symlink stays a symlink' test -L "$work/stage/directory-link"
printf '\n' >> "$work/stage/second"
"$gen" --check "$work/stage/second" >/dev/null; check '--check edited' 1 "$?"
ln -s "$bundle" "$work/stage/link"
"$gen" --check "$work/stage/link" >/dev/null; check '--check symlink' 1 "$?"

new_repo() {
    repo="$work/$1"
    git init -q -b topic "$repo"
    git -C "$repo" config user.name Example
    git -C "$repo" config user.email example@example.com
    printf 'start\n' > "$repo/a"
    git -C "$repo" add a; git -C "$repo" commit -qm frozen
    floor="$(git -C "$repo" rev-parse HEAD)"
    printf 'second\n' > "$repo/b"
    git -C "$repo" add b; git -C "$repo" commit -qm 'series: second'
    base="$(git -C "$repo" rev-parse HEAD)"
    printf 'fix\n' >> "$repo/b"
    git -C "$repo" add b; git -C "$repo" commit -qm 'fixup! series: second'
    tip="$(git -C "$repo" rev-parse HEAD)"
    reply="$work/$1.reply"
    printf 'Subject: [PATCH v2 0/2] example\n\nFrozen-Head: %s\nDescribed-Tip: %s\n\n## Since v1\n\n' "$floor" "$tip" > "$reply"
}
run_direct() { "$direct" --repo "$repo" --base "$base" --floor "$floor" --reply "$reply" >"$work/direct.out" 2>"$work/direct.err"; direct_rc=$?; }
run_bundle() { ( cd "$repo" && FS_FINALIZE_BASE="$base" FS_FINALIZE_FLOOR="$floor" FS_FINALIZE_REPLY="$reply" "$shell_path" "$bundle" ) >"$work/bundle.out" 2>"$work/bundle.err"; bundle_rc=$?; }

new_repo source
cp -a "$repo" "$work/direct-repo"
cp -a "$repo" "$work/bundle-repo"
cp "$reply" "$work/direct.reply"; cp "$reply" "$work/bundle.reply"
repo="$work/direct-repo"; reply="$work/direct.reply"; run_direct
repo="$work/bundle-repo"; reply="$work/bundle.reply"; run_bundle
check 'successful fold status' "$direct_rc" "$bundle_rc"
check 'successful fold tree' "$(git -C "$work/direct-repo" rev-parse 'HEAD^{tree}')" "$(git -C "$work/bundle-repo" rev-parse 'HEAD^{tree}')"
check 'direct cover names direct tip' "Described-Tip: $(git -C "$work/direct-repo" rev-parse topic)" "$(grep '^Described-Tip:' "$work/direct.reply")"
check 'bundle cover names bundle tip' "Described-Tip: $(git -C "$work/bundle-repo" rev-parse topic)" "$(grep '^Described-Tip:' "$work/bundle.reply")"
check 'successful cover count' "$(grep '^Subject:' "$work/direct.reply")" "$(grep '^Subject:' "$work/bundle.reply")"
check 'successful Frozen-Head' "$(grep '^Frozen-Head:' "$work/direct.reply")" "$(grep '^Frozen-Head:' "$work/bundle.reply")"
check 'successful reflog' "$(git -C "$work/direct-repo" log -g -1 --format=%gs topic)" "$(git -C "$work/bundle-repo" log -g -1 --format=%gs topic)"
check 'bundle leaves one worktree' 1 "$(git -C "$work/bundle-repo" worktree list | wc -l | tr -d ' ')"

for kind in missing-tip bad-base; do
    new_repo "$kind"
    if [[ "$kind" == missing-tip ]]; then sed -i '/^Described-Tip:/d' "$reply"; else base=invalid; fi
    run_direct; run_bundle
    check "$kind status" "$direct_rc" "$bundle_rc"
    check "$kind first line" "$(head -n 1 "$work/direct.err")" "$(head -n 1 "$work/bundle.err")"
done

mkdir "$work/no-python"
for program in bash git mktemp base64 chmod rm; do ln -s "$(command -v "$program")" "$work/no-python/$program"; done
new_repo missing-program
( cd "$repo" && PATH="$work/no-python" FS_FINALIZE_BASE="$base" FS_FINALIZE_FLOOR="$floor" FS_FINALIZE_REPLY="$reply" "$shell_path" "$bundle" ) >"$work/bundle.out" 2>"$work/bundle.err"; bundle_rc=$?
check 'missing python status' 1 "$bundle_rc"
holds 'missing python first line' grep -q '^lkml-author-finalize-bundle: python3 ' "$work/bundle.err"

# The embedded series checker calls grep, so the bundle asks for it up front.
mkdir "$work/no-grep"
for program in bash git python3 mktemp base64 chmod rm; do ln -s "$(command -v "$program")" "$work/no-grep/$program"; done
before="$(git -C "$repo" rev-parse topic)"
( cd "$repo" && PATH="$work/no-grep" FS_FINALIZE_BASE="$base" FS_FINALIZE_FLOOR="$floor" FS_FINALIZE_REPLY="$reply" "$shell_path" "$bundle" ) >"$work/bundle.out" 2>"$work/bundle.err"; bundle_rc=$?
check 'missing grep status' 1 "$bundle_rc"
holds 'missing grep first line' grep -q '^lkml-author-finalize-bundle: grep ' "$work/bundle.err"
check 'missing grep leaves the branch' "$before" "$(git -C "$repo" rev-parse topic)"

new_repo term
before="$(git -C "$repo" rev-parse topic)"
cp -p "$reply" "$work/term.before"
mkdir "$work/termbin"
cat > "$work/termbin/git" <<EOF
#!/bin/sh
case " \$* " in
    *" update-ref "*) touch "$work/termbin/fired"; kill -TERM "\$(cat "$work/bundle.pid")"; sleep 12; exit 1 ;;
esac
exec "$real_git" "\$@"
EOF
chmod +x "$work/termbin/git"
( cd "$repo" && PATH="$work/termbin:$PATH" FS_FINALIZE_BASE="$base" FS_FINALIZE_FLOOR="$floor" FS_FINALIZE_REPLY="$reply" "$shell_path" "$bundle" ) >"$work/term.out" 2>"$work/term.err" &
pid=$!; printf '%s\n' "$pid" > "$work/bundle.pid"
deadline=$((SECONDS + 9))
while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then
    no 'TERM exits before runner KILL deadline'
    kill -KILL "$pid" 2>/dev/null || :
else
    ok 'TERM exits before runner KILL deadline'
fi
wait "$pid"; term_rc=$?
holds 'TERM reached update-ref' test -e "$work/termbin/fired"
holds 'TERM exits nonzero' test "$term_rc" -ne 0
check 'TERM restores branch' "$before" "$(git -C "$repo" rev-parse topic)"
holds 'TERM restores reply' cmp -s "$work/term.before" "$reply"
check 'TERM leaves one worktree' 1 "$(git -C "$repo" worktree list | wc -l | tr -d ' ')"

# A finalize that ignores TERM is in a process group the runner's KILL does
# not reach, so the bundle must kill it, inside the runner's grace period.
new_repo hung
mkdir "$work/hungbin"
cat > "$work/hungbin/git" <<EOF
#!/bin/sh
case " \$* " in
    *" update-ref "*) trap '' TERM; echo \$\$ > "$work/hung.pid"; kill -TERM "\$(cat "$work/bundle.pid")"; sleep 30; exit 1 ;;
esac
exec "$real_git" "\$@"
EOF
chmod +x "$work/hungbin/git"
( cd "$repo" && PATH="$work/hungbin:$PATH" FS_FINALIZE_BASE="$base" FS_FINALIZE_FLOOR="$floor" FS_FINALIZE_REPLY="$reply" "$shell_path" "$bundle" ) >"$work/hung.out" 2>"$work/hung.err" &
pid=$!; printf '%s\n' "$pid" > "$work/bundle.pid"
deadline=$((SECONDS + 9))
while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then
    no 'a hung finalize is killed before runner KILL deadline'
    kill -KILL "$pid" 2>/dev/null || :
else
    ok 'a hung finalize is killed before runner KILL deadline'
fi
wait "$pid"; hung_rc=$?
check 'a hung finalize exits 143' 143 "$hung_rc"
holds 'the hung finalize reached update-ref' test -s "$work/hung.pid"
if kill -0 "$(cat "$work/hung.pid" 2>/dev/null)" 2>/dev/null; then
    no 'nothing of the hung finalize survives'
    kill -KILL "$(cat "$work/hung.pid")" 2>/dev/null || :
else
    ok 'nothing of the hung finalize survives'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
