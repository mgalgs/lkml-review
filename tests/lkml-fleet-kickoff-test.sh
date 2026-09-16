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
    "$kickoff" "$project_dir" "topic~1..topic" \
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

printf '\n== --attach with a range that produces no commits is a hard error ==\n'
out_empty_attach="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "HEAD..HEAD" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --attach 2>&1)"
rc_empty_attach=$?
if (( rc_empty_attach != 0 )); then ok "--attach with an empty range exits non-zero"; else no "--attach with an empty range exits non-zero" "exit 0: $out_empty_attach"; fi
contains "--attach with an empty range names the problem" "$out_empty_attach" "produced no patches"

printf '\n== branch-name variant (no --attach) with a range that produces no commits is also a hard error ==\n'
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

printf '\n== --attach also refuses a range whose right side is not a branch, since the template always offers the checkout fallback too ==\n'
out_bad_branch_attach="$(PATH="$stub_bin:$PATH" "$kickoff" "$project_dir" "HEAD~1..HEAD" \
    --from '@author' --to '@lkml-panel' --subject 'subj' --attach \
    --template "$repo_dir/fleet/kickoffs/single-patch.md" 2>&1)"
rc_bad_branch_attach=$?
if (( rc_bad_branch_attach != 0 )); then ok "--attach with a non-branch range exits non-zero"; else no "--attach with a non-branch range exits non-zero" "exit 0: $out_bad_branch_attach"; fi
contains "--attach with a non-branch range names the problem" "$out_bad_branch_attach" "does not resolve to a checkout-able branch name"

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
    --template "$focused_template" 2>&1)"
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
    --template "$focused_template" --send 2>&1)"
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
contains "series-review Next version keeps the inline-copy convention" "$series_tail" "inline copy is the review copy"
single_tail="$(sed -n '/^## Next version/,$p' "$repo_dir/fleet/kickoffs/single-patch.md")"
contains "single-patch Next version keeps the wake no-attachment guard" "$single_tail" "a wake's reply cannot"
contains "single-patch Next version keeps the inline-copy convention" "$single_tail" "inline copy is the review copy"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
