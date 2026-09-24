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
#   - fetched != true: same stop condition, the other way it can trip.
#   - commits > 0 but no cover-letter.md: refuses to post, names the
#     branch to read by hand, exits non-zero.
#   - lkml-mailbox.sh init itself fails (e.g. the version it would post
#     already exists): exits non-zero and does NOT append to the
#     version-to-branch ledger lkml-forklift.sh reads -- a failed init must
#     not leave a ledger entry for a version with no cover letter.

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
    cat > "$stub_bin/fork-sandbox.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
run_dir="\$(mktemp -d "$run_prefix_dir/run.XXXXXX")"
printf '%s\n' "\$@" > "$run_prefix_dir/last-args"
clone_dir="\$run_dir/clone/proj"
mkdir -p "\$clone_dir/.git/lkml-out"
STUB
    if [[ "$write_cover" == 1 ]]; then
        cat >> "$stub_bin/fork-sandbox.sh" <<STUB
printf 'Add the return-value fix\n\nv2: fixed frob per core.\n' > "\$clone_dir/.git/lkml-out/cover-letter.md"
STUB
    fi
    if [[ "$write_reply" == 1 ]]; then
        cat >> "$stub_bin/fork-sandbox.sh" <<STUB
printf 'In-Reply-To: $r1\nX-Tags: Reviewed-by\n\nFixed, see v2.\n' > "\$clone_dir/.git/lkml-out/1.msg"
STUB
    fi
    cat >> "$stub_bin/fork-sandbox.sh" <<STUB
jq -n --arg clone_dir "\$clone_dir" --arg branch "v2-branch" \\
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

tree_out="$("$mailbox" tree widget-frob)"
contains "v2 shows up in the tree" "$tree_out" "=== v2 ==="
contains "v2's patch carries the real repo's commit message" "$tree_out" "frob: fix return value"
contains "v2 is posted as the whole series (v1's commit plus this round's fixup), not just the fixup alone" \
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
contains "names the 'changes nothing' stop condition (fetched case)" "$out" "changes nothing"

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
    --upstream-head v2-branch 2>&1)"
rc_uh=$?
if (( rc_uh == 0 )); then ok "uh: exits 0 and posts v2"; else no "uh: exits 0 and posts v2" "exit $rc_uh: $out_uh"; fi
uh_tree="$("$mailbox" tree widget-uh)"
uh_reply_msg="$("$mailbox" show widget-uh "$(printf '%s\n' "$uh_tree" | grep -m1 Reviewed-by | awk '{print $1}')")"
contains "the author's reply carries the REVIEWED version's ledger upstream_head" \
    "$uh_reply_msg" "X-Upstream-Head: $reviewed_upstream_sha"
case "$uh_reply_msg" in
    *"X-Upstream-Head: $v2_branch_sha"*) no "the author's reply must not carry the NEW version's --upstream-head instead" ;;
    *) ok "the author's reply does not carry the NEW version's --upstream-head" ;;
esac
uh_v2_cover_id="$(printf '%s\n' "$uh_tree" | awk '/^=== v2 ===/{found=1; next} found && /^[[:alnum:]]/{print $1; exit}')"
contains "the new v2 cover still carries the NEW version's --upstream-head, not the reviewed one" \
    "$("$mailbox" show widget-uh "$uh_v2_cover_id")" "X-Upstream-Head: $v2_branch_sha"

printf '\n== --help ==\n'
h_out="$("$revise" --help 2>&1)"; h_rc=$?
if (( h_rc == 0 )); then ok "--help alone exits 0"; else no "--help alone exits 0" "exit $h_rc: $h_out"; fi
contains "--help prints the header usage" "$h_out" "lkml-revise.sh — Launch the author persona to answer review and produce"
h2_out="$("$revise" -h 2>&1)"; h2_rc=$?
if (( h2_rc == 0 )); then ok "-h alone exits 0"; else no "-h alone exits 0" "exit $h2_rc: $h2_out"; fi
contains "-h prints the header usage" "$h2_out" "lkml-revise.sh — Launch the author persona to answer review and produce"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
