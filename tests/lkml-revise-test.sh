#!/usr/bin/env bash
# lkml-revise-test.sh — Exercise lkml-revise.sh's harvest/post-v(N+1) logic
# and its three quiet decision points, against a stub fork-sandbox.sh and a
# real (throwaway) git repo.
#
# Usage: tests/lkml-revise-test.sh
#
# Same "stub the external command on PATH" pattern tests/lkml-round-test.sh
# uses, but lkml-revise.sh is the one script in lkml-mode that runs `git
# format-patch` against the REAL repo (never the persona's clone), so this
# test gives it a real, throwaway git repo rather than /nonexistent/project
# -- there is no clone_dir git history to fake around.
#
# Covers:
#   - the happy path: a run that committed, fetched, and left a cover
#     letter posts vN+1 with the real repo's own format-patch output, and
#     harvests the run's reply alongside it -- as the WHOLE series (format-
#     patch'd from the original --base, not vN's tip), not just this
#     round's fixup commits.
#   - commits == 0: the "a version changes nothing" stop condition exits
#     non-zero but still harvests any reply.
#   - commits > 0 with fetched != true: refuses after harvest rather than
#     posting a resumed checkout and dropping the run's commits.
#   - commits > 0 but no cover-letter.md: refuses to post, names the
#     branch to read by hand, exits non-zero.
#   - lkml-mailbox.sh init itself fails (e.g. the version it would post
#     already exists): exits non-zero and does NOT append to the
#     version-to-branch ledger lkml-forklift.sh reads -- a failed init must
#     not leave a ledger entry for a version with no cover letter.
#   - the handoff names the frozen boundary (an --upstream-head, an
#     inherited ledger head, or the series base) and carries the re-roll
#     rules: fold fixes into the right commit, no fixup!/squash!, a
#     `## Testing` section, accepted/adapted/refused per reviewer point.
#   - the gate (lkml-series-check.sh, next to the script) refuses a fetched
#     branch with a fixup! commit, a comment-only commit, or one not sitting
#     on the --upstream-head; a cover letter with no `## Testing` heading
#     is refused too. Every refusal still harvests replies, posts no
#     version and keeps the branch. A clean re-rolled branch whose commits
#     are not descendants of the checkout tip, only of the boundary, posts.
#   - --frozen-fixups <lo>..<hi>: refused at launch without an upstream
#     boundary or with a bad range; with it the gate gets --allow-fixups-for,
#     the version is formatted from the frozen boundary (patches, diffstat,
#     X-Base), the handoff carries the slice instructions, and a fixup aimed
#     outside the slice is still refused. Without it nothing changes.
#   - a RESUMED author round -- relaunched with --checkout pointed at a dead
#     attempt's fetched branch and --version unchanged, so the run commits
#     nothing of its own -- posts vN+1 from --checkout when it already
#     differs from vN's POSTED tip (the ledger sha, not --checkout itself);
#     an unchanged checkout, or no ledger sha to compare against, still
#     stops; a resumed round with no cover letter is refused exactly like
#     an ordinary one.

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
revise="$repo_dir/scripts/lkml-revise.sh"
mailbox="$repo_dir/scripts/lkml-mailbox.sh"

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed; lkml-revise.sh needs it to read summary.json."
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not installed."
    exit 0
fi

# A real, throwaway repo for `git format-patch` to run against -- this is
# what --project points at, standing in for the operator's actual repo. It
# has a pre-series base commit distinct from v1's tip, so a test that
# passes the ORIGINAL base as --base (as SKILL.md's step 4 now requires)
# and one that mistakenly passed vN's tip instead would disagree about how
# many patches v2 contains -- see the "whole series" assertion below.
real_repo="$(mktemp -d)"; tmpdirs+=("$real_repo")
git -C "$real_repo" init -q
git -C "$real_repo" config user.email t@fork-sandbox.invalid
git -C "$real_repo" config user.name Tester
printf 'this is the trunk the series branches from\n' > "$real_repo/base.txt"
git -C "$real_repo" add base.txt
git -C "$real_repo" commit -q -m "repo: pre-series base"
series_base_sha="$(git -C "$real_repo" rev-parse --verify --quiet HEAD)"

printf 'int frob(void) { return 0; }\n' > "$real_repo/frob.c"
git -C "$real_repo" add frob.c
git -C "$real_repo" commit -q -m "frob: add core"

# --checkout is resolved to a full sha in this repo before the author is
# launched -- give it a real branch to resolve, standing in for the branch
# v1 was posted from.
git -C "$real_repo" branch somebranch -q
somebranch_sha="$(git -C "$real_repo" rev-parse --verify --quiet somebranch)"

# The branch a persona's run would have fetched back into the real repo --
# built here directly, standing in for what fork-sandbox.sh's own fetch
# step does after a real sandboxed run.
git -C "$real_repo" branch v2-branch -q
git -C "$real_repo" checkout v2-branch -q
printf 'int frob(void) { return 1; }\n' > "$real_repo/frob.c"
git -C "$real_repo" commit -q -am "frob: fix return value"
v2_branch_sha="$(git -C "$real_repo" rev-parse --verify --quiet v2-branch)"
git -C "$real_repo" checkout - -q

# A minimal v1 series to revise.
work="$(mktemp -d)"; tmpdirs+=("$work")
# The launcher resolves its seats file from $HOME by default -- pin a
# controlled HOME and an empty LKML_SEATS_FILE so neither a real
# ~/.config/lkml/seats.yaml nor the machine's own HOME can
# leak in (tests/lkml-seats-test.sh does the same).
home_dir="$work/home"; mkdir -p -- "$home_dir"
export HOME="$home_dir" LKML_SEATS_FILE=''
export LKML_MAILBOX_ROOT; LKML_MAILBOX_ROOT="$(mktemp -d)"; tmpdirs+=("$LKML_MAILBOX_ROOT")
cd "$work" || exit 1
printf 'Add the frobnicator\n\nBody.\n' > cover.txt
mkdir patches
printf 'Subject: [PATCH 1/1] frob: add core\n\ndiff\n' > patches/0001.patch
"$mailbox" init widget-frob --cover cover.txt --patches patches --from author \
    --harness claude --model opus --no-checkout >/dev/null 2>&1
patch_id="$("$mailbox" tree widget-frob | awk 'NR==3{print $1}')"
echo "please fix the return value" > q.txt
r1="$("$mailbox" post widget-frob --from core --reply-to "$patch_id" --file q.txt \
    --tags Changes-requested --harness claude --model opus 2>/dev/null)"

stub_bin="$(mktemp -d)"; tmpdirs+=("$stub_bin")
run_prefix_dir="$(mktemp -d)"; tmpdirs+=("$run_prefix_dir")

# Builds a stub fork-sandbox.sh that fabricates one run directory with the
# given summary.json fields and clone_dir contents. Each scenario below
# writes its own stub so commits/fetched/cover-letter can vary.
write_stub() {
    local commits="$1" fetched="$2" write_cover="$3" write_reply="$4"
    local branch="${5:-v2-branch}" testing="${6:-1}" move_branch="${7:-}"
    cat > "$stub_bin/fork-sandbox.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
run_dir="\$(mktemp -d "$run_prefix_dir/run.XXXXXX")"
printf '%s\n' "\$@" > "$run_prefix_dir/last-args"
cp -- "\${!#}" "$run_prefix_dir/last-handoff.md"
clone_dir="\$run_dir/clone/proj"
mkdir -p "\$clone_dir/.git/lkml-out"
STUB
    if [[ "$write_cover" == 1 ]]; then
        cat >> "$stub_bin/fork-sandbox.sh" <<STUB
printf 'Add the return-value fix\n\nv2: fixed frob per core.\n' > "\$clone_dir/.git/lkml-out/cover-letter.md"
STUB
        if [[ "$testing" == 1 ]]; then
            cat >> "$stub_bin/fork-sandbox.sh" <<STUB
printf '\n## Testing\n\nsh run-tests.sh: 4 passed, 0 failed\n' >> "\$clone_dir/.git/lkml-out/cover-letter.md"
STUB
        fi
    fi
    if [[ "$write_reply" == 1 ]]; then
        cat >> "$stub_bin/fork-sandbox.sh" <<STUB
printf 'In-Reply-To: $r1\nX-Tags: Reviewed-by\n\nFixed, see v2.\n' > "\$clone_dir/.git/lkml-out/1.msg"
STUB
    fi
    if [[ -n "$move_branch" ]]; then
        cat >> "$stub_bin/fork-sandbox.sh" <<STUB
git -C "$real_repo" branch -f "$move_branch" "$series_base_sha"
STUB
    fi
    cat >> "$stub_bin/fork-sandbox.sh" <<STUB
jq -n --arg clone_dir "\$clone_dir" --arg branch "$branch" \\
    --argjson commits $commits --argjson fetched $fetched \\
    '{clone_dir: \$clone_dir, branch: \$branch, commits: \$commits, fetched: \$fetched}' \\
    > "\$run_dir/summary.json"
echo "fork-sandbox: launched in a stub"
echo "  run dir:  \$run_dir"
STUB
    chmod +x "$stub_bin/fork-sandbox.sh"
}

printf '\n== happy path: commits + fetched + cover letter ==\n'
write_stub 1 true 1 1
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc=$?
check "exits 0 and posts v2" "0" "$rc"
contains "reports harvesting the reply" "$out" "harvested 1 repl"
contains "reports posting v2" "$out" "posted v2"
contains "v1 was posted --no-checkout, so there is no ledger sha: warns and omits the flag" "$out" \
    "no ledger sha for v1; the v2 cover will carry no \"## Since\" section."

tree_out="$("$mailbox" tree widget-frob)"
contains "v2 shows up in the tree" "$tree_out" "=== v2 ==="
contains "v2's patch carries the real repo's commit message" "$tree_out" "frob: fix return value"
contains "v2 is posted as the whole series (v1's commit plus this round's change), not just the change alone" \
    "$tree_out" "PATCH v2 2/2"
contains "core's Changes-requested was answered with Reviewed-by" \
    "$("$mailbox" tree widget-frob)" "Reviewed-by"

printf '\n== review-target headers ==\n'
reviewed_by_id="$(printf '%s\n' "$tree_out" | grep -m1 Reviewed-by | awk '{print $1}')"
reply_msg="$("$mailbox" show widget-frob "$reviewed_by_id")"
contains "the author's harvested reply carries X-Review-Target for the checkout it was spawned on" \
    "$reply_msg" "X-Review-Target: somebranch $somebranch_sha"
contains "the author's harvested reply carries X-Base" "$reply_msg" "X-Base: $series_base_sha"
v2_cover_id="$(printf '%s\n' "$tree_out" | awk '/^=== v2 ===/{found=1; next} found && /^[[:alnum:]]/{print $1; exit}')"
v2_cover_msg="$("$mailbox" show widget-frob "$v2_cover_id")"
contains "the new cover carries X-Review-Target-Set with the fetched branch's tip sha" \
    "$v2_cover_msg" "X-Review-Target-Set: v2-branch $v2_branch_sha"
contains "the new cover also carries X-Review-Target (same value as -Set)" \
    "$v2_cover_msg" "X-Review-Target: v2-branch $v2_branch_sha"
contains "the new cover carries X-Base with the series' original base" \
    "$v2_cover_msg" "X-Base: $series_base_sha"
case "$v2_cover_msg" in
    *"X-Upstream-Head:"*) no "no --upstream-head was given; the new cover carries no X-Upstream-Head" ;;
    *) ok "no --upstream-head was given; the new cover carries no X-Upstream-Head" ;;
esac
case "$v2_cover_msg" in
    *"## Since"*) no "no ledger sha for v1: the new cover carries no ## Since section" "$v2_cover_msg" ;;
    *) ok "no ledger sha for v1: the new cover carries no ## Since section" ;;
esac

printf '\n== an unresolvable --checkout is refused before any launch ==\n'
out_badco="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout nosuchcheckoutref --version 1 --base "$series_base_sha" 2>&1)"
rc_badco=$?
if (( rc_badco != 0 )); then ok "an unresolvable --checkout exits non-zero"; else no "an unresolvable --checkout exits non-zero" "exit 0: $out_badco"; fi
contains "the refusal names the bad checkout ref" "$out_badco" "nosuchcheckoutref"

printf '\n== an unresolvable --upstream-head is refused before any launch ==\n'
out_baduh="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" \
    --upstream-head nosuchupstreamref 2>&1)"
rc_baduh=$?
if (( rc_baduh != 0 )); then ok "an unresolvable --upstream-head exits non-zero"; else no "an unresolvable --upstream-head exits non-zero" "exit 0: $out_baduh"; fi
contains "the refusal names the bad upstream-head ref" "$out_baduh" "nosuchupstreamref"

printf '\n== the thread is mounted at /thread, not inlined in the handoff ==\n'
# r1's body ("please fix the return value") lives in the message BODY --
# tree/open only ever show subjects -- so its presence in thread.txt (and
# absence from the handoff) proves the thread is rendered once to a mounted
# file rather than inlined.
thread_dir_of() { awk '$0=="--thread-dir"{getline; print; exit}' "$1"; }
handoff_path="$(tail -n1 "$run_prefix_dir/last-args")"
handoff_text="$(cat -- "$handoff_path" 2>/dev/null)"
captured_handoff_text="$(cat -- "$run_prefix_dir/last-handoff.md" 2>/dev/null)"
thread_dir_arg="$(thread_dir_of "$run_prefix_dir/last-args")"
if [[ "$thread_dir_arg" == /var/tmp/claude-scratch/lkml-revise-thread-* && -d "$thread_dir_arg" ]]; then
    ok "fork-sandbox.sh is launched with --thread-dir under the scratch root"
else
    no "fork-sandbox.sh is launched with --thread-dir under the scratch root" "got '$thread_dir_arg'"
fi
if [[ -s "$thread_dir_arg/thread.txt" ]]; then ok "the thread dir holds a non-empty thread.txt"; else no "the thread dir holds a non-empty thread.txt"; fi
contains "thread.txt carries a reply body, not just the tree" "$(cat -- "$thread_dir_arg/thread.txt" 2>/dev/null)" "please fix the return value"
case "$handoff_text" in
    *"please fix the return value"*) no "the handoff no longer inlines reply bodies" "body found inline" ;;
    *) ok "the handoff no longer inlines reply bodies" ;;
esac
contains "handoff points at /thread/thread.txt" "$handoff_text" "/thread/thread.txt"
contains "ordinary handoff keeps the no-commit, no-cover instruction" "$captured_handoff_text" \
    "do not fabricate a cover letter for a"
tree_pos=$(printf '%s' "$handoff_text" | grep -bo '## The full thread tree' | head -n1 | cut -d: -f1)
pointer_pos=$(printf '%s' "$handoff_text" | grep -bo '## The rest of the thread' | head -n1 | cut -d: -f1)
open_pos=$(printf '%s' "$handoff_text" | grep -bo '## Open items' | head -n1 | cut -d: -f1)
if [[ -n "$tree_pos" && -n "$pointer_pos" && -n "$open_pos" \
    && "$tree_pos" -lt "$pointer_pos" && "$pointer_pos" -lt "$open_pos" ]]; then
    ok "the pointer section sits between the tree and open items"
else
    no "the pointer section sits between the tree and open items" "tree=$tree_pos pointer=$pointer_pos open=$open_pos"
fi

printf '\n== a failed thread render refuses the launch, nothing is spent ==\n'
# Stub python3 to fail so lkml-render.py never runs, the same
# "stub the external command on PATH" pattern as fork-sandbox.sh above.
render_fail_bin="$(mktemp -d)"; tmpdirs+=("$render_fail_bin")
cat > "$render_fail_bin/python3" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$render_fail_bin/python3"
n_runs_before=$(find "$run_prefix_dir" -maxdepth 1 -name 'run.*' | wc -l)
thread_dirs_before="$(find /var/tmp/claude-scratch -maxdepth 1 -name 'lkml-revise-thread-*' 2>/dev/null | sort)"
out_render="$(PATH="$render_fail_bin:$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc_render=$?
if (( rc_render != 0 )); then
    ok "exits non-zero when the thread render fails"
else
    no "exits non-zero when the thread render fails" "exit 0: $out_render"
fi
contains "names the render failure" "$out_render" "could not render the thread bodies"
n_runs_after=$(find "$run_prefix_dir" -maxdepth 1 -name 'run.*' | wc -l)
check "no run was launched when the render fails" "$n_runs_before" "$n_runs_after"
thread_dirs_after="$(find /var/tmp/claude-scratch -maxdepth 1 -name 'lkml-revise-thread-*' 2>/dev/null | sort)"
leaked_thread_dirs="$(comm -13 <(printf '%s\n' "$thread_dirs_before") <(printf '%s\n' "$thread_dirs_after") | grep -v '^$' || true)"
if [[ -z "$leaked_thread_dirs" ]]; then
    ok "a failed render leaves no thread dir behind"
else
    no "a failed render leaves no thread dir behind" "$leaked_thread_dirs"
    printf '%s\n' "$leaked_thread_dirs" | xargs -r rm -rf --
fi

printf '\n== stop condition: commits == 0 ==\n'
write_stub 0 true 0 1
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero when commits == 0"; else no "exits non-zero when commits == 0" "exit 0"; fi
contains "names the 'changes nothing' stop condition" "$out" "changes nothing"
contains "still harvests the reply even with no commits" "$out" "harvested 1 repl"

printf '\n== stop condition: fetched != true ==\n'
write_stub 1 false 1 0
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero when fetched != true"; else no "exits non-zero when fetched != true" "exit 0"; fi
contains "names the missing fetch (fetched case)" "$out" \
    "the run committed 1 commit(s) but its branch was not fetched back"

printf '\n== refusal: commits but no cover letter ==\n'
write_stub 1 true 0 0
n_before=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero with commits but no cover letter"; else no "exits non-zero with commits but no cover letter" "exit 0"; fi
contains "refusal names the branch to read by hand" "$out" "v2-branch"
n_after=$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)
check "no new version was posted (message count unchanged)" "$n_before" "$n_after"

printf '\n== refusal: lkml-mailbox.sh init itself fails (v2 already exists) ==\n'
ledger_file="$LKML_MAILBOX_ROOT/widget-frob/versions.jsonl"
ledger_lines_before=$(wc -l < "$ledger_file" | tr -d '[:space:]')
write_stub 1 true 1 0
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero when init fails"; else no "exits non-zero when init fails" "exit 0"; fi
contains "names the mailbox init failure" "$out" "init failed"
ledger_lines_after=$(wc -l < "$ledger_file" | tr -d '[:space:]')
check "no ledger entry was appended for the failed version" "$ledger_lines_before" "$ledger_lines_after"


printf '\n== --services-trust-ref is forwarded to the launch ==\n'
write_stub 1 true 1 1
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 2 --base "$series_base_sha" \
    --services-trust-ref refs/heads/main 2>&1)"
check "exits 0 with --services-trust-ref" "0" "$?"
if grep -qx -- '--services-trust-ref' "$run_prefix_dir/last-args" \
    && grep -qx -- 'refs/heads/main' "$run_prefix_dir/last-args"; then
    ok "--services-trust-ref and its ref reach fork-sandbox.sh"
else
    no "--services-trust-ref and its ref reach fork-sandbox.sh" "$(cat "$run_prefix_dir/last-args")"
fi
printf '\n== without the flag, no trust-ref argument is forwarded ==\n'
write_stub 1 true 1 1
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 3 --base "$series_base_sha" 2>&1)"
check "exits 0 without the flag" "0" "$?"
if grep -qx -- '--services-trust-ref' "$run_prefix_dir/last-args"; then
    no "no --services-trust-ref forwarded when the flag is absent" "$(cat "$run_prefix_dir/last-args")"
else
    ok "no --services-trust-ref forwarded when the flag is absent"
fi

printf '\n== bare seat: an empty model falls back before stamping the mailbox ==\n'
# --model-override with a BARE harness drops the persona's frontmatter
# model, so the mailbox stamp must fall back to the run summary's model
# (the stub writes none) and then 'unknown' -- never an empty --model,
# which lkml-mailbox.sh refuses and which lost the harvested replies.
write_stub 1 true 1 1
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 4 --base "$series_base_sha" \
    --model-override pi-local 2>&1)"
rc=$?
check "bare override exits 0 and posts v5" "0" "$rc"
contains "bare override harvests the reply" "$out" "harvested 1 repl"
contains "bare override posts v5" "$out" "posted v5"
case "$out" in
    *"failed to post"*|*"init failed"*) no "bare override never refuses the mailbox stamp" "$out" ;;
    *) ok "bare override never refuses the mailbox stamp" ;;
esac
n_pi=0; n_pi_unknown=0; bare_reply=0
while IFS= read -r f; do
    grep -q -- 'X-AI-Harness: pi$' "$f" || continue
    n_pi=$(( n_pi + 1 ))
    grep -q -- 'X-AI-Model: unknown' "$f" && n_pi_unknown=$(( n_pi_unknown + 1 ))
    grep -q -- 'Fixed, see v2' "$f" && bare_reply=1
done < <(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg')
check "the bare seat posted the harvested reply and v5's three messages" "4" "$n_pi"
check "every bare-seat message is stamped with the fallback model" "$n_pi" "$n_pi_unknown"
check "the harvested reply landed with the bare seat" "1" "$bare_reply"

printf '\n== a pi-local author with an explicit pinned network is refused before any launch ==\n'
# The pi-local + network: pinned contradiction is refused inside
# lkml-seats-resolve (the frontmatter check runs before the seats-file
# early exit, so it fires even with no seats file). Pin it through the
# launcher itself, not just the resolver unit test, so a launcher that
# ever stops calling the resolver cannot silently launch a sealed seat.
pin_personas="$(mktemp -d)"; tmpdirs+=("$pin_personas")
cat > "$pin_personas/author.md" <<'EOF'
---
persona: author
role: author
display: The Author
harness: pi-local
network: pinned
---

# The Author (AI persona)

Body.
EOF
n_runs_before=$(find "$run_prefix_dir" -maxdepth 1 -name 'run.*' | wc -l)
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" \
    --personas-dir "$pin_personas" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "exits non-zero on pi-local with network: pinned"; else no "exits non-zero on pi-local with network: pinned" "exit 0"; fi
contains "refusal names the already-sealed alias" "$out" "already sealed"
n_runs_after=$(find "$run_prefix_dir" -maxdepth 1 -name 'run.*' | wc -l)
check "no run was launched" "$n_runs_before" "$n_runs_after"

printf '\n== the author'"'"'s harvested reply carries the REVIEWED version'"'"'s ledger upstream_head ==\n'
# A separate series: lkml-round.sh reads a version's OWN upstream_head from
# the ledger (scripts/lkml-round.sh:425) and stamps it on every harvested
# reply in that version's thread -- the author's own replies must agree,
# reading the version-under-revision's ledger row (not $upstream_head_ref
# above, which names the NEW version's head -- distinct on purpose here).
mkdir uh-patches
printf 'Subject: [PATCH 1/1] frob: uh core\n\ndiff\n' > uh-patches/0001.patch
"$mailbox" init widget-uh --cover cover.txt --patches uh-patches --from author \
    --harness claude --model opus --no-checkout >/dev/null 2>&1
uh_patch_id="$("$mailbox" tree widget-uh | awk 'NR==3{print $1}')"
reviewed_upstream_sha="$series_base_sha"
printf '{"version":1,"branch":"somebranch","upstream_head":"%s"}\n' "$reviewed_upstream_sha" \
    > "$LKML_MAILBOX_ROOT/widget-uh/versions.jsonl"
echo "please look again" > q2.txt
r_uh="$("$mailbox" post widget-uh --from core --reply-to "$uh_patch_id" --file q2.txt \
    --tags Changes-requested --harness claude --model opus 2>/dev/null)"
r1_saved="$r1"; r1="$r_uh"
write_stub 1 true 1 1
r1="$r1_saved"
out_uh="$(PATH="$stub_bin:$PATH" "$revise" widget-uh --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" \
    --upstream-head somebranch 2>&1)"
rc_uh=$?
if (( rc_uh == 0 )); then ok "uh: exits 0 and posts v2"; else no "uh: exits 0 and posts v2" "exit $rc_uh: $out_uh"; fi
uh_tree="$("$mailbox" tree widget-uh)"
uh_reply_msg="$("$mailbox" show widget-uh "$(printf '%s\n' "$uh_tree" | grep -m1 Reviewed-by | awk '{print $1}')")"
contains "the author's reply carries the REVIEWED version's ledger upstream_head" \
    "$uh_reply_msg" "X-Upstream-Head: $reviewed_upstream_sha"
case "$uh_reply_msg" in
    *"X-Upstream-Head: $somebranch_sha"*) no "the author's reply must not carry the NEW version's --upstream-head instead" ;;
    *) ok "the author's reply does not carry the NEW version's --upstream-head" ;;
esac
uh_v2_cover_id="$(printf '%s\n' "$uh_tree" | awk '/^=== v2 ===/{found=1; next} found && /^[[:alnum:]]/{print $1; exit}')"
contains "the new v2 cover still carries the NEW version's --upstream-head, not the reviewed one" \
    "$("$mailbox" show widget-uh "$uh_v2_cover_id")" "X-Upstream-Head: $somebranch_sha"

printf '\n== fixture branches, as a run would fetch them back ==\n'
# Real branches, standing in for what a run fetches back, all built on the
# series base (--base) with a real git history.
orig_branch="$(git -C "$real_repo" rev-parse --abbrev-ref HEAD)"
rgit() { git -C "$real_repo" "$@"; }
rgit checkout -q --detach "$series_base_sha"
printf 'int frob(void) { return 1; }\n' > "$real_repo/frob.c"
rgit add frob.c; rgit commit -q -m "frob: add core"
printf 'int frob(void) { return 2; }\n' > "$real_repo/frob.c"
rgit commit -q -am "fixup! frob: add core"
rgit branch -f fixup-branch HEAD

rgit checkout -q --detach "$series_base_sha"
printf 'int frob(void) { return 1; }\n' > "$real_repo/frob.c"
rgit add frob.c; rgit commit -q -m "frob: add core"
printf '/* frob returns one */\nint frob(void) { return 1; }\n' > "$real_repo/frob.c"
rgit commit -q -am "frob: document the return value"
rgit branch -f comment-branch HEAD

rgit checkout -q --detach "$series_base_sha"
printf 'int frob(void) { return 1; }\n' > "$real_repo/frob.c"
rgit add frob.c; rgit commit -q -m "frob: add core, returning one"
printf 'int main(void) { return frob() != 1; }\n' > "$real_repo/frob_test.c"
rgit add frob_test.c; rgit commit -q -m "frob: add a self-test"
rgit branch -f reroll-branch HEAD
rgit checkout -q "$orig_branch"
if rgit merge-base --is-ancestor "$somebranch_sha" reroll-branch; then
    no "fixture: reroll-branch must NOT descend from the checkout tip"
else
    ok "fixture: reroll-branch does not descend from the checkout tip"
fi
if rgit merge-base --is-ancestor "$series_base_sha" reroll-branch; then
    ok "fixture: reroll-branch descends from the boundary (the series base)"
else
    no "fixture: reroll-branch descends from the boundary (the series base)"
fi

printf '\n== the handoff names the frozen boundary and the re-roll rules ==\n'
handoff_of() { tail -n1 "$run_prefix_dir/last-args"; }
# Read from a run whose branch the gate refuses (fixup-branch, built below),
# so it posts no version of widget-uh: the inheritance case further down
# posts v3 and must find it free.
r1_saved="$r1"; r1="$r_uh"
write_stub 1 true 1 0 fixup-branch
PATH="$stub_bin:$PATH" "$revise" widget-uh --project "$real_repo" \
    --checkout somebranch --version 2 --base "$series_base_sha" \
    --upstream-head somebranch >/dev/null 2>&1
r1="$r1_saved"
h_up="$(cat -- "$(handoff_of)")"
contains "an --upstream-head names the full sha as frozen" "$h_up" \
    "Commits up to and including $somebranch_sha are frozen: never rewrite them. Everything above it is your series; re-roll it."
contains "the handoff tells the author to fold fixes into the right commit" "$h_up" "fold every fix into the commit it belongs to"
contains "the handoff names the autosquash recipe with a no-op editor" "$h_up" "GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash $somebranch_sha"
contains "the handoff forbids fixup!/squash! commits" "$h_up" "no fixup!, squash! or amend! commit"
contains "the handoff asks for a ## Testing section with counts" "$h_up" "## Testing"
contains "the handoff asks for accepted/adapted/refused per reviewer point" "$h_up" "accepted, adapted or refused"
contains "the handoff says only the author writes patches" "$h_up" "Only you write patches"
contains "the handoff leaves the Diffstat to posting" "$h_up" "Do not write a \`## Diffstat\` or a \`## Since vN\` section"
contains "the handoff mentions ## Since" "$h_up" "## Since"
case "$h_up" in
    *"commit early and often"*|*"one logical change per commit -- not one"*) no "the append-only advice is gone from the handoff" ;;
    *) ok "the append-only advice is gone from the handoff" ;;
esac

printf '\n== the frozen boundary is the series base when nothing is stacked ==\n'
# refuse_case <label> <branch> <violation-substring> [extra revise args]
# One refusal: the run is stubbed to fetch <branch>; the gate must refuse,
# the reply must still land, and nothing may be posted.
refuse_case() {
    local label="$1" branch="$2" want="$3"; shift 3
    write_stub 1 true 1 1 "$branch"
    local msgs_before msgs_after
    msgs_before="$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)"
    out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
        --checkout somebranch --version 9 --base "$series_base_sha" "$@" 2>&1)"
    rc=$?
    if (( rc != 0 )); then ok "$label: exits non-zero"; else no "$label: exits non-zero" "exit 0: $out"; fi
    contains "$label: prints the violation" "$out" "$want"
    contains "$label: says it refuses v10 and keeps the branch" "$out" \
        "refusing to post v10: the series is not a clean re-roll; branch $branch kept for inspection"
    contains "$label: the reply was still harvested" "$out" "harvested 1 repl"
    msgs_after="$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)"
    check "$label: only the harvested reply was posted (no v10)" "$(( msgs_before + 1 ))" "$msgs_after"
    case "$out" in *"posted v10"*) no "$label: v10 must not be posted" ;; *) ok "$label: v10 is not posted" ;; esac
}
refuse_case "a fixup! commit" fixup-branch "fixup! frob: add core: "
h_base="$(cat -- "$(handoff_of)")"
contains "no upstream: the handoff names the series base as the boundary" "$h_base" \
    "Everything above the series base $series_base_sha is yours; re-roll it."
refuse_case "a comment-only commit" comment-branch "frob: document the return value: changes only comments"

printf '\n== --upstream-head is the boundary, and the branch must sit on it ==\n'
refuse_case "a branch not on the --upstream-head" reroll-branch \
    "the frozen commits were rewritten or the series is not on the boundary" --upstream-head somebranch
contains "the refusal names the boundary" "$out" "Commits up to and including $somebranch_sha are frozen"

printf '\n== a boundary the checkout tip does not contain is refused before launch ==\n'
write_stub 1 true 1 1 reroll-branch
msgs_before="$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)"
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 9 --base "$series_base_sha" \
    --upstream-head reroll-branch 2>&1)"
rc=$?
if (( rc != 0 )); then ok "moved --upstream-head: exits non-zero"; else no "moved --upstream-head: exits non-zero" "exit 0: $out"; fi
contains "moved --upstream-head: says the boundary is not an ancestor of --checkout" "$out" "is not an ancestor of --checkout"
msgs_after="$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)"
check "moved --upstream-head: nothing was posted" "$msgs_before" "$msgs_after"

printf '\n== a cover letter without ## Testing is refused ==\n'
write_stub 1 true 1 1 reroll-branch 0
msgs_before="$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)"
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 9 --base "$series_base_sha" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "no ## Testing: exits non-zero"; else no "no ## Testing: exits non-zero" "exit 0: $out"; fi
contains "no ## Testing: names the missing section" "$out" "## Testing"
contains "no ## Testing: refuses v10" "$out" "refusing to post v10"
contains "no ## Testing: names the branch" "$out" "reroll-branch"
contains "no ## Testing: the reply was still harvested" "$out" "harvested 1 repl"
msgs_after="$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)"
check "no ## Testing: only the harvested reply was posted" "$(( msgs_before + 1 ))" "$msgs_after"

printf '\n== a clean re-roll, not a descendant of the checkout tip, posts ==\n'
write_stub 1 true 1 1 reroll-branch
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 9 --base "$series_base_sha" 2>&1)"
rc=$?
check "the re-rolled series exits 0" "0" "$rc"
contains "the re-rolled series posts v10" "$out" "posted v10"
tree_out="$("$mailbox" tree widget-frob)"
contains "v10 is posted as the whole re-rolled series" "$tree_out" "PATCH v10 2/2"
contains "v10 carries the re-rolled commit" "$tree_out" "frob: add core, returning one"

printf '\n== an inherited upstream_head is the boundary when --upstream-head is omitted ==\n'
# widget-uh v2 was posted above with --upstream-head somebranch; revising v2
# without the flag must inherit that head from the ledger.
r1_saved="$r1"; r1="$r_uh"
write_stub 1 true 1 1
r1="$r1_saved"
out="$(PATH="$stub_bin:$PATH" "$revise" widget-uh --project "$real_repo" \
    --checkout somebranch --version 2 --base "$series_base_sha" 2>&1)"
rc=$?
check "inherited boundary: exits 0 and posts v3" "0" "$rc"
contains "inherited boundary: the handoff names the inherited head" "$(cat -- "$(handoff_of)")" \
    "Commits up to and including $somebranch_sha are frozen"

printf '\n== pr-author with no frozen boundary is refused at launch ==\n'
pra_personas="$(mktemp -d)"
cat > "$pra_personas/pr-author.md" <<'PERSONA'
---
persona: pr-author
role: author
display: The PR Author
harness: claude
---

# The PR Author (AI persona)

Body.
PERSONA
msgs_before="$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)"
n_runs_before=$(find "$run_prefix_dir" -maxdepth 1 -name 'run.*' | wc -l)
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 9 --base "$series_base_sha" \
    --author pr-author --personas-dir "$pra_personas" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "pr-author, no upstream head: exits non-zero"; else no "pr-author, no upstream head: exits non-zero" "exit 0: $out"; fi
contains "pr-author, no upstream head: tells the operator to pass --upstream-head" "$out" "Pass --upstream-head <pr-head>"
n_runs_after=$(find "$run_prefix_dir" -maxdepth 1 -name 'run.*' | wc -l)
check "pr-author, no upstream head: no run was launched" "$n_runs_before" "$n_runs_after"
msgs_after="$(find "$LKML_MAILBOX_ROOT/widget-frob/cur" -name '*.msg' | wc -l)"
check "pr-author, no upstream head: nothing was posted" "$msgs_before" "$msgs_after"
out="$(PATH="$stub_bin:$PATH" "$revise" widget-frob --project "$real_repo" \
    --checkout somebranch --version 9 --base "$series_base_sha" \
    --author pr-author --personas-dir "$pra_personas" \
    --upstream-head somebranch 2>&1)"
case "$out" in
    *"needs a frozen boundary"*) no "pr-author with --upstream-head is not refused for a missing boundary" "$out" ;;
    *) ok "pr-author with --upstream-head is not refused for a missing boundary" ;;
esac
rm -rf -- "$pra_personas"

printf '\n== --previous-tip: the ledger sha is used, not --checkout or the new tip ==\n'
# A distinct branch standing in for what v1 was ACTUALLY posted from --
# different from both "somebranch" (this round's --checkout) and
# "v2-branch" (what gets fetched back as v2), so a test that used either
# of those instead of the ledger sha would be caught.
git -C "$real_repo" checkout -b v1-posted-branch "$series_base_sha" -q
printf 'this is what v1 was actually posted from\n' > "$real_repo/posted-marker.txt"
git -C "$real_repo" add posted-marker.txt
git -C "$real_repo" commit -q -m "repo: v1 posted-branch marker"
v1_posted_sha="$(git -C "$real_repo" rev-parse --verify --quiet HEAD)"
git -C "$real_repo" checkout - -q

(cd "$real_repo" && "$mailbox" init widget-ledger-sha --cover "$work/cover.txt" --patches "$work/patches" \
    --from author --harness claude --model opus --checkout v1-posted-branch >/dev/null 2>&1)

write_stub 1 true 1 0
out_ledger="$(PATH="$stub_bin:$PATH" "$revise" widget-ledger-sha --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc_ledger=$?
check "ledger-sha run posts v2" "0" "$rc_ledger"
case "$out_ledger" in
    *"no ledger sha for v1"*) no "a recorded ledger sha does not warn" "$out_ledger" ;;
    *) ok "a recorded ledger sha does not warn" ;;
esac

ledger_tree_out="$("$mailbox" tree widget-ledger-sha)"
ledger_v2_cover_id="$(printf '%s\n' "$ledger_tree_out" | awk '/^=== v2 ===/{found=1; next} found && /^[[:alnum:]]/{print $1; exit}')"
ledger_v2_cover_msg="$("$mailbox" show widget-ledger-sha "$ledger_v2_cover_id")"
contains "the Since section is keyed on the ledger's v1 sha" "$ledger_v2_cover_msg" "v1  $v1_posted_sha  tree"
case "$ledger_v2_cover_msg" in
    *"$somebranch_sha"*) no "the Since section does not use --checkout's sha instead of the ledger" "$ledger_v2_cover_msg" ;;
    *) ok "the Since section does not use --checkout's sha instead of the ledger" ;;
esac

printf '\n== --previous-tip: an unresolvable ledger sha warns and omits the flag ==\n'
(cd "$real_repo" && "$mailbox" init widget-bad-ledger-sha --cover "$work/cover.txt" --patches "$work/patches" \
    --from author --harness claude --model opus --no-checkout >/dev/null 2>&1)
printf '{"version":1,"branch":"nosuchbranch","sha":"%s"}\n' "$(printf 'e%.0s' {1..40})" \
    > "$LKML_MAILBOX_ROOT/widget-bad-ledger-sha/versions.jsonl"

write_stub 1 true 1 0
out_badledger="$(PATH="$stub_bin:$PATH" "$revise" widget-bad-ledger-sha --project "$real_repo" \
    --checkout somebranch --version 1 --base "$series_base_sha" 2>&1)"
rc_badledger=$?
check "an unresolvable ledger sha still posts v2" "0" "$rc_badledger"
contains "an unresolvable ledger sha warns and omits the flag" "$out_badledger" \
    "ledger sha $(printf 'e%.0s' {1..40}) for v1 does not resolve in $real_repo; the v2 cover will carry no \"## Since\" section."
badledger_tree_out="$("$mailbox" tree widget-bad-ledger-sha)"
badledger_v2_cover_id="$(printf '%s\n' "$badledger_tree_out" | awk '/^=== v2 ===/{found=1; next} found && /^[[:alnum:]]/{print $1; exit}')"
badledger_v2_cover_msg="$("$mailbox" show widget-bad-ledger-sha "$badledger_v2_cover_id")"
case "$badledger_v2_cover_msg" in
    *"## Since"*) no "an unresolvable ledger sha: the new cover carries no ## Since section" "$badledger_v2_cover_msg" ;;
    *) ok "an unresolvable ledger sha: the new cover carries no ## Since section" ;;
esac

printf '\n== resumed author round: --checkout already carries unposted work above vN posted tip ==\n'
# The operator relaunches a dead attempt with --checkout pointed at that
# attempt's fetched branch and --version unchanged; the run itself commits
# nothing (the commits already sit on --checkout). Each scenario gets its
# own series so a ledger row from one cannot leak into another.
resume_setup_series() {
    local series="$1"; shift
    (cd "$real_repo" && "$mailbox" init "$series" --cover "$work/cover.txt" --patches "$work/patches" \
        --from author --harness claude --model opus "$@" >/dev/null 2>&1)
}
resume_reply_target() {
    local series="$1" pid qfile id
    pid="$("$mailbox" tree "$series" | awk 'NR==3{print $1}')"
    qfile="$(mktemp)"
    echo "please address this in the resumed round" > "$qfile"
    id="$("$mailbox" post "$series" --from core --reply-to "$pid" --file "$qfile" \
        --tags Changes-requested --harness claude --model opus 2>/dev/null)"
    rm -f "$qfile"
    printf '%s' "$id"
}

# Branch A stands in for what v1 was actually posted from; branch B is one
# extra commit on top of A, standing in for the dead attempt's fetched
# branch that --checkout is pointed at on the resumed relaunch.
git -C "$real_repo" checkout -q --detach "$series_base_sha"
printf 'resume A commit\n' > "$real_repo/resume-a.txt"
git -C "$real_repo" add resume-a.txt
git -C "$real_repo" commit -q -m "resume: branch A commit"
git -C "$real_repo" branch -f resume-a HEAD
resume_a_sha="$(git -C "$real_repo" rev-parse --verify --quiet resume-a)"
printf 'resume B extra commit\n' > "$real_repo/resume-b.txt"
git -C "$real_repo" add resume-b.txt
git -C "$real_repo" commit -q -m "resume: branch B extra commit"
git -C "$real_repo" branch -f resume-b HEAD
resume_b_sha="$(git -C "$real_repo" rev-parse --verify --quiet resume-b)"
git -C "$real_repo" checkout - -q

printf '\n-- resume: posts from the checkout --\n'
resume_setup_series widget-resume-ok --checkout resume-a
r_resume_ok="$(resume_reply_target widget-resume-ok)"
r1_saved="$r1"; r1="$r_resume_ok"
write_stub 0 false 1 1
r1="$r1_saved"
out_resume="$(PATH="$stub_bin:$PATH" "$revise" widget-resume-ok --project "$real_repo" \
    --checkout resume-b --version 1 --base "$series_base_sha" 2>&1)"
rc_resume=$?
check "resume: exits 0 and posts v2" "0" "$rc_resume"
contains "resume: reports harvesting the reply" "$out_resume" "harvested 1 repl"
contains "resume: posts v2" "$out_resume" "posted v2"
contains "resume: explains the resumed round is posting the checkout" "$out_resume" \
    "the run made no commits of its own, but --checkout resume-b (${resume_b_sha:0:7}) carries unposted work above v1's posted tip ${resume_a_sha:0:7}; posting it as v2."
resume_tree="$("$mailbox" tree widget-resume-ok)"
contains "resume: v2 shows up in the tree" "$resume_tree" "=== v2 ==="
resume_ledger="$LKML_MAILBOX_ROOT/widget-resume-ok/versions.jsonl"
resume_v2_row="$(grep '"version":2' "$resume_ledger")"
contains "resume: v2 recorded in the ledger with B's sha, not A's" "$resume_v2_row" "\"sha\":\"$resume_b_sha\""
case "$resume_v2_row" in
    *"$resume_a_sha"*) no "resume: v2's ledger sha is not A's sha" "$resume_v2_row" ;;
    *) ok "resume: v2's ledger sha is not A's sha" ;;
esac
resume_handoff_text="$(cat -- "$run_prefix_dir/last-handoff.md")"
resume_commit_count="$(git -C "$real_repo" rev-list --count "$resume_a_sha..$resume_b_sha")"
contains "resume handoff names all unposted commits" "$resume_handoff_text" \
    "carries $resume_commit_count unposted commit(s) above"
contains "resume handoff names both short endpoints" "$resume_handoff_text" \
    "${resume_a_sha:0:7}, through ${resume_b_sha:0:7}"
contains "resume handoff requires a cover for the whole unposted work" "$resume_handoff_text" \
    "must write its cover letter covering the whole unposted work"
case "$resume_handoff_text" in
    *"do not fabricate a cover letter for a"*) no "resume handoff replaces the no-commit, no-cover instruction" ;;
    *) ok "resume handoff replaces the no-commit, no-cover instruction" ;;
esac

printf '\n-- resume: an unchanged checkout still stops --\n'
resume_setup_series widget-resume-unchanged --checkout resume-a
r_resume_unchanged="$(resume_reply_target widget-resume-unchanged)"
r1_saved="$r1"; r1="$r_resume_unchanged"
write_stub 0 false 1 1
r1="$r1_saved"
out_unchanged="$(PATH="$stub_bin:$PATH" "$revise" widget-resume-unchanged --project "$real_repo" \
    --checkout resume-a --version 1 --base "$series_base_sha" 2>&1)"
rc_unchanged=$?
if (( rc_unchanged != 0 )); then ok "resume unchanged: exits non-zero"; else no "resume unchanged: exits non-zero" "exit 0: $out_unchanged"; fi
contains "resume unchanged: the existing 'made no commits' text stands" "$out_unchanged" \
    "the author made no commits this round --"
contains "resume unchanged: names the 'changes nothing' stop condition" "$out_unchanged" "changes nothing"
unchanged_tree="$("$mailbox" tree widget-resume-unchanged)"
case "$unchanged_tree" in
    *"=== v2 ==="*) no "resume unchanged: no v2 in the tree" "$unchanged_tree" ;;
    *) ok "resume unchanged: no v2 in the tree" ;;
esac

printf '\n-- resume: no ledger sha still stops --\n'
resume_setup_series widget-resume-noledger --no-checkout
r_resume_noledger="$(resume_reply_target widget-resume-noledger)"
r1_saved="$r1"; r1="$r_resume_noledger"
write_stub 0 false 1 1
r1="$r1_saved"
out_noledger="$(PATH="$stub_bin:$PATH" "$revise" widget-resume-noledger --project "$real_repo" \
    --checkout resume-b --version 1 --base "$series_base_sha" 2>&1)"
rc_noledger=$?
if (( rc_noledger != 0 )); then ok "resume no ledger: exits non-zero"; else no "resume no ledger: exits non-zero" "exit 0: $out_noledger"; fi
contains "resume no ledger: names the 'changes nothing' stop condition" "$out_noledger" "changes nothing"
contains "resume no ledger: explains the resume check could not run" "$out_noledger" \
    "no ledger sha for v1, so the resume"

printf '\n-- resume: no cover letter is refused, naming the checkout branch --\n'
resume_setup_series widget-resume-nocover --checkout resume-a
r_resume_nocover="$(resume_reply_target widget-resume-nocover)"
r1_saved="$r1"; r1="$r_resume_nocover"
write_stub 0 false 0 1
r1="$r1_saved"
msgs_before_nocover="$(find "$LKML_MAILBOX_ROOT/widget-resume-nocover/cur" -name '*.msg' | wc -l)"
out_nocover="$(PATH="$stub_bin:$PATH" "$revise" widget-resume-nocover --project "$real_repo" \
    --checkout resume-b --version 1 --base "$series_base_sha" 2>&1)"
rc_nocover=$?
if (( rc_nocover != 0 )); then ok "resume no cover: exits non-zero"; else no "resume no cover: exits non-zero" "exit 0: $out_nocover"; fi
contains "resume no cover: names branch B (the checkout)" "$out_nocover" "resume-b"
contains "resume no cover: the reply is still harvested" "$out_nocover" "harvested 1 repl"
msgs_after_nocover="$(find "$LKML_MAILBOX_ROOT/widget-resume-nocover/cur" -name '*.msg' | wc -l)"
check "resume no cover: only the harvested reply was posted (no v2)" "$(( msgs_before_nocover + 1 ))" "$msgs_after_nocover"

printf '\n-- resume: committed work not fetched back is refused after harvesting --\n'
resume_setup_series widget-resume-unfetched --checkout resume-a
r_resume_unfetched="$(resume_reply_target widget-resume-unfetched)"
r1_saved="$r1"; r1="$r_resume_unfetched"
write_stub 1 false 1 1
r1="$r1_saved"
msgs_before_unfetched="$(find "$LKML_MAILBOX_ROOT/widget-resume-unfetched/cur" -name '*.msg' | wc -l)"
out_unfetched="$(PATH="$stub_bin:$PATH" "$revise" widget-resume-unfetched --project "$real_repo" \
    --checkout resume-b --version 1 --base "$series_base_sha" 2>&1)"
rc_unfetched=$?
if (( rc_unfetched != 0 )); then ok "resume unfetched: exits non-zero"; else no "resume unfetched: exits non-zero" "exit 0: $out_unfetched"; fi
contains "resume unfetched: names the missing fetch" "$out_unfetched" \
    "the run committed 1 commit(s) but its branch was not fetched back"
contains "resume unfetched: names the run directory" "$out_unfetched" "Run directory:"
unfetched_tree="$("$mailbox" tree widget-resume-unfetched)"
case "$unfetched_tree" in
    *"=== v2 ==="*) no "resume unfetched: no v2 in the tree" "$unfetched_tree" ;;
    *) ok "resume unfetched: no v2 in the tree" ;;
esac
msgs_after_unfetched="$(find "$LKML_MAILBOX_ROOT/widget-resume-unfetched/cur" -name '*.msg' | wc -l)"
check "resume unfetched: the reply is still harvested" "$(( msgs_before_unfetched + 1 ))" "$msgs_after_unfetched"

printf '\n-- resume: a checkout branch moved during the run is refused --\n'
resume_setup_series widget-resume-moved --checkout resume-a
write_stub 0 false 1 0 v2-branch 1 resume-b
out_resume_moved="$(PATH="$stub_bin:$PATH" "$revise" widget-resume-moved --project "$real_repo" \
    --checkout resume-b --version 1 --base "$series_base_sha" 2>&1)"
rc_resume_moved=$?
if (( rc_resume_moved != 0 )); then ok "resume moved: exits non-zero"; else no "resume moved: exits non-zero" "exit 0: $out_resume_moved"; fi
contains "resume moved: names the old checkout sha" "$out_resume_moved" "$resume_b_sha"
contains "resume moved: names the new checkout sha" "$out_resume_moved" "$series_base_sha"
moved_tree="$("$mailbox" tree widget-resume-moved)"
case "$moved_tree" in
    *"=== v2 ==="*) no "resume moved: no v2 in the tree" "$moved_tree" ;;
    *) ok "resume moved: no v2 in the tree" ;;
esac
git -C "$real_repo" branch -f resume-b "$resume_b_sha"

printf '\n-- resume: a tag checkout is refused before launch --\n'
resume_setup_series widget-resume-tag --checkout resume-a
git -C "$real_repo" tag -f resume-b-tag resume-b
write_stub 0 false 1 1
rm -f -- "$run_prefix_dir/last-args"
out_resume_tag="$(PATH="$stub_bin:$PATH" "$revise" widget-resume-tag --project "$real_repo" \
    --checkout resume-b-tag --version 1 --base "$series_base_sha" 2>&1)"
rc_resume_tag=$?
if (( rc_resume_tag != 0 )); then ok "resume tag: exits non-zero"; else no "resume tag: exits non-zero" "exit 0: $out_resume_tag"; fi
contains "resume tag: names the ref and local-branch requirement" "$out_resume_tag" \
    "resumed checkout 'resume-b-tag' must be launched from a local branch"
if [[ ! -e "$run_prefix_dir/last-args" ]]; then ok "resume tag: stub was not invoked"; else no "resume tag: stub was not invoked" "$(cat "$run_prefix_dir/last-args")"; fi

printf '\n-- resume: a checkout behind the posted tip is not posted as resumed work --\n'
resume_setup_series widget-resume-behind --checkout resume-b
write_stub 0 false 1 1
out_resume_behind="$(PATH="$stub_bin:$PATH" "$revise" widget-resume-behind --project "$real_repo" \
    --checkout resume-a --version 1 --base "$series_base_sha" 2>&1)"
rc_resume_behind=$?
if (( rc_resume_behind != 0 )); then ok "resume behind: exits non-zero"; else no "resume behind: exits non-zero" "exit 0: $out_resume_behind"; fi
contains "resume behind: names the posted tip" "$out_resume_behind" "$resume_b_sha"
contains "resume behind: names the checkout tip" "$out_resume_behind" "$resume_a_sha"
contains "resume behind: explains that posted work must be retained" "$out_resume_behind" \
    "a resumed checkout must retain all posted work"
contains "resume behind: reply is still harvested" "$out_resume_behind" "harvested 1 repl"
behind_tree="$("$mailbox" tree widget-resume-behind)"
case "$behind_tree" in
    *"=== v2 ==="*) no "resume behind: no v2 is posted" "$behind_tree" ;;
    *) ok "resume behind: no v2 is posted" ;;
esac

printf '\n== --frozen-fixups: fixtures, a stack with a slice under review ==\n'
# A four-commit stack on the series base; the frozen head is its tip and the
# slice under review is the two commits above ff-lo (ff-s2, ff-s3). The
# author's branches sit on the frozen head.
rgit checkout -q --detach "$series_base_sha"
for n in 1 2 3 4; do
    printf 'stack %s\n' "$n" > "$real_repo/stack$n.txt"
    rgit add "stack$n.txt"; rgit commit -q -m "stack: commit $n"
    rgit tag -f "ff-s$n" HEAD >/dev/null
done
rgit branch -f ff-head HEAD
ff_lo_sha="$(rgit rev-parse ff-s1)"; ff_hi_sha="$(rgit rev-parse ff-s3)"; ff_head_sha="$(rgit rev-parse ff-head)"
printf 'own\n' > "$real_repo/own.txt"; rgit add own.txt; rgit commit -q -m "own: add a thing"
printf 'fix 3\n' > "$real_repo/stack3.txt"; rgit commit -q -am "fixup! stack: commit 3"
printf '/* note */\n' >> "$real_repo/stack2.txt"; rgit commit -q -am "fixup! stack: commit 2"
rgit branch -f ff-good HEAD
rgit checkout -q --detach ff-head
printf 'own\n' > "$real_repo/own.txt"; rgit add own.txt; rgit commit -q -m "own: add a thing"
printf 'fix 1\n' > "$real_repo/stack1.txt"; rgit commit -q -am "fixup! stack: commit 1"
rgit branch -f ff-bad HEAD
rgit checkout -q "$orig_branch"
ff_range="ff-s1..ff-s3"

printf 'Add the stack\n\nBody.\n' > ff-cover.txt
mkdir -p ff-patches
printf 'Subject: [PATCH 1/1] stack: commit 4\n\ndiff\n' > ff-patches/0001.patch
"$mailbox" init widget-ff --cover ff-cover.txt --patches ff-patches --from author \
    --harness claude --model opus --no-checkout >/dev/null 2>&1

ff_launches() { find "$run_prefix_dir" -maxdepth 1 -name 'run.*' | wc -l; }
ff_msgs() { find "$LKML_MAILBOX_ROOT/widget-ff/cur" -name '*.msg' | wc -l; }
ff_refused() {
    local label="$1" want="$2"; shift 2
    local launches_before msgs_before
    write_stub 1 true 1 0 ff-good
    launches_before="$(ff_launches)"; msgs_before="$(ff_msgs)"
    out="$(PATH="$stub_bin:$PATH" "$revise" widget-ff --project "$real_repo" \
        --checkout ff-head --version 1 --base "$series_base_sha" "$@" 2>&1)"
    rc=$?
    if (( rc != 0 )); then ok "$label: exits non-zero"; else no "$label: exits non-zero" "exit 0: $out"; fi
    contains "$label: says why" "$out" "$want"
    check "$label: no run was launched" "$launches_before" "$(ff_launches)"
    check "$label: nothing was posted" "$msgs_before" "$(ff_msgs)"
}

printf '\n== --frozen-fixups is refused at launch when it cannot apply ==\n'
ff_refused "no upstream boundary" "--frozen-fixups needs a frozen boundary" --frozen-fixups "$ff_range"
ff_refused "lo is not an ancestor of hi" "is not an ancestor of" \
    --upstream-head ff-head --frozen-fixups ff-s3..ff-s1
ff_refused "hi is above the boundary" "is not at or below the frozen boundary" \
    --upstream-head ff-s3 --frozen-fixups ff-s1..ff-head
ff_refused "an unresolvable lo" "'nosuchlo' does not name a commit" \
    --upstream-head ff-head --frozen-fixups nosuchlo..ff-s3
ff_refused "an unresolvable hi" "'nosuchhi' does not name a commit" \
    --upstream-head ff-head --frozen-fixups ff-s1..nosuchhi
ff_refused "a malformed range" "is not of the form <lo>..<hi>" \
    --upstream-head ff-head --frozen-fixups ff-s3

printf '\n== --frozen-fixups: the gate gets --allow-fixups-for, and the handoff explains the slice ==\n'
# The gate is found next to the script, so run a copy of the scripts whose
# lkml-series-check.sh logs its arguments and hands over to the real one.
ff_copy="$(mktemp -d)"; tmpdirs+=("$ff_copy")
cp -r "$repo_dir/scripts" "$repo_dir/skills" "$ff_copy/"
mv "$ff_copy/scripts/lkml-series-check.sh" "$ff_copy/scripts/lkml-series-check-real.sh"
cp "$repo_dir/scripts/lkml-series-check-py.py" "$ff_copy/scripts/"
cat > "$ff_copy/scripts/lkml-series-check.sh" <<GATE
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ff_copy/gate-args"
exec "$ff_copy/scripts/lkml-series-check-real.sh" "\$@"
GATE
chmod +x "$ff_copy/scripts/lkml-series-check.sh"

write_stub 1 true 1 0 ff-good
out="$(PATH="$stub_bin:$PATH" "$ff_copy/scripts/lkml-revise.sh" widget-ff --project "$real_repo" \
    --checkout ff-head --version 1 --base "$series_base_sha" \
    --upstream-head ff-head --frozen-fixups "$ff_range" 2>&1)"
rc=$?
check "slice fixups plus an own commit: exits 0 and posts v2" "0" "$rc"
contains "slice fixups plus an own commit: posted v2" "$out" "posted v2"
check "the gate got --allow-fixups-for with full shas" \
    "--allow-fixups-for $ff_lo_sha..$ff_hi_sha" \
    "$(grep -A1 -x -- '--allow-fixups-for' "$ff_copy/gate-args" | paste -sd' ')"
check "the gate's boundary is the frozen head" "$ff_head_sha" \
    "$(awk '$0=="--boundary"{getline; print; exit}' "$ff_copy/gate-args")"
h_ff="$(cat -- "$(handoff_of)")"
contains "the handoff names the slice by both full shas" "$h_ff" "The commits $ff_lo_sha..$ff_hi_sha"
contains "the handoff says to make a slice fix as a fixup and leave it unfolded" "$h_ff" \
    "\`git commit --fixup=<sha>\`"
contains "the handoff names the amend form" "$h_ff" "\`git commit --fixup=amend:<sha>\`"
contains "the handoff says the fixup is deliberately left unfolded" "$h_ff" "deliberately LEFT unfolded"
contains "the handoff says a fix to any other frozen commit is answered on-thread" "$h_ff" \
    "A fix to any OTHER"
contains "the handoff allows only fixups aimed at the slice" "$h_ff" \
    "the ONLY
  such commits allowed are the ones aimed at $ff_lo_sha..$ff_hi_sha"
case "$h_ff" in
    *"and no fixup!, squash! or amend! commit."*) no "the flat no-fixup rule is replaced when the flag is set" ;;
    *) ok "the flat no-fixup rule is replaced when the flag is set" ;;
esac
contains "the handoff still gives the autosquash recipe from the boundary" "$h_ff" \
    "GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash $ff_head_sha"
contains "the handoff says that recipe leaves the slice fixups in place" "$h_ff" \
    "leaves the fixups aimed at the slice"

ff_tree="$("$mailbox" tree widget-ff)"
contains "v2 is only the commits above the boundary (three patches)" "$ff_tree" "PATCH v2 3/3"
case "$ff_tree" in
    *"PATCH v2 4/4"*|*"stack: commit 1"*) no "v2 carries none of the frozen stack's commits" "$ff_tree" ;;
    *) ok "v2 carries none of the frozen stack's commits" ;;
esac
ff_v2_cover_id="$(printf '%s\n' "$ff_tree" | awk '/^=== v2 ===/{found=1; next} found && /^[[:alnum:]]/{print $1; exit}')"
ff_v2_cover="$("$mailbox" show widget-ff "$ff_v2_cover_id")"
contains "v2's base is the frozen boundary" "$ff_v2_cover" "X-Base: $ff_head_sha"
contains "v2's diffstat covers the author's commits" "$ff_v2_cover" "own.txt"

printf '\n== --frozen-fixups: the gate still refuses a fixup aimed outside the slice ==\n'
write_stub 1 true 1 0 ff-bad
msgs_before="$(ff_msgs)"
out="$(PATH="$stub_bin:$PATH" "$revise" widget-ff --project "$real_repo" \
    --checkout ff-head --version 2 --base "$series_base_sha" \
    --upstream-head ff-head --frozen-fixups "$ff_range" 2>&1)"
rc=$?
if (( rc != 0 )); then ok "fixup at a frozen commit below the slice: exits non-zero"; else no "fixup at a frozen commit below the slice: exits non-zero" "exit 0: $out"; fi
contains "fixup at a frozen commit below the slice: the target is named as outside the range" "$out" \
    "fixup! stack: commit 1: fixup target is not a commit in $ff_lo_sha..$ff_hi_sha"
check "fixup at a frozen commit below the slice: nothing posted" "$msgs_before" "$(ff_msgs)"

printf '\n== without --frozen-fixups the handoff and the gate are unchanged ==\n'
write_stub 1 true 1 0 ff-good
msgs_before="$(ff_msgs)"
out="$(PATH="$stub_bin:$PATH" "$ff_copy/scripts/lkml-revise.sh" widget-ff --project "$real_repo" \
    --checkout ff-head --version 2 --base "$series_base_sha" \
    --upstream-head ff-head 2>&1)"
rc=$?
if (( rc != 0 )); then ok "no flag: a slice fixup is refused by the gate"; else no "no flag: a slice fixup is refused by the gate" "exit 0: $out"; fi
check "no flag: the gate got no --allow-fixups-for" "0" "$(grep -c -x -- '--allow-fixups-for' "$ff_copy/gate-args")"
check "no flag: nothing posted" "$msgs_before" "$(ff_msgs)"
h_noff="$(cat -- "$(handoff_of)")"
contains "no flag: the flat no-fixup rule stands" "$h_noff" \
    "the change and not the review, and no fixup!, squash! or amend! commit.
  A commit that changes only comments"
case "$h_noff" in
    *"slice under review"*|*"LEFT unfolded"*|*"aimed at the slice"*) no "no flag: the handoff carries no slice wording" ;;
    *) ok "no flag: the handoff carries no slice wording" ;;
esac
contains "no flag: the frozen commits are still just frozen" "$h_noff" \
    "Commits up to and including $ff_head_sha are frozen: never rewrite them. Everything above it is your series; re-roll it."

printf '\n== --help ==\n'
h_out="$("$revise" --help 2>&1)"; h_rc=$?
if (( h_rc == 0 )); then ok "--help alone exits 0"; else no "--help alone exits 0" "exit $h_rc: $h_out"; fi
contains "--help prints the header usage" "$h_out" "lkml-revise.sh — Launch the author persona to answer review and produce"
h2_out="$("$revise" -h 2>&1)"; h2_rc=$?
if (( h2_rc == 0 )); then ok "-h alone exits 0"; else no "-h alone exits 0" "exit $h2_rc: $h2_out"; fi
contains "-h prints the header usage" "$h2_out" "lkml-revise.sh — Launch the author persona to answer review and produce"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
