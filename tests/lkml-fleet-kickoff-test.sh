#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal placeholder examples deliberately contain ${...}.
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
# Counts blank lines immediately preceding the first line in $1 that
# matches $2 verbatim -- used to pin the exact blank-line shape around
# ${HANDOFF}/${SUMMARY} rather than just checking substrings are present.
# An empty/missing $1 or an anchor absent from the file prints a label
# instead of a number, so a caller comparing against an expected count
# fails loudly instead of an unset awk `target` silently running its
# "for (i = -1; i >= 1; ...)" loop zero times and printing "0" -- which
# reads identically to a genuine zero-blank-lines match.
blank_run_before() {
    local file="$1" anchor="$2"
    if [[ -z "$file" || ! -f "$file" ]]; then
        printf 'NO-SUCH-FILE\n'
        return
    fi
    awk -v anchor="$anchor" '
        { lines[NR] = $0 }
        $0 == anchor && !found { target = NR; found = 1 }
        END {
            if (!found) { print "ANCHOR-NOT-FOUND"; exit }
            n = 0
            for (i = target - 1; i >= 1 && lines[i] == ""; i--) n++
            print n
        }
    ' "$file"
}
# Lints kickoff templates for the shape fill()'s two fixed-point
# loops exist to absorb: two own-line occurrences of the SAME
# placeholder name separated by zero or one blank line. Prints one
# "file:line: NAME" line per offending pair, the line being the second
# occurrence; empty output means clean. Leading/trailing whitespace
# around an own-line placeholder is ignored, mirroring how a template
# author reads it; a separating line must be a genuinely empty one,
# matching the "\n\n" in fill()'s pattern and blank_run_before above.
adjacent_ownline_same() {
    awk '
        function ownname(line,    n) {
            n = line
            gsub(/^[ \t]+/, "", n)
            gsub(/[ \t]+$/, "", n)
            if (length(n) < 4) return ""
            if (substr(n, 1, 2) != "${" || substr(n, length(n), 1) != "}") return ""
            n = substr(n, 3, length(n) - 3)
            if (n !~ /^[A-Za-z0-9_]+$/) return ""
            return n
        }
        # Reset per file: fill() runs per template, so a pair split across
        # two files is not the shape, and awk state would bridge them.
        FNR == 1 { prevn = ""; prevpn = ""; prevblank = 0 }
        {
            n = ownname($0)
            if (n != "" && prevn == n)
                print FILENAME ":" FNR ": " n
            if (n != "" && prevblank && prevpn == n)
                print FILENAME ":" FNR ": " n
            prevpn = prevn
            prevn = n
            prevblank = ($0 == "")
        }
    ' "$@"
}

# Pulls the Nth (1-indexed) printed `--body <file>` argument's own
# Subject: header out of a composed --patches sequence -- the
# --patches-mode replacement for the old `--attach [^ ]*` pattern, since
# a patch is now named only in a `mail reply ... --body <file>` line,
# not by an --attach flag. N=1 is always the cover's own body file; N=2
# is the first patch reply, N=3 the second, and so on.
patch_subject_at() {
    local out="$1" nth="$2" f
    f="$(grep -o -- '--body [^ ]*' <<<"$out" | sed -n "${nth}p" | awk '{print $2}')"
    [[ -f "$f" ]] && grep -m1 '^Subject: ' "$f" | sed 's/^Subject: //'
}

printf '\n== fill(): literal ${PLACEHOLDER} substitution, in isolation ==\n'
# Pull lkml-fleet-kickoff.sh's own fill() definition out of the script
# rather than keeping a hand-copied duplicate here: a copy drifts the
# moment the real function changes shape and every assertion below
# would keep passing against the stale copy instead of the shipped
# code. eval'ing the extracted text still runs it in-process, so a
# mis-escaped pattern makes every downstream assertion below
# meaningless rather than failing loudly.
eval "$(sed -n '/^fill() {/,/^}/p' "$kickoff")"
sample='a${X}b and ${X} again, plus ${Y}'
fill sample X hello
fill sample Y world
check "fill() replaces every occurrence of a placeholder" \
    "ahellob and hello again, plus world" "$sample"

sample_inline='Base: ${A}'
fill sample_inline A ""
check "an inline placeholder that fills to empty stays on its line" \
    "Base: " "$sample_inline"

sample_nonempty_ownline=$'prev\n${A}\n\nnext'
fill sample_nonempty_ownline A "filled"
check "an own-line placeholder that fills to a non-empty value is not removed" \
    $'prev\nfilled\n\nnext' "$sample_nonempty_ownline"

sample_first=$'${A}\n\nnext'
fill sample_first A ""
check "own-line empty placeholder as the first line of the body removes its line and the following blank" \
    "next" "$sample_first"

sample_last=$'prev\n${A}'
fill sample_last A ""
check "own-line empty placeholder as the last line, with no trailing newline, removes just its own line" \
    "prev" "$sample_last"

sample_adjacent=$'prev\n${A}\n${B}\nnext'
fill sample_adjacent A ""
fill sample_adjacent B ""
check "two adjacent own-line empty placeholders with DIFFERENT names, no blank line between them, each remove only their own line" \
    $'prev\nnext' "$sample_adjacent"

sample_two_blanks=$'prev\n${A}\n\n\nnext'
fill sample_two_blanks A ""
check "own-line empty placeholder followed by two blank lines claims exactly one" \
    $'prev\n\nnext' "$sample_two_blanks"

sample_content_after=$'prev\n${A}\ncontent\nnext'
fill sample_content_after A ""
check "own-line empty placeholder followed immediately by a content line leaves that line untouched" \
    $'prev\ncontent\nnext' "$sample_content_after"

sample_repeat=$'${A}\n\nmiddle\n${A}\n\nend'
fill sample_repeat A ""
check "repeated own-line empty placeholder, separated by a content line, removes both" \
    $'middle\nend' "$sample_repeat"

# The shape line 118's "adjacent" test doesn't cover: the SAME name
# repeated back to back, with nothing between the two occurrences but
# newlines. ${var//pat/repl}'s non-overlapping left-to-right scan can
# only claim each occurrence's own newlines once, so consecutive same-
# name occurrences compete for the newline between them.
sample_repeat_adjacent_blank=$'prev\n${A}\n\n${A}\n\nnext'
fill sample_repeat_adjacent_blank A ""
check "two adjacent own-line empty placeholders with the SAME name, separated by a blank line, both fully removed" \
    $'prev\nnext' "$sample_repeat_adjacent_blank"

sample_repeat_adjacent_noblank=$'prev\n${A}\n${A}\nnext'
fill sample_repeat_adjacent_noblank A ""
check "two adjacent own-line empty placeholders with the SAME name, no blank line between them, both fully removed" \
    $'prev\nnext' "$sample_repeat_adjacent_noblank"

printf '\n== kickoff templates avoid the adjacent same-name own-line placeholder shape ==\n'
# fill() handles the shape the comment above its fixed-point loops
# describes, but a template growing it would trade an explicit, linted
# choice for relying on loop behaviour -- so the shape is refused at
# the template layer rather than the filling layer.
shopt -s nullglob
shipped_templates=("$repo_dir"/fleet/kickoffs/*.md)
shopt -u nullglob
if (( ${#shipped_templates[@]} > 0 )); then
    ok "the shipped kickoff templates are present to lint"
    lint_out="$(adjacent_ownline_same "${shipped_templates[@]}")"
    check "the shipped kickoff templates carry no adjacent same-name own-line placeholder" "" "$lint_out"
else
    no "the shipped kickoff templates are present to lint" "no fleet/kickoffs/*.md under $repo_dir"
fi

lint_dir="$(mktemp -d)"; tmpdirs+=("$lint_dir")
adj_fixture="$lint_dir/adjacent-noblank.md"
printf '%s\n' 'Before' '${FOO}' '${FOO}' 'After' > "$adj_fixture"
contains "adjacent same-name own-line placeholders with no blank line are reported" \
    "$(adjacent_ownline_same "$adj_fixture")" "adjacent-noblank.md:3: FOO"
blank_fixture="$lint_dir/adjacent-one-blank.md"
printf '%s\n' 'Before' '${FOO}' '' '${FOO}' 'After' > "$blank_fixture"
contains "same-name own-line placeholders a blank line apart are reported" \
    "$(adjacent_ownline_same "$blank_fixture")" "adjacent-one-blank.md:4: FOO"
diff_noblank="$lint_dir/different-noblank.md"
printf '%s\n' 'Before' '${HANDOFF}' '${SUMMARY}' 'After' > "$diff_noblank"
diff_blank="$lint_dir/different-one-blank.md"
printf '%s\n' 'Before' '${HANDOFF}' '' '${SUMMARY}' 'After' > "$diff_blank"
check "adjacent own-line placeholders with different names are not reported" "" \
    "$(adjacent_ownline_same "$diff_noblank" "$diff_blank")"
not_ownline="$lint_dir/not-own-line.md"
printf '%s\n' 'Before' 'text ${FOO}' '${FOO} text' 'After' > "$not_ownline"
check "same-name placeholders that share their line with text are not reported" "" \
    "$(adjacent_ownline_same "$not_ownline")"
far_apart="$lint_dir/far-apart.md"
printf '%s\n' 'Before' '${FOO}' 'a real line' 'another real line' '${FOO}' 'After' > "$far_apart"
check "same-name own-line placeholders far apart are not reported" "" \
    "$(adjacent_ownline_same "$far_apart")"
span_a="$lint_dir/span-a.md"
printf 'Before\n${FOO}\n' > "$span_a"
span_b="$lint_dir/span-b.md"
printf '${FOO}\nAfter\n' > "$span_b"
check "a same-name pair split across two files is not reported" "" \
    "$(adjacent_ownline_same "$span_a" "$span_b")"
ws_padded="$lint_dir/whitespace-padded.md"
printf 'Before\n  ${FOO}\n${FOO}  \nAfter\n' > "$ws_padded"
contains "an own-line placeholder padded with whitespace still counts as own-line" \
    "$(adjacent_ownline_same "$ws_padded")" "whitespace-padded.md:3: FOO"

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
if [[ "${1-}" == "fleet" && "${2-}" == "expand" ]]; then
    printf '%s\n' "${3-}" >> "$STUB_EXPAND_LOG"
    printf '%s\n' "${FORK_SANDBOX_PERSONAS_DIR-unset}" >> "${STUB_PERSONAS_LOG:-/dev/null}"
    case "${3-}" in
        @ci) printf '%s\n' '@ci' ;;
        @ci-and-core) printf '%s\n' '@ci' '@core' ;;
        @lkml-panel) printf '%s\n' '@core' '@ci' ;;
        @ci-only) printf '%s\n' '@ci' ;;
        @missing|@empty) echo "Error: expand: unknown address '${3}'." >&2; exit 1 ;;
        *) echo "Error: unexpected fixture address '${3}'." >&2; exit 1 ;;
    esac
    exit 0
fi
if [[ "${1-}" == "mail" && ( "${2-}" == "send" || "${2-}" == "reply" ) ]]; then
    printf '%s\n' "$*" >> "$STUB_CAPTURE_DIR/argv"
    id="stub-$(printf '%s' "$*" | cksum | awk '{print $1}')-$$"
    if [[ "$2" == "send" ]]; then
        echo "stub fork-sandbox: sent $id as a new thread" >&2
    else
        echo "stub fork-sandbox: replied $id" >&2
    fi
    printf '%s\n' "$id"
    exit 0
fi
echo "Error: unexpected stub invocation: $*" >&2
exit 1
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
case "$out" in
    *"--hops"*) no "print-only mode without --hops carries no --hops flag" "$out" ;;
    *) ok "print-only mode without --hops carries no --hops flag" ;;
esac
contains "printed command carries the subject" "$out" "PATCH\\ v1\\ 0/2"
tmp_prefix="${TMPDIR:-/tmp}"; tmp_prefix="${tmp_prefix%/}"
contains "printed command points --body at a tempfile" "$out" "--body $tmp_prefix/"
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
    case "$body_text" in
        'Subject:'*) no "body does not repeat the mail Subject header" "$body_text" ;;
        *) ok "body does not repeat the mail Subject header" ;;
    esac
    contains "body has the filled summary" "$body_text" "does a thing"
    contains "body has the base" "$body_text" "Base: master"
    # ${HANDOFF} fills to the empty string for an ordinary kickoff, and it
    # sits between blank lines in the template, so the body would open on
    # two blank lines if they were not trimmed.
    check "ordinary body opens on its first real line, not a blank" \
        "does a thing" "$(head -n1 "$body_file")"
    check "ordinary body leaves no unsubstituted HANDOFF placeholder" "0" \
        "$(grep -c 'HANDOFF' "$body_file")"
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

printf '\n== --hops validation and passthrough ==\n'
out_hops="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --hops 9 2>&1)"
contains "--hops 9 appears in the printed command" "$out_hops" "--hops 9"
out_hops_bad="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --hops nine 2>&1)"
rc_hops_bad=$?
if (( rc_hops_bad != 0 )); then ok "a non-integer --hops exits non-zero"; else no "a non-integer --hops exits non-zero" "exit 0: $out_hops_bad"; fi
contains "a non-integer --hops names the validation problem" "$out_hops_bad" "non-negative integer"
out_hops_negative="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --hops -1 2>&1)"
rc_hops_negative=$?
if (( rc_hops_negative != 0 )); then ok "a negative --hops exits non-zero"; else no "a negative --hops exits non-zero" "exit 0: $out_hops_negative"; fi
contains "a negative --hops names the validation problem" "$out_hops_negative" "non-negative integer"

printf '\n== --patches mode: composed (no --send) sequence ==\n'
out_patches="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --patches 2>&1)"
rc_patches=$?
check "--patches mode exits 0" "0" "$rc_patches"
n_cover_id="$(grep -c -- 'cover_id=\$(' <<<"$out_patches")"
check "--patches composes exactly one cover_id=\$(...) assignment" "1" "$n_cover_id"
n_reply="$(grep -c -- '^fork-sandbox mail reply' <<<"$out_patches")"
check "--patches composes one mail reply per produced patch (2 commits in the range)" "2" "$n_reply"
n_to_operator="$(grep -o -- '--to @operator' <<<"$out_patches" | wc -l | tr -d '[:space:]')"
check "every patch reply addresses --to @operator" "2" "$n_to_operator"
n_reply_to="$(grep -o -- '--reply-to "\$cover_id"' <<<"$out_patches" | wc -l | tr -d '[:space:]')"
check "every patch reply carries --reply-to \"\$cover_id\"" "2" "$n_reply_to"
contains "the cover keeps its own recipients" "$out_patches" '--to @lkml-panel'
patch1_subject="$(patch_subject_at "$out_patches" 2)"
patch2_subject="$(patch_subject_at "$out_patches" 3)"
contains "the first patch reply's subject is [PATCH v1 1/2]" "$patch1_subject" "[PATCH v1 1/2]"
contains "the second patch reply's subject is [PATCH v1 2/2]" "$patch2_subject" "[PATCH v1 2/2]"

printf '\n== single-patch range (one commit, --patches) ==\n'
out_single="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" \
    "$kickoff" "$project_dir" "topic~1..topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' \
    --template "$repo_dir/fleet/kickoffs/single-patch.md" --patches 2>&1)"
n_reply_single="$(grep -c -- '^fork-sandbox mail reply' <<<"$out_single")"
check "single-patch range composes exactly one mail reply" "1" "$n_reply_single"
single_patch_subject="$(patch_subject_at "$out_single" 2)"
contains "the single patch reply's subject is [PATCH v1 1/1]" "$single_patch_subject" "[PATCH v1 1/1]"

printf '\n== --attach is a deprecated alias for --patches ==\n'
out_attach_alias="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --attach 2>&1)"
contains "--attach prints a deprecation warning naming --patches" "$out_attach_alias" "deprecated alias for --patches"
n_reply_alias="$(grep -c -- '^fork-sandbox mail reply' <<<"$out_attach_alias")"
check "--attach still composes one mail reply per patch (behaves like --patches)" "2" "$n_reply_alias"

printf '\n== --send mode with --patches: actual dispatch, not just composed ==\n'
rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --patches --send >/dev/null 2>&1
rc_send_patches=$?
check "--send with --patches exits 0" "0" "$rc_send_patches"
send_patches_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
n_send_patches_sent="$(grep -c -- '^mail send' <<<"$send_patches_argv")"
check "--send --patches posts exactly one cover" "1" "$n_send_patches_sent"
n_send_patches_replied="$(grep -c -- '^mail reply' <<<"$send_patches_argv")"
check "--send --patches posts one reply per patch (2 commits in the range)" "2" "$n_send_patches_replied"
n_send_patches_to_operator="$(grep -o -- '--to @operator' <<<"$send_patches_argv" | wc -l | tr -d '[:space:]')"
check "every posted patch reply addresses --to @operator" "2" "$n_send_patches_to_operator"
contains "the posted cover keeps its own recipients" "$send_patches_argv" "mail send --from @author --to @lkml-panel"
send_patches_reply_to_values="$(grep -oE -- '\-\-reply-to [^ ]+' <<<"$send_patches_argv" | sort -u)"
check "both posted patch replies use the same --reply-to (the cover's own id)" "1" "$(wc -l <<<"$send_patches_reply_to_values")"

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

printf '\n== --ci-first addresses CI, hands off to the panel, and gates the shape ==\n'
expand_log="$work/expand.log"
personas_log="$work/personas.log"; : > "$personas_log"
: > "$expand_log"
out_ci_first="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" STUB_PERSONAS_LOG="$personas_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@ci' 2>&1)"
rc_ci_first=$?
check "--ci-first print-only mode exits 0" "0" "$rc_ci_first"
contains "--ci-first makes the command address CI alone" "$out_ci_first" "--to @ci"
ci_body_file="$(printf '%s' "$out_ci_first" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
ci_body_text="$([[ -f "$ci_body_file" ]] && cat "$ci_body_file")"
contains "--ci-first body carries the panel address" "$ci_body_text" '`To:` to @lkml-panel'
contains "--ci-first body carries the fixed wave-one heading" "$ci_body_text" "## Wave one: test results first"
check "--ci-first body opens on the wave-one heading, not a blank" \
    "## Wave one: test results first" "$(head -n1 "$ci_body_file")"
contains "--ci-first body says CI alone was addressed" "$ci_body_text" "addressed to you alone"
contains "--ci-first without --hops defaults to 9" "$out_ci_first" "--hops 9"
contains "--ci-first without --hops explains its hop bump" "$out_ci_first" "extra hop"
check "--ci-first gate expands CI then panel in print-only mode" $'@ci\n@lkml-panel' "$(cat "$expand_log")"

out_ci_multiple="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@ci-and-core' 2>&1)"
rc_ci_multiple=$?
if (( rc_ci_multiple != 0 )); then ok "a multi-seat CI address refuses"; else no "a multi-seat CI address refuses" "exit 0: $out_ci_multiple"; fi
contains "a multi-seat CI refusal requires exactly one seat" "$out_ci_multiple" "exactly one CI seat"

out_ci_cc="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --cc '@core' --subject 'subj' --ci-first '@ci' 2>&1)"
rc_ci_cc=$?
if (( rc_ci_cc != 0 )); then ok "--ci-first rejects a Cc that would wake a fleet seat"; else no "--ci-first rejects a Cc that would wake a fleet seat" "exit 0: $out_ci_cc"; fi
contains "--ci-first Cc refusal explains the ordering violation" "$out_ci_cc" "Cc recipients are not woken before its results"

ci_template_dir="$(mktemp -d)"; tmpdirs+=("$ci_template_dir")
no_handoff_template="$ci_template_dir/no-handoff.md"
printf 'Custom review kickoff: ${SUMMARY}\n' > "$no_handoff_template"
out_ci_no_handoff="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@ci' \
    --template "$no_handoff_template" 2>&1)"
rc_ci_no_handoff=$?
if (( rc_ci_no_handoff != 0 )); then ok "--ci-first rejects a template without the routing handoff"; else no "--ci-first rejects a template without the routing handoff" "exit 0: $out_ci_no_handoff"; fi
contains "missing CI-first handoff refusal names the placeholder" "$out_ci_no_handoff" '${HANDOFF}'

out_ci_hops_20="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@ci' --hops 20 2>&1)"
contains "--ci-first carries an explicit --hops 20" "$out_ci_hops_20" "--hops 20"
out_ci_hops_8="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@ci' --hops 8 2>&1)"
contains "--ci-first permits explicit --hops 8" "$out_ci_hops_8" "--hops 8"
contains "--ci-first warns when explicit hops costs the extra hop" "$out_ci_hops_8" "extra hop"

out_ci_missing="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@missing' 2>&1)"
rc_ci_missing=$?
if (( rc_ci_missing != 0 )); then ok "an unresolvable CI address refuses in print-only mode"; else no "an unresolvable CI address refuses in print-only mode" "exit 0: $out_ci_missing"; fi
contains "an unresolvable CI address names both documented answers" "$out_ci_missing" "services-backed \`ci\` seat"
contains "an unresolvable CI address names test-results injection" "$out_ci_missing" "tests were run elsewhere"
contains "an unresolvable CI address rejects directly addressing the panel" "$out_ci_missing" "wrong"

out_panel_empty="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@empty' --subject 'subj' --ci-first '@ci' 2>&1)"
rc_panel_empty=$?
if (( rc_panel_empty != 0 )); then ok "a panel that expands to nothing refuses"; else no "a panel that expands to nothing refuses" "exit 0: $out_panel_empty"; fi
contains "an empty panel refusal says wave two wakes nobody" "$out_panel_empty" "wave two would wake nobody"
out_panel_ci_only="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@ci-only' --subject 'subj' --ci-first '@ci' 2>&1)"
rc_panel_ci_only=$?
if (( rc_panel_ci_only != 0 )); then ok "a panel of CI alone refuses"; else no "a panel of CI alone refuses" "exit 0: $out_panel_ci_only"; fi
contains "a CI-only panel refusal says wave two wakes nobody" "$out_panel_ci_only" "wave two would wake nobody"

out_ci_no_command="$(PATH="/usr/bin:/bin" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@ci' 2>&1)"
rc_ci_no_command=$?
if (( rc_ci_no_command != 0 )); then ok "--ci-first refuses when fork-sandbox is unavailable"; else no "--ci-first refuses when fork-sandbox is unavailable" "exit 0: $out_ci_no_command"; fi
contains "a missing fork-sandbox refusal names the command" "$out_ci_no_command" "missing fork-sandbox command"

case "$body_text" in
    *'${HANDOFF}'*) no "ordinary kickoff has no leftover HANDOFF placeholder" "$body_text" ;;
    *) ok "ordinary kickoff has no leftover HANDOFF placeholder" ;;
esac
case "$body_text" in
    *"## Wave one: test results first"*) no "ordinary kickoff has no wave-one block" "$body_text" ;;
    *) ok "ordinary kickoff has no wave-one block" ;;
esac

printf '\n== case matrix: blank-line shape around ${HANDOFF}/${SUMMARY} ==\n'
# series-review.md holds "${HANDOFF}\n\n${SUMMARY}\n\nBase: ...". Each of
# ${HANDOFF} and ${SUMMARY} is independently empty or filled depending on
# --ci-first/--summary, and every combination must leave exactly one
# blank line between the last real content above and "Base:" -- never
# more than one (a stray blank left behind by a placeholder that filled
# to nothing) -- UNLESS both fill empty, in which case there is no
# content above "Base:" at all and the body opens directly on it (row
# 1, "0"): the "never zero" rule describes gluing real content to
# "Base:", not the body's own opening line.
row1_out="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' 2>&1)"
row1_body_file="$(printf '%s' "$row1_out" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
check "row 1 (no --ci-first, no --summary): no blank line before Base: (body opens directly on it)" \
    "0" "$(blank_run_before "$row1_body_file" "Base: master")"

row2_out="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --summary 'row two summary' 2>&1)"
row2_body_file="$(printf '%s' "$row2_out" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
check "row 2 (no --ci-first, --summary): exactly one blank line before Base:" \
    "1" "$(blank_run_before "$row2_body_file" "Base: master")"

row3_out="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@ci' 2>&1)"
row3_body_file="$(printf '%s' "$row3_out" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
check "row 3 (--ci-first, no --summary): exactly one blank line before Base: -- the regression this round fixes" \
    "1" "$(blank_run_before "$row3_body_file" "Base: master")"

row4_out="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@ci' --summary 'row four summary' 2>&1)"
row4_body_file="$(printf '%s' "$row4_out" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
check "row 4 (--ci-first, --summary): exactly one blank line before Base:" \
    "1" "$(blank_run_before "$row4_body_file" "Base: master")"

printf '\n== missing required flags ==\n'
out_missing="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' 2>&1)"
rc_missing=$?
if (( rc_missing != 0 )); then ok "missing --subject exits non-zero"; else no "missing --subject exits non-zero" "exit 0: $out_missing"; fi
contains "missing --subject names the flag" "$out_missing" "--subject is required"

printf '\n== a trailing flag with no value names the flag, not $2: unbound ==\n'
out_trailing="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --from 2>&1)"
rc_trailing=$?
if (( rc_trailing != 0 )); then ok "trailing --from with no value exits non-zero"; else no "trailing --from with no value exits non-zero" "exit 0: $out_trailing"; fi
contains "trailing --from with no value names the flag" "$out_trailing" "--from requires a value"

printf '\n== --patches with a range that produces no commits is a hard error ==\n'
out_empty_patches="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "HEAD..HEAD" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --patches 2>&1)"
rc_empty_patches=$?
if (( rc_empty_patches != 0 )); then ok "--patches with an empty range exits non-zero"; else no "--patches with an empty range exits non-zero" "exit 0: $out_empty_patches"; fi
contains "--patches with an empty range names the problem" "$out_empty_patches" "produced no patches"

printf '\n== branch-name variant (no --patches) with a range that produces no commits is also a hard error ==\n'
out_empty_branch="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "topic..topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' 2>&1)"
rc_empty_branch=$?
if (( rc_empty_branch != 0 )); then ok "branch-name variant with an empty range exits non-zero"; else no "branch-name variant with an empty range exits non-zero" "exit 0: $out_empty_branch"; fi
contains "branch-name variant with an empty range names the problem" "$out_empty_branch" "produced no patches"

printf '\n== branch-name variant refuses a range whose right side is not a branch ==\n'
out_bad_branch="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "HEAD~1..HEAD" \
    --from '@author' --to '@lkml-panel' --subject 'subj' \
    --template "$repo_dir/fleet/kickoffs/single-patch.md" 2>&1)"
rc_bad_branch=$?
if (( rc_bad_branch != 0 )); then ok "branch-name variant with a non-branch range exits non-zero"; else no "branch-name variant with a non-branch range exits non-zero" "exit 0: $out_bad_branch"; fi
contains "branch-name variant names the problem" "$out_bad_branch" "does not resolve to a checkout-able branch name"

printf '\n== --patches also refuses a range whose right side is not a branch, since the template always offers the checkout fallback too ==\n'
out_bad_branch_patches="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "HEAD~1..HEAD" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --patches \
    --template "$repo_dir/fleet/kickoffs/single-patch.md" 2>&1)"
rc_bad_branch_patches=$?
if (( rc_bad_branch_patches != 0 )); then ok "--patches with a non-branch range exits non-zero"; else no "--patches with a non-branch range exits non-zero" "exit 0: $out_bad_branch_patches"; fi
contains "--patches with a non-branch range names the problem" "$out_bad_branch_patches" "does not resolve to a checkout-able branch name"

printf '\n== a comment closing with trailing whitespace still strips cleanly ==\n'
template_dir="$(mktemp -d)"; tmpdirs+=("$template_dir")
trailing_ws_template="$template_dir/trailing-ws.md"
printf '<!-- DRAFT: adapted for the fork-sandbox fleet --> \nReal body text: ${SUMMARY}\n' > "$trailing_ws_template"
out_trailing_ws="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --summary 'does a thing' \
    --template "$trailing_ws_template" 2>&1)"
rc_trailing_ws=$?
check "trailing-whitespace-comment template exits 0" "0" "$rc_trailing_ws"
trailing_ws_body_file="$(printf '%s' "$out_trailing_ws" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
trailing_ws_body_text="$([[ -f "$trailing_ws_body_file" ]] && cat "$trailing_ws_body_file")"
contains "body survives a comment whose closing --> has trailing whitespace" \
    "$trailing_ws_body_text" "Real body text: does a thing"

printf '\n== a template whose comment never closes is a hard error, not an empty mail ==\n'
unterminated_template="$template_dir/unterminated.md"
printf '<!-- DRAFT: never closed\nBody text that should never be reached.\n' > "$unterminated_template"
out_unterminated="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --template "$unterminated_template" 2>&1)"
rc_unterminated=$?
if (( rc_unterminated != 0 )); then ok "unterminated comment exits non-zero"; else no "unterminated comment exits non-zero" "exit 0: $out_unterminated"; fi
contains "unterminated comment names the problem" "$out_unterminated" "produced an empty body"

printf '\n== focused-review template: a follow-up round that fills through the harness ==\n'
focused_template="$repo_dir/fleet/kickoffs/focused-review.md"
if [[ -f "$focused_template" ]]; then
    ok "focused-review template exists in fleet/kickoffs"
else
    no "focused-review template exists in fleet/kickoffs"
fi

# The operator's focus is filled into the copy before the harness runs;
# the harness must carry it into the body intact and leave no
# placeholder behind. Asserting the literal ${FOCUS} is absent is the
# point: a missed substitution ships silently.
focused_copy="$template_dir/focused-filled.md"
sed 's/\${FOCUS}/concentrate on the error handling in the mail path/' \
    "$focused_template" > "$focused_copy"
out_focus="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' \
    --summary 'answers round one' \
    --template "$focused_copy" 2>&1)"
rc_focus=$?
check "focused-review template composes through the harness" "0" "$rc_focus"
focus_body_file="$(printf '%s' "$out_focus" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
focus_body_text="$([[ -f "$focus_body_file" ]] && cat "$focus_body_file")"
contains "the operator's focus reaches the body" "$focus_body_text" "concentrate on the error handling in the mail path"
case "$focus_body_text" in
    *'${FOCUS}'*) no "focused body has no leftover FOCUS placeholder" "$focus_body_text" ;;
    *) ok "focused body has no leftover FOCUS placeholder" ;;
esac
case "$focus_body_text" in
    *'${'*) no "focused body has no leftover unfilled placeholders" "$focus_body_text" ;;
    *) ok "focused body has no leftover unfilled placeholders" ;;
esac
check "focused body leaves no unsubstituted HANDOFF placeholder" "0" \
    "$(grep -c 'HANDOFF' "$focus_body_file")"
check "focused body opens on the focus line, not a blank" \
    "This round is for: concentrate on the error handling in the mail path" \
    "$(head -n1 "$focus_body_file" 2>/dev/null)"

out_focus_ci="$(PATH="$stub_bin:$PATH" STUB_EXPAND_LOG="$expand_log" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --ci-first '@ci' \
    --template "$focused_copy" 2>&1)"
rc_focus_ci=$?
check "--ci-first composes the focused-review template" "0" "$rc_focus_ci"
focus_ci_body_file="$(printf '%s' "$out_focus_ci" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
check "--ci-first focused body opens on the wave-one heading, not a blank" \
    "## Wave one: test results first" "$(head -n1 "$focus_ci_body_file" 2>/dev/null)"
contains "--ci-first focused body keeps the focus below the handoff" \
    "$([[ -f "$focus_ci_body_file" ]] && cat "$focus_ci_body_file")" \
    "This round is for: concentrate on the error handling in the mail path"

printf '\n== --focus fills ${FOCUS}; omitting it for a focused template is refused ==\n'
out_focus_flag="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' \
    --summary 'answers round one' \
    --focus 'concentrate on the error handling in the mail path' \
    --version 2 --template "$focused_template" 2>&1)"
rc_focus_flag=$?
check "--focus composes the focused-review template" "0" "$rc_focus_flag"
focus_flag_body_file="$(printf '%s' "$out_focus_flag" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
focus_flag_body_text="$([[ -f "$focus_flag_body_file" ]] && cat "$focus_flag_body_file")"
contains "--focus reaches the body" "$focus_flag_body_text" "concentrate on the error handling in the mail path"
case "$focus_flag_body_text" in
    *'${FOCUS}'*) no "--focus leaves no FOCUS placeholder" "$focus_flag_body_text" ;;
    *) ok "--focus leaves no FOCUS placeholder" ;;
esac
contains "print-only focused compose warns the sent command starts a new thread" "$out_focus_flag" "starts a new thread"
contains "the focused print-only warning names the mail reply bridge" "$out_focus_flag" "mail reply"

# A ${FOCUS} template is a reply template, and --send would run
# `mail send` on it, starting a new thread and throwing away the
# earlier round the focus points at: refuse, and run nothing.
rm -f -- "$capture_dir/argv"
out_focus_send="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' \
    --focus 'concentrate on the error handling in the mail path' \
    --version 2 --template "$focused_template" --send 2>&1)"
rc_focus_send=$?
if (( rc_focus_send != 0 )); then ok "a focused template with --send refuses"; else no "a focused template with --send refuses" "exit 0: $out_focus_send"; fi
contains "the focused --send refusal says send starts a new thread" "$out_focus_send" "starts a new thread"
contains "the focused --send refusal names the mail reply bridge" "$out_focus_send" "mail reply"
if [[ -f "$capture_dir/argv" ]]; then
    no "a refused focused --send ran no fork-sandbox command" "$(cat "$capture_dir/argv")"
else
    ok "a refused focused --send ran no fork-sandbox command"
fi

out_focus_missing="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' \
    --template "$focused_template" 2>&1)"
rc_focus_missing=$?
if (( rc_focus_missing != 0 )); then ok "a focused template without --focus refuses"; else no "a focused template without --focus refuses" "exit 0: $out_focus_missing"; fi
contains "the missing-focus refusal names --focus" "$out_focus_missing" "--focus"

# A focused round is a reply into an existing thread that already has
# versions on the wire, so silently stamping v1 the way a new-thread
# round does would mislabel it. A versionless subject and no --version
# is refused instead, naming --version <n> as the fix -- not
# --allow-ambiguous-version, which guards a different failure entirely.
out_focus_noversion="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'sched: tidy the thing' \
    --focus 'patch 2 only' --template "$focused_template" 2>&1)"
rc_focus_noversion=$?
if (( rc_focus_noversion != 0 )); then ok "a focused template with a versionless subject and no --version refuses"; else no "a focused template with a versionless subject and no --version refuses" "exit 0: $out_focus_noversion"; fi
contains "the no-determinable-version refusal names --version" "$out_focus_noversion" "--version"
contains "the no-determinable-version refusal states the reason" "$out_focus_noversion" "no determinable version"
case "$out_focus_noversion" in
    *'--allow-ambiguous-version'*) no "the no-determinable-version refusal does not point at --allow-ambiguous-version" "$out_focus_noversion" ;;
    *) ok "the no-determinable-version refusal does not point at --allow-ambiguous-version" ;;
esac

# The detection anchors on a LEADING "[PATCH", so a reply-shaped subject
# carries a version token that is not leading -- that is not the same
# as "no version anywhere in the subject": the marker is right there,
# just after a "Re: " prefix. Stamping over it (whether the v1 default
# or an operator-given --version) would prepend a second bracket in
# front of the one already there instead of replacing it, so this must
# refuse -- naming a reword, not --version, as the fix -- regardless of
# whether --version was given. It is not the multi-version re-parse
# guard either: per this script's own header, that guard fires on an
# already-marked subject too, but only once it re-parses to more than
# one *distinct* version, and a double-stamped subject whose given
# --version happens to equal the embedded marker's version re-parses as
# exactly one -- so that guard cannot be relied on to catch this case.
out_focus_reply="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'Re: [PATCH v3 0/2] improve the thing' \
    --focus 'patch 2 only' --template "$focused_template" 2>&1)"
rc_focus_reply=$?
if (( rc_focus_reply != 0 )); then ok "a reply-shaped subject with a non-leading version token still refuses"; else no "a reply-shaped subject with a non-leading version token still refuses" "exit 0: $out_focus_reply"; fi
contains "the reply-shaped refusal names rewording" "$out_focus_reply" "Reword the subject"
case "$out_focus_reply" in
    *'Pass --version'*) no "the reply-shaped refusal does not tell the operator to pass --version" "$out_focus_reply" ;;
    *) ok "the reply-shaped refusal does not tell the operator to pass --version" ;;
esac
case "$out_focus_reply" in
    *'lkml-fleet-status.sh'*) no "the reply-shaped refusal is not the multi-version re-parse guard" "$out_focus_reply" ;;
    *) ok "the reply-shaped refusal is not the multi-version re-parse guard" ;;
esac
case "$out_focus_reply" in
    *'--allow-ambiguous-version'*) no "the reply-shaped refusal does not point at --allow-ambiguous-version" "$out_focus_reply" ;;
    *) ok "the reply-shaped refusal does not point at --allow-ambiguous-version" ;;
esac

# The above refusal must fire even when --version IS given and equals
# the embedded marker's version -- otherwise an operator who followed
# the (wrong) "Pass --version <n>" advice would compose a silently
# double-stamped subject ('[PATCH v3 0/2] Re: [PATCH v3 0/2] improve the
# thing') whose two identical version tokens dedup to one in the
# re-parse guard, so nothing downstream would catch it either.
out_focus_reply_version="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'Re: [PATCH v3 0/2] improve the thing' \
    --focus 'patch 2 only' --version 3 --template "$focused_template" 2>&1)"
rc_focus_reply_version=$?
if (( rc_focus_reply_version != 0 )); then ok "a reply-shaped subject still refuses when --version matches the embedded marker"; else no "a reply-shaped subject still refuses when --version matches the embedded marker" "exit 0: $out_focus_reply_version"; fi
case "$out_focus_reply_version" in
    # The composed command is printed via `printf '%q '`, so a literal
    # space or bracket in the subject is backslash-escaped in the
    # output -- this must match the escaped form, not the raw subject
    # text, or it can never fail regardless of what the script prints.
    *'\[PATCH\ v3\ 0/2\]\ Re:\ \[PATCH\ v3\ 0/2\]'*) no "the double-stamped subject never appears in the output" "$out_focus_reply_version" ;;
    *) ok "the double-stamped subject never appears in the output" ;;
esac

# The acceptance direction that separates "refuse when no determinable
# version" from the over-refusing "focused requires --version": a
# leading, versioned bracket IS a determinable version, so this must
# compose without --version, stamped with the version already on the
# subject.
out_focus_leading="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH v3 0/2] improve the thing' \
    --focus 'patch 2 only' --template "$focused_template" 2>&1)"
rc_focus_leading=$?
check "a focused subject with a leading version marker composes without --version" "0" "$rc_focus_leading"
contains "the leading-marker subject is passed through stamped v3" \
    "$out_focus_leading" '\[PATCH\ v3\ 0/2\]\ improve\ the\ thing'

out_focus_version="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'sched: tidy the thing' \
    --focus 'patch 2 only' --version 2 --template "$focused_template" 2>&1)"
rc_focus_version=$?
check "a focused template with --version composes" "0" "$rc_focus_version"
contains "a focused template with --version stamps the given version" \
    "$out_focus_version" "PATCH\\ v2\\ 0/2\\]\\ sched:\\ tidy\\ the\\ thing"

# A leading but UNVERSIONED PATCH bracket is not a reply-shaped subject
# -- it is the qualifier-preserving stamp case the header documents
# ("[RFC PATCH 0/5]" keeps its qualifier). The non-leading-marker guard
# above must not fire on this leading bracket just because its own
# unanchored first-bracket scan would otherwise see it too.
out_focus_leading_unversioned="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH 0/2] improve the thing' \
    --focus 'patch 2 only' --version 3 --template "$focused_template" 2>&1)"
rc_focus_leading_unversioned=$?
check "a focused subject with a leading unversioned PATCH bracket composes with --version" "0" "$rc_focus_leading_unversioned"
contains "the leading unversioned bracket is stamped v3 in place, not refused" \
    "$out_focus_leading_unversioned" '\[PATCH\ v3\ 0/2\]\ improve\ the\ thing'

out_focus_leading_rfc="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[RFC PATCH] improve the thing' \
    --focus 'patch 2 only' --version 3 --template "$focused_template" 2>&1)"
rc_focus_leading_rfc=$?
check "a focused subject with a leading unversioned qualified bracket composes with --version" "0" "$rc_focus_leading_rfc"
contains "the leading RFC bracket is stamped v3 with its qualifier kept" \
    "$out_focus_leading_rfc" '\[RFC\ PATCH\ v3\ 0/2\]\ improve\ the\ thing'

# A non-PATCH bracket ahead of the real, non-leading marker (e.g. a
# subsystem tag before a "Re: " reply prefix) must not hide that marker
# from the guard: the unanchored scan has to walk every bracket, not
# just the leftmost one.
out_focus_bracket_before_reply="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[net-next] Re: [PATCH v3 0/2] improve the thing' \
    --focus 'patch 2 only' --version 3 --template "$focused_template" 2>&1)"
rc_focus_bracket_before_reply=$?
if (( rc_focus_bracket_before_reply != 0 )); then ok "a non-PATCH bracket ahead of a non-leading marker still refuses"; else no "a non-PATCH bracket ahead of a non-leading marker still refuses" "exit 0: $out_focus_bracket_before_reply"; fi
case "$out_focus_bracket_before_reply" in
    *'\[PATCH\ v3\ 0/2\]\ \[net-next\]'*) no "the bracket-then-reply subject is not double-stamped in the output" "$out_focus_bracket_before_reply" ;;
    *) ok "the bracket-then-reply subject is not double-stamped in the output" ;;
esac

# The reply-shaped-marker corruption is not focus-specific: a plain
# template with no ${FOCUS} placeholder hits the same v1-default/stamp
# path and must refuse too, not just warn or silently double-stamp.
out_plain_reply="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'Re: [PATCH v3 0/2] improve the thing' --version 3 \
    --template "$repo_dir/fleet/kickoffs/series-review.md" 2>&1)"
rc_plain_reply=$?
if (( rc_plain_reply != 0 )); then ok "a reply-shaped subject on a non-focused template still refuses"; else no "a reply-shaped subject on a non-focused template still refuses" "exit 0: $out_plain_reply"; fi
contains "the non-focused reply-shaped refusal names rewording" "$out_plain_reply" "Reword the subject"

out_nofocus_plain="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --summary 'does a thing' \
    --template "$repo_dir/fleet/kickoffs/series-review.md" 2>&1)"
rc_nofocus_plain=$?
check "a template without the FOCUS placeholder is unaffected by omitting --focus" "0" "$rc_nofocus_plain"
contains "the unfocused plain kickoff still composes normally" "$out_nofocus_plain" "fork-sandbox mail send"

printf '\n== --focus for a template without ${FOCUS} warns; the text does not reach the mail ==\n'
# The mirror of the missing-focus refusal above: the operator asked for a
# focused round, but this template has nowhere to put it. Composing must
# still succeed -- the mail is a valid ordinary kickoff -- and the warning
# is the thing that keeps the panel from silently waking to a full review
# while the command line says the round was focused.
out_focus_noph="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subj' \
    --focus 'ONLY the mail error paths' \
    --template "$repo_dir/fleet/kickoffs/series-review.md" 2>&1)"
rc_focus_noph=$?
check "--focus on an unfocused template still composes" "0" "$rc_focus_noph"
contains "--focus on an unfocused template warns about the missing placeholder" "$out_focus_noph" 'has no ${FOCUS} placeholder'
contains "the unfocused --focus warning names the focus text that will not land" "$out_focus_noph" "ONLY the mail error paths"
contains "the unfocused --focus compose still prints the mail send command" "$out_focus_noph" "fork-sandbox mail send"
focus_noph_body_file="$(printf '%s' "$out_focus_noph" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
case "$(cat "$focus_noph_body_file" 2>/dev/null)" in
    *'ONLY the mail error paths'*) no "an unfocused template drops the focus text out of the body" "focus text found in body" ;;
    *) ok "an unfocused template drops the focus text out of the body" ;;
esac

printf '\n== --ci-first resolves against the lkml persona registry ==\n'
# The gate must consult the personas in THIS checkout, not whatever fleet
# the machine ~/.config/fork-sandbox happens to describe -- against the
# machine registry the panel resolves to nothing and every gate below
# refuses for the wrong reason. It reaches them by calling
# scripts/lkml-fleet.sh, which exports FORK_SANDBOX_PERSONAS_DIR, so the
# stub seeing that variable IS the proof the gate went through the
# wrapper. A bare `fork-sandbox fleet expand` leaves it unset.
repo_personas="$repo_dir/fleet/personas"
if grep -Fqx -- "$repo_personas" "$personas_log"; then
    ok "--ci-first gate resolves against this checkout's personas"
else
    no "--ci-first gate resolves against this checkout's personas" \
        "expected '$repo_personas', log holds: $(cat "$personas_log")"
fi
if grep -Fqx -- unset "$personas_log"; then
    no "--ci-first gate never expands with no personas dir set" "$(cat "$personas_log")"
else
    ok "--ci-first gate never expands with no personas dir set"
fi

printf '\n== kickoff templates keep the no-attachment guard on the author reply ==\n'
# A wake's harvested reply carries no attachment path (the postmaster
# builds `mail reply` without --attach), so the "Next version" sections
# must keep stating that the inline copy is the review copy -- the
# silent false-green the inline convention exists to prevent. A host
# `mail reply` can attach, but that is a different actor from the wake
# these sections govern.
series_tail="$(sed -n '/^## Next version/,$p' "$repo_dir/fleet/kickoffs/series-review.md")"
contains "series-review Next version keeps the wake no-attachment guard" "$series_tail" "a wake's reply cannot carry"
contains "series-review Next version keeps the review-copy convention" "$series_tail" "messages are the review copy"
single_tail="$(sed -n '/^## Next version/,$p' "$repo_dir/fleet/kickoffs/single-patch.md")"
contains "single-patch Next version keeps the wake no-attachment guard" "$single_tail" "a wake's reply cannot"
contains "single-patch Next version keeps the review-copy convention" "$single_tail" "the patch message is the review copy"

printf '\n== --version stamps the kickoff subject ==\n'
# Extract fs_subject_versions() from lkml-fleet-status.sh itself, the
# same "pull the real function rather than keep a hand-copied duplicate"
# approach used for fill() above -- this is the round-trip check that
# catches a marker which looks right but the Versions section can't
# actually parse.
eval "$(sed -n '/^fs_subject_versions() {/,/^}/p' "$repo_dir/scripts/lkml-fleet-status.sh")"

# The stub records its argv joined by spaces ("$*"), which loses the
# quoting that told bash "--subject" and "--body" were separate
# arguments -- so pull the subject back out positionally, between the
# literal "--subject " and " --body " that cmd= in the script always
# places around it, rather than retyping the subject by hand. Feeding a
# hand-typed literal instead would only prove that the literal parses,
# not that the script's own output does -- the exact gap CLAUDE.md's
# "self-consistent fixtures" hazard warns about.
ver_argv_subject() { sed -E 's/^.*--subject (.*) --body .*/\1/' <<<"$1"; }

# Pulls the stamped subject back out of the multi-version refusal message
# (between "produces subject '" and "', which lkml-fleet-status.sh") so a
# refusal case can be re-checked against the real fs_subject_versions()
# parser instead of trusting the message's own prose.
refusal_stamped_subject() { sed -E "s/^.*produces subject '(.*)', which lkml-fleet-status\\.sh.*/\\1/" <<<"$1"; }

rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'unstamped default subject' --send >/dev/null 2>&1
rc_ver_default=$?
check "unstamped subject with no --version exits 0" "0" "$rc_ver_default"
ver_default_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "default (no --version) stamps v1 with the real patch count" \
    "$ver_default_argv" "[PATCH v1 0/2] unstamped default subject"
check "the default-stamped version round-trips through fs_subject_versions" \
    "1" "$(fs_subject_versions "$(ver_argv_subject "$ver_default_argv")")"

rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'a series' --version 3 --send >/dev/null 2>&1
rc_ver_3=$?
check "--version 3 exits 0" "0" "$rc_ver_3"
ver_3_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "--version 3 stamps v3 with the real patch count" \
    "$ver_3_argv" "[PATCH v3 0/2] a series"
check "the v3-stamped subject round-trips through fs_subject_versions" \
    "3" "$(fs_subject_versions "$(ver_argv_subject "$ver_3_argv")")"

# --version must reach `git format-patch -v` too, or the cover subject
# says "v3" while every posted patch reply's own Subject line says
# unversioned "[PATCH i/N]" -- a reviewer reading the patch messages
# (the copy they actually apply) would see a contradiction.
out_ver_patches="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'a series' --version 3 --patches 2>&1)"
rc_ver_patches=$?
check "--version with --patches exits 0" "0" "$rc_ver_patches"
ver_patches_subject="$(patch_subject_at "$out_ver_patches" 2)"
contains "the posted patch reply's own Subject line carries the same version" \
    "$ver_patches_subject" "[PATCH v3"

# Different fixture range (one commit, not two) so the patch count in the
# marker is proven to track the real count rather than a hardcoded "2"
# left over from the range used everywhere else in this file.
rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "topic~1..topic" \
    --from '@author' --to '@lkml-panel' --subject 'single patch subject' --send >/dev/null 2>&1
rc_ver_count=$?
check "single-patch range with default version exits 0" "0" "$rc_ver_count"
ver_count_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "the marker's patch count tracks the real count (1), not a hardcoded one" \
    "$ver_count_argv" "[PATCH v1 0/1] single patch subject"

# The cover's "0/1" is a numbering claim, and `git format-patch` does not
# number a one-commit range on its own -- without -n the sole posted
# patch reply's own Subject would carry no "1/1" to agree with it.
out_single_patches="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "topic~1..topic" \
    --from '@author' --to '@lkml-panel' --subject 'single patch subject' --patches 2>&1)"
rc_single_patches=$?
check "single-patch range with --patches exits 0" "0" "$rc_single_patches"
single_patches_subject="$(patch_subject_at "$out_single_patches" 2)"
contains "the single posted patch reply's own Subject line is numbered 1/1, matching the cover's 0/1" \
    "$single_patches_subject" "1/1"

rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH v2 0/2] a series' --send >/dev/null 2>&1
rc_ver_marked=$?
check "an already-marked subject with no --version exits 0" "0" "$rc_ver_marked"
ver_marked_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "an already-marked subject passes through byte-identical" \
    "$ver_marked_argv" "[PATCH v2 0/2] a series"
n_patch_tokens="$(grep -o -- '\[PATCH' <<<"$ver_marked_argv" | wc -l | tr -d '[:space:]')"
check "an already-marked subject is not double-stamped" "1" "$n_patch_tokens"

# An already-marked subject with a stray "v<digits>" token elsewhere in
# it (here "v3 parser") parses under fs_subject_versions() as two
# distinct versions -- v2 from the marker, v3 from the stray prose
# token -- the exact phantom-round shape the multi-version re-parse
# guard exists to catch. The phantom round it produces on the status
# screen is identical whether this script did the stamping or found
# the subject already marked, so the guard runs -- and refuses -- here
# too, rather than passing a known-ambiguous subject through unchecked.
rm -f -- "$capture_dir/argv"
out_ver_marked_stray="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH v2 0/2] fix the v3 parser' 2>&1)"
rc_ver_marked_stray=$?
if (( rc_ver_marked_stray != 0 )); then
    ok "an already-marked subject with a stray version token is refused"
else
    no "an already-marked subject with a stray version token is refused" "exit 0: $out_ver_marked_stray"
fi
contains "the already-marked-stray refusal names the subject's marker" "$out_ver_marked_stray" "v2"
check "the already-marked-stray subject really parses as BOTH v2 and the stray prose v3" \
    "$(printf '2\n3')" "$(fs_subject_versions '[PATCH v2 0/2] fix the v3 parser')"
if [[ -f "$capture_dir/argv" ]]; then
    no "the already-marked-stray refusal does not send" "argv capture file exists: $(cat "$capture_dir/argv")"
else
    ok "the already-marked-stray refusal does not send"
fi

# An already-marked subject whose own "i/N" disagrees with the range's
# real patch count is refused rather than passed through: sending it
# would leave the Subject claiming 5 patches while the body's
# ${PATCH_COUNT} fill and (now that --version reaches `git format-patch
# -v`) every attached patch's own "i/N" both say 2, a three-way
# contradiction about the size of the series with no warning at all.
out_ver_count_conflict="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH v2 0/5] a series' 2>&1)"
rc_ver_count_conflict=$?
if (( rc_ver_count_conflict != 0 )); then
    ok "a marked subject whose count disagrees with the real range exits non-zero"
else
    no "a marked subject whose count disagrees with the real range exits non-zero" "exit 0: $out_ver_count_conflict"
fi
contains "the count-conflict refusal names the declared count" "$out_ver_count_conflict" "5"
contains "the count-conflict refusal names the real count" "$out_ver_count_conflict" "2"

# A print-only refusal never reaches the "Note: temp files ... are left
# under $tmpdir" line, so nothing tells the caller $tmpdir exists --
# leaving it behind on a refusal (unlike the deliberate leak on the
# print-only success path, above) is a silent leak, not a kept
# artifact. Each refusal below runs with its own empty TMPDIR so the
# directory is unambiguously this invocation's, not a leftover from
# elsewhere in the suite or the host.
leak_check_tmp="$(mktemp -d)"; tmpdirs+=("$leak_check_tmp")
TMPDIR="$leak_check_tmp" PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH v2 0/5] a series' >/dev/null 2>&1
leak_count_conflict="$(find "$leak_check_tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')"
check "the count-conflict refusal does not leak its tempdir" "0" "$leak_count_conflict"

leak_check_tmp2="$(mktemp -d)"; tmpdirs+=("$leak_check_tmp2")
TMPDIR="$leak_check_tmp2" PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH v2 0/2] fix the v3 parser' >/dev/null 2>&1
leak_multi_version="$(find "$leak_check_tmp2" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')"
check "the multi-version refusal does not leak its tempdir" "0" "$leak_multi_version"

# A bare "v2" in prose (no leading "[PATCH ...]" bracket) is not a
# version marker on its own, so it is stamped over like any other
# unmarked subject -- but the stamp this script adds would then make
# lkml-fleet-status.sh's Versions section (which matches "v<digits>"
# anywhere in a Subject) read the resulting thread as BOTH v1 and a
# phantom v2 that never existed. This script's own stamp creates that
# ambiguity, so it is refused rather than sent -- the same
# "two contradictory statements about the field that identifies the
# series" reasoning as the marker-conflict refusal above, arriving by
# a different route.
out_ver_bare="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'fix the v2 parser' 2>&1)"
rc_ver_bare=$?
if (( rc_ver_bare != 0 )); then
    ok "a bare v2 in prose that would stamp as a second version is refused"
else
    no "a bare v2 in prose that would stamp as a second version is refused" "exit 0: $out_ver_bare"
fi
contains "the phantom-version refusal names the stamped subject" \
    "$out_ver_bare" "[PATCH v1 0/2] fix the v2 parser"
check "the phantom-version refusal's subject really parses as BOTH v1 and the phantom prose v2" \
    "$(printf '1\n2')" "$(fs_subject_versions "$(refusal_stamped_subject "$out_ver_bare")")"

# --version does not rescue this: overriding to a number DIFFERENT from
# the stray prose token still leaves that token in place, so the
# stamped subject still parses as two distinct versions and is still
# refused.
out_ver_bare_override="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'fix the v2 parser' --version 3 2>&1)"
rc_ver_bare_override=$?
if (( rc_ver_bare_override != 0 )); then
    ok "--version to a number other than the stray prose token is still refused"
else
    no "--version to a number other than the stray prose token is still refused" "exit 0: $out_ver_bare_override"
fi
check "the override refusal's subject really parses as BOTH v3 and the phantom prose v2" \
    "$(printf '2\n3')" "$(fs_subject_versions "$(refusal_stamped_subject "$out_ver_bare_override")")"

# The one case where a stray prose token is harmless: --version given
# the SAME number the prose already contains stamps to a subject with
# only ONE distinct version, so it is allowed. This is the boundary a
# careless "refuse if any other v<digits> token exists" implementation
# gets wrong -- the rule keys on distinct version COUNT, not on whether
# a second token merely exists.
rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'the v2 rewrite' --version 2 --send >/dev/null 2>&1
rc_ver_bare_matching=$?
check "--version matching the stray prose token exits 0" "0" "$rc_ver_bare_matching"
ver_bare_matching_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "the stamp matches the stray token" \
    "$ver_bare_matching_argv" "[PATCH v2 0/2] the v2 rewrite"
check "the matching-token subject round-trips as exactly one version" \
    "2" "$(fs_subject_versions "$(ver_argv_subject "$ver_bare_matching_argv")")"

# --allow-ambiguous-version is the escape hatch for a stray token that
# cannot be reworded away because it names something else entirely (a
# subsystem, an upstream tag) -- proven here with a prose token whose
# number differs from the stamped version, the exact case that has no
# other way through. It downgrades the refusal to a Warning and lets
# the send proceed with the known-ambiguous subject intact.
rm -f -- "$capture_dir/argv"
out_ver_allow_ambiguous="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'media: v4l2: fix capture' \
    --allow-ambiguous-version --send 2>&1)"
rc_ver_allow_ambiguous=$?
check "--allow-ambiguous-version on a non-rewordable subsystem token exits 0" "0" "$rc_ver_allow_ambiguous"
contains "--allow-ambiguous-version prints a Warning, not an Error" \
    "$out_ver_allow_ambiguous" "Warning:"
ver_allow_ambiguous_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "--allow-ambiguous-version still stamps the real version" \
    "$ver_allow_ambiguous_argv" "[PATCH v1 0/2] media: v4l2: fix capture"
check "the allowed subject really parses as two distinct versions (the ambiguity is real, not sidestepped)" \
    "$(printf '1\n4')" "$(fs_subject_versions "$(ver_argv_subject "$ver_allow_ambiguous_argv")")"

# The same escape hatch on an already-marked subject: the Warning wording
# differs (no stamping happened this run) but the send still proceeds.
rm -f -- "$capture_dir/argv"
out_ver_allow_ambiguous_marked="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH v2 0/2] fix the v3 parser' \
    --allow-ambiguous-version --send 2>&1)"
rc_ver_allow_ambiguous_marked=$?
check "--allow-ambiguous-version on an already-marked subject exits 0" "0" "$rc_ver_allow_ambiguous_marked"
contains "--allow-ambiguous-version on an already-marked subject prints a Warning, not an Error" \
    "$out_ver_allow_ambiguous_marked" "Warning:"
ver_allow_ambiguous_marked_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "--allow-ambiguous-version passes the already-marked subject through byte-identical" \
    "$ver_allow_ambiguous_marked_argv" "[PATCH v2 0/2] fix the v3 parser"

# Without the flag, the same subjects are still refused -- the escape
# hatch is opt-in, not a loosening of the default.
out_ver_ambiguous_no_flag="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'media: v4l2: fix capture' 2>&1)"
rc_ver_ambiguous_no_flag=$?
if (( rc_ver_ambiguous_no_flag != 0 )); then
    ok "a non-rewordable subsystem token is still refused without --allow-ambiguous-version"
else
    no "a non-rewordable subsystem token is still refused without --allow-ambiguous-version" "exit 0: $out_ver_ambiguous_no_flag"
fi
contains "the refusal without the flag mentions --allow-ambiguous-version" \
    "$out_ver_ambiguous_no_flag" "--allow-ambiguous-version"

# An already-bracketed but unversioned subject (single-patch.md's
# documented ${SUBJECT} form) must not be double-stamped: the old
# bracket is replaced, not nested inside a new one.
rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH] fix the thing' --send >/dev/null 2>&1
rc_ver_bare_bracket=$?
check "an unversioned [PATCH] subject exits 0" "0" "$rc_ver_bare_bracket"
ver_bare_bracket_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "an unversioned [PATCH] bracket is replaced with a real stamp, not nested" \
    "$ver_bare_bracket_argv" "[PATCH v1 0/2] fix the thing"
n_patch_tokens_bracket="$(grep -o -- '\[PATCH' <<<"$ver_bare_bracket_argv" | wc -l | tr -d '[:space:]')"
check "an unversioned [PATCH] subject is not double-stamped" "1" "$n_patch_tokens_bracket"

# An unversioned bracket that carries a qualifier -- "RFC PATCH",
# "RESEND PATCH", "PATCH net-next" -- must keep that qualifier when
# stamped, not have its whole bracket thrown away: an RFC round one
# that lost its RFC tag would read to the panel as a merge-ready
# series. The stale "0/5" declared count is also expected to be
# replaced by the real count (2), not left alongside it.
rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[RFC PATCH 0/5] a series' --send >/dev/null 2>&1
rc_ver_unversioned_rfc=$?
check "an unversioned [RFC PATCH ...] subject exits 0" "0" "$rc_ver_unversioned_rfc"
ver_unversioned_rfc_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "an unversioned [RFC PATCH ...] subject keeps its RFC tag when stamped" \
    "$ver_unversioned_rfc_argv" "[RFC PATCH v1 0/2] a series"
n_patch_tokens_unversioned_rfc="$(grep -o -- 'PATCH' <<<"$ver_unversioned_rfc_argv" | wc -l | tr -d '[:space:]')"
check "an unversioned [RFC PATCH ...] subject is not double-stamped" "1" "$n_patch_tokens_unversioned_rfc"

rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[RESEND PATCH 0/2] a series' --send >/dev/null 2>&1
rc_ver_unversioned_resend=$?
check "an unversioned [RESEND PATCH ...] subject exits 0" "0" "$rc_ver_unversioned_resend"
ver_unversioned_resend_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "an unversioned [RESEND PATCH ...] subject keeps its RESEND tag when stamped" \
    "$ver_unversioned_resend_argv" "[RESEND PATCH v1 0/2] a series"

rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH net-next 0/2] a series' --send >/dev/null 2>&1
rc_ver_unversioned_subsystem=$?
check "an unversioned [PATCH net-next ...] subject exits 0" "0" "$rc_ver_unversioned_subsystem"
ver_unversioned_subsystem_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "an unversioned [PATCH net-next ...] subject keeps its subsystem tag when stamped" \
    "$ver_unversioned_subsystem_argv" "[PATCH v1 net-next 0/2] a series"

out_ver_conflict="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[PATCH v2 0/5] a series' --version 4 2>&1)"
rc_ver_conflict=$?
if (( rc_ver_conflict != 0 )); then ok "--version plus an already-marked subject exits non-zero"; else no "--version plus an already-marked subject exits non-zero" "exit 0: $out_ver_conflict"; fi
contains "the conflict refusal names the given --version value" "$out_ver_conflict" "--version 4"
contains "the conflict refusal names the marker found in the subject" "$out_ver_conflict" "v2"

# A leading bracket that carries a qualifier before the word PATCH --
# "[RFC PATCH v2 0/5]", "[RESEND PATCH v3 0/5]" -- is the common
# versioned-series form on a real list, and must be recognised as an
# existing marker the same as a bare "[PATCH v2 0/5]": anchoring on
# "^\[PATCH" alone missed these, letting them fall through as unmarked
# and get a second, contradictory version stamped in front.
rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[RFC PATCH v2 0/2] a series' --send >/dev/null 2>&1
rc_ver_rfc=$?
check "an [RFC PATCH v2 ...] subject exits 0" "0" "$rc_ver_rfc"
ver_rfc_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "an [RFC PATCH v2 ...] subject passes through byte-identical" \
    "$ver_rfc_argv" "[RFC PATCH v2 0/2] a series"
n_patch_tokens_rfc="$(grep -o -- 'PATCH' <<<"$ver_rfc_argv" | wc -l | tr -d '[:space:]')"
check "an [RFC PATCH v2 ...] subject is not double-stamped" "1" "$n_patch_tokens_rfc"

rm -f -- "$capture_dir/argv"
PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" STUB_CAPTURE_DIR="$capture_dir" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[RESEND PATCH v3 0/2] a series' --send >/dev/null 2>&1
rc_ver_resend=$?
check "a [RESEND PATCH v3 ...] subject exits 0" "0" "$rc_ver_resend"
ver_resend_argv="$(cat "$capture_dir/argv" 2>/dev/null)"
contains "a [RESEND PATCH v3 ...] subject passes through byte-identical" \
    "$ver_resend_argv" "[RESEND PATCH v3 0/2] a series"

out_ver_rfc_conflict="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject '[RFC PATCH v2 0/5] a series' --version 4 2>&1)"
rc_ver_rfc_conflict=$?
if (( rc_ver_rfc_conflict != 0 )); then
    ok "--version plus an already-marked [RFC PATCH ...] subject exits non-zero"
else
    no "--version plus an already-marked [RFC PATCH ...] subject exits non-zero" "exit 0: $out_ver_rfc_conflict"
fi
contains "the [RFC PATCH ...] conflict refusal names the marker found in the subject" "$out_ver_rfc_conflict" "v2"

for bad_version in 0 -1 abc ''; do
    out_ver_bad="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "master...topic" \
        --from '@author' --to '@lkml-panel' --subject 'a series' --version "$bad_version" 2>&1)"
    rc_ver_bad=$?
    if (( rc_ver_bad != 0 )); then
        ok "--version '$bad_version' exits non-zero"
    else
        no "--version '$bad_version' exits non-zero" "exit 0: $out_ver_bad"
    fi
    contains "--version '$bad_version' names the validation problem" "$out_ver_bad" "positive integer"
done

# print-only mode shell-quotes the composed command with printf '%q', so
# the space-separated subject shows up backslash-escaped here the same
# way the "printed command carries the subject" assertion above expects.
contains "--ci-first's wave-one mail carries the v1 stamp (it starts the thread)" \
    "$out_ci_first" "PATCH\\ v1\\ 0/2\\]\\ subj"

subject_body_template="$template_dir/subject-in-body.md"
printf '%s\n' 'Subject-in-body: ${SUBJECT}' '' 'Base: ${BASE}' > "$subject_body_template"
out_ver_body="$(PATH="$stub_bin:$PATH" FORK_SANDBOX_MAIL_ROOT="$mail_root" \
    "$kickoff" "$project_dir" "master...topic" \
    --from '@author' --to '@lkml-panel' --subject 'subject in the body test' \
    --template "$subject_body_template" 2>&1)"
rc_ver_body=$?
check "a template with \${SUBJECT} in its body exits 0" "0" "$rc_ver_body"
ver_body_file="$(printf '%s' "$out_ver_body" | grep -o -- '--body [^ ]*' | awk '{print $2}')"
ver_body_text="$([[ -f "$ver_body_file" ]] && cat "$ver_body_file")"
contains "the body's \${SUBJECT} fill carries the same stamped subject as the header" \
    "$ver_body_text" "Subject-in-body: [PATCH v1 0/2] subject in the body test"

printf '\n== Sign-off convention: tag-form contract round-trips through the real fs_body_tags ==\n'
# Pull lkml-fleet-status.sh's own fs_body_tags() definition out of the
# script text and eval it into this shell, the same "pull the real
# function rather than hand-copy its behavior" technique used for
# fill() and fs_subject_versions() above -- the point is that the
# Sign-off convention paragraph's claims and the SHIPPED PARSER cannot
# silently drift apart (CLAUDE.md's "false green" hazard).
eval "$(sed -n '/^fs_body_tags() {/,/^}/p' "$repo_dir/scripts/lkml-fleet-status.sh")"

# fs_body_tags reads a message FILE: header lines, a blank line, then
# the body. A minimal fixture skips the header entirely -- the leading
# blank line alone is what flips awk's `body` flag.
body_tag_dir="$(mktemp -d)"; tmpdirs+=("$body_tag_dir")
body_tag_file() {
    local f
    f="$(mktemp "$body_tag_dir/msg-XXXXXX")"
    printf '\n%s\n' "$1" > "$f"
    printf '%s' "$f"
}

contains "a colon-form trailer starting its own line IS counted" \
    "$(fs_body_tags "$(body_tag_file 'Reviewed-by: Core')")" "Reviewed-by"

case "$(fs_body_tags "$(body_tag_file 'Reviewed-by Core')")" in
    *Reviewed-by*) no "the same trailer without the colon is NOT counted" "tag registered with no colon" ;;
    *) ok "the same trailer without the colon is NOT counted" ;;
esac

case "$(fs_body_tags "$(body_tag_file 'Signed -- Reviewed-by: Core')")" in
    *Reviewed-by*) no "the same trailer embedded mid-prose is NOT counted" "tag registered from mid-prose" ;;
    *) ok "the same trailer embedded mid-prose is NOT counted" ;;
esac

# The Sign-off convention paragraph says a trailer "must start its own
# line at the left margin, with no leading whitespace" -- this pins that
# an indented trailer (e.g. under a bullet, or the two-space habit these
# markdown persona files otherwise encourage) is NOT counted, the same
# way the doc now says it isn't. Before the paragraph named the left
# margin explicitly, this case was undocumented and untested even though
# the parser already dropped it.
case "$(fs_body_tags "$(body_tag_file '  Reviewed-by: Core')")" in
    *Reviewed-by*) no "an indented colon-form trailer is NOT counted" "tag registered from an indented line" ;;
    *) ok "an indented colon-form trailer is NOT counted" ;;
esac

case "$(fs_body_tags "$(body_tag_file '  NAK')")" in
    *NAK*) no "an indented bare verdict is NOT counted" "tag registered from an indented line" ;;
    *) ok "an indented bare verdict is NOT counted" ;;
esac

contains "a bare verdict on the last line IS counted" \
    "$(fs_body_tags "$(body_tag_file "$(printf 'Some findings here.\nNAK')")")" "NAK"

contains "a bare verdict on the first line IS counted" \
    "$(fs_body_tags "$(body_tag_file "$(printf 'NAK\nMore detail follows.')")")" "NAK"

case "$(fs_body_tags "$(body_tag_file "$(printf 'Some findings.\nNAK\nMore detail follows.')")")" in
    *NAK*) no "a verdict mid-body is NOT counted" "tag registered from a middle line" ;;
    *) ok "a verdict mid-body is NOT counted" ;;
esac

printf '\n== Sign-off convention blocks stay byte-identical across all three kickoff templates ==\n'
extract_signoff_block() {
    awk '/^## Sign-off convention$/{ f = 1; print; next }
         f && /^## / { exit }
         f { print }' "$1"
}
so_series="$(extract_signoff_block "$repo_dir/fleet/kickoffs/series-review.md")"
so_single="$(extract_signoff_block "$repo_dir/fleet/kickoffs/single-patch.md")"
so_focused="$(extract_signoff_block "$repo_dir/fleet/kickoffs/focused-review.md")"

# The byte-identical comparisons below pass on three empty strings just
# as readily as on three matching blocks -- guard non-emptiness (so a
# renamed or deleted "## Sign-off convention" heading fails loudly) and
# pin the tag-form paragraph's normative sentences by name (so deleting
# the paragraph itself, leaving the heading and bullets intact, fails
# too).
for pair in "series-review:$so_series" "single-patch:$so_single" "focused-review:$so_focused"; do
    so_name="${pair%%:*}" so_val="${pair#*:}"
    if [[ -n "$so_val" ]]; then
        ok "$so_name's Sign-off convention block is non-empty"
    else
        no "$so_name's Sign-off convention block is non-empty" "no '## Sign-off convention' heading found"
    fi
done
contains "the Sign-off convention block states the colon requirement on -by trailers" \
    "$so_series" "The colon after the three"
contains "the Sign-off convention block states the left-margin requirement for trailers" \
    "$so_series" "left margin, with no leading whitespace"
contains "the Sign-off convention block states the first-or-last-line rule for bare verdicts" \
    "$so_series" "first or last non-empty, non-quoted line"

if [[ "$so_series" == "$so_single" ]]; then
    ok "series-review and single-patch Sign-off convention blocks are byte-identical"
else
    no "series-review and single-patch Sign-off convention blocks are byte-identical" "blocks diverge"
fi
if [[ "$so_series" == "$so_focused" ]]; then
    ok "series-review and focused-review Sign-off convention blocks are byte-identical"
else
    no "series-review and focused-review Sign-off convention blocks are byte-identical" "blocks diverge"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
