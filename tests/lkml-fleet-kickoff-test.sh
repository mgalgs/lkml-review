#!/usr/bin/env bash
# lkml-fleet-kickoff-test.sh — Exercise lkml-fleet-kickoff.sh's format,
# compose, and send paths against a fixture git repo and a stub
# `fork-sandbox` on PATH, the same "stub the external command on PATH"
# pattern tests/lkml-round-test.sh uses for fork-sandbox.sh. No real mail
# store is ever touched: FORK_SANDBOX_MAIL_ROOT is pinned at a fixture
# dir for the --send case even though this script never calls
# `fork-sandbox` itself except through the stub.
#
# Usage: tests/lkml-fleet-kickoff-test.sh

set -uo pipefail

# Keep the fixture repo independent of the operator's global and system
# git config, the same guard tests/lkml-round-test.sh applies.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
kickoff="$repo_dir/scripts/lkml-fleet-kickoff.sh"

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

printf '\n== fill(): literal ${PLACEHOLDER} substitution, in isolation ==\n'
# lkml-fleet-kickoff.sh's own fill() function, copied verbatim, sanity
# checked before trusting the rest of the suite against it -- a
# mis-escaped pattern here would make every downstream assertion below
# meaningless rather than failing loudly.
fill() {
    local -n content_ref="$1"
    content_ref="${content_ref//\$\{$2\}/$3}"
}
sample='a${X}b and ${X} again, plus ${Y}'
fill sample X hello
fill sample Y world
check "fill() replaces every occurrence of a placeholder" \
    "ahellob and hello again, plus world" "$sample"

work="$(mktemp -d)"; tmpdirs+=("$work")
project_dir="$work/project"; mkdir -p -- "$project_dir"
git -C "$project_dir" init -q
git -C "$project_dir" config user.email t@fork-sandbox.invalid
git -C "$project_dir" config user.name Tester
printf 'one\n' > "$project_dir/file"
git -C "$project_dir" add file
git -C "$project_dir" commit -qm base
git -C "$project_dir" checkout -qb topic
printf 'one\ntwo\n' > "$project_dir/file"
git -C "$project_dir" add file
git -C "$project_dir" commit -qm "second commit"
printf 'one\ntwo\nthree\n' > "$project_dir/file"
git -C "$project_dir" add file
git -C "$project_dir" commit -qm "third commit"

stub_bin="$(mktemp -d)"; tmpdirs+=("$stub_bin")
mail_root="$(mktemp -d)"; tmpdirs+=("$mail_root")
capture_dir="$(mktemp -d)"; tmpdirs+=("$capture_dir")

# The stub replaces `fork-sandbox` entirely: no mail store, no network.
# It records its own argv for the test to inspect.
cat > "$stub_bin/fork-sandbox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$STUB_CAPTURE_DIR/argv"
echo "stub fork-sandbox: sent"
STUB
chmod +x "$stub_bin/fork-sandbox"

printf '\n== print-only mode, branch-name variant ==\n'
out="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH v1 0/2] a series' \
    --summary 'does a thing' 2>&1)"
rc=$?
check "print-only mode exits 0" "0" "$rc"
contains "printed command names fork-sandbox mail send" "$out" "fork-sandbox mail send"
contains "printed command carries --from" "$out" "--from @author"
contains "printed command carries --to" "$out" "--to @lkml-panel"
contains "printed command carries the subject" "$out" "PATCH\\ v1\\ 0/2"
contains "printed command points --body at a tempfile" "$out" "--body /tmp/"
case "$out" in
    *"--attach"*) no "print-only, no --attach, carries no --attach flag" "$out" ;;
    *) ok "print-only, no --attach, carries no --attach flag" ;;
esac
if [[ -f "$capture_dir/argv" ]]; then
    no "print-only mode does not run the real fork-sandbox stub" "argv capture file exists: $(cat "$capture_dir/argv")"
else
    ok "print-only mode does not run the real fork-sandbox stub"
fi

body_file="$(printf '%s' "$out" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
if [[ -f "$body_file" ]]; then
    ok "print-only mode's body file is left in place for the printed command to use"
    body_text="$(cat "$body_file")"
    contains "body has the filled subject" "$body_text" "Subject: [PATCH v1 0/2] a series"
    contains "body has the filled summary" "$body_text" "does a thing"
    contains "body has the base" "$body_text" "Base: master"
    contains "body has the branch" "$body_text" "Branch: topic"
    contains "body has the patch count" "$body_text" "Patches: 2"
    case "$body_text" in
        *'${'*) no "body has no leftover unfilled placeholders" "$body_text" ;;
        *) ok "body has no leftover unfilled placeholders" ;;
    esac
    case "$body_text" in
        *'<!--'*) no "body has no leftover HTML comment markers" "$body_text" ;;
        *) ok "body has no leftover HTML comment markers" ;;
    esac
else
    no "print-only mode's body file is left in place for the printed command to use" "no such file: $body_file"
fi

printf '\n== --attach mode ==\n'
out_attach="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --attach 2>&1)"
rc_attach=$?
check "--attach mode exits 0" "0" "$rc_attach"
n_attach="$(grep -o -- '--attach' <<<"$out_attach" | wc -l | tr -d '[:space:]')"
check "one --attach flag per produced patch (2 commits in the range)" "2" "$n_attach"

printf '\n== single-patch range (one commit, --attach) ==\n'
out_single="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" \
    "$kickoff" "$project_dir" "HEAD~1..HEAD" \
    --from '@author' --to '@lkml-panel' --subject 'subj' \
    --template "$repo_dir/fleet/kickoffs/single-patch.md" --attach 2>&1)"
n_attach_single="$(grep -o -- '--attach' <<<"$out_single" | wc -l | tr -d '[:space:]')"
check "single-patch range attaches exactly one patch" "1" "$n_attach_single"

printf '\n== --send mode ==\n'
out_send="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --send 2>&1)"
rc_send=$?
check "--send mode exits 0" "0" "$rc_send"
if [[ -f "$capture_dir/argv" ]]; then
    ok "--send mode ran the stub fork-sandbox"
    sent_argv="$(cat "$capture_dir/argv")"
    contains "the sent argv carries the subject" "$sent_argv" "subj"
    contains "the sent argv carries --from" "$sent_argv" "--from @author"
else
    no "--send mode ran the stub fork-sandbox"
fi
contains "--send mode reports it sent" "$out_send" "stub fork-sandbox: sent"

printf '\n== missing required flags ==\n'
out_missing="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' 2>&1)"
rc_missing=$?
if (( rc_missing != 0 )); then ok "missing --subject exits non-zero"; else no "missing --subject exits non-zero" "exit 0: $out_missing"; fi
contains "missing --subject names the flag" "$out_missing" "--subject is required"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
