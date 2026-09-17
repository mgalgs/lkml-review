#!/usr/bin/env bash
# install-test.sh — Exercise install.sh against a controlled HOME and a
# throwaway copy of the checkout. No link ever lands in the operator's
# real $HOME: every install run gets HOME pointed at a temp dir, and the
# drift cases run against a temp copy of the repo so the real checkout's
# scripts/ is never written.
#
# Usage: tests/install-test.sh
#
# Covers:
#   - porcelain gets linked into $HOME/.claude/scripts, plumbing does not.
#   - the lkml-mode skill lands as a symlink in all three skill farms.
#   - the fail-closed drift check catches a file in scripts/ that is in
#     neither list, and a listed name that does not exist in scripts/.
#   - a drift refusal links nothing: the install stops before creating
#     any directory.
#   - --check exits 0 when the config files are missing, and names them;
#     an orphaned pre-move file at the old path is called out by name.
#   - a link target that exists as a real directory is refused by name,
#     not nested into (ln -sfn would link inside it and report success);
#     the same install links cleanly once the directory is gone.
#   - re-running the install is idempotent.
#   - the porcelain and plumbing lists this test keeps as its own copy
#     agree with install.sh's, are disjoint, and together cover exactly
#     the files in scripts/ (the copies are independent on purpose;
#     only the agreement is checked).

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
install="$repo_dir/install.sh"

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

# Read one of install.sh's script lists straight out of its source by
# parsing the array literal. install.sh is neither executed nor
# sourced: running it would symlink into the real $HOME/.claude/scripts,
# and sourcing it is safe only while the arrays happen to come before
# any work -- an invariant a later edit could break. The literal is
# plain names, one per line, until the closing paren.
install_list() {
    local var="$1"
    awk -v v="$var" '
        !inarr && $0 ~ "^" v "=\\($" { inarr = 1; next }
        inarr && /^\)/ { exit }
        inarr {
            gsub(/^[[:space:]]+/, ""); gsub(/[[:space:]]+$/, "")
            if ($0 != "") print
        }
    ' "$install"
}

# Set equality over two newline-separated sorted name lists. The
# failure names which side holds which extra, so a drift is readable
# without diffing the two files by hand.
assert_set_eq() {
    local label="$1" left="$2" right="$3"
    local only_left only_right
    only_left="$(comm -23 <(printf '%s\n' "$left") <(printf '%s\n' "$right") | tr '\n' ' ')"
    only_right="$(comm -13 <(printf '%s\n' "$left") <(printf '%s\n' "$right") | tr '\n' ' ')"
    if [[ -z "$only_left" && -z "$only_right" ]]; then
        ok "$label"
    else
        no "$label" "only in the first: ${only_left:-none}; only in the second: ${only_right:-none}"
    fi
}

work="$(mktemp -d)"; tmpdirs+=("$work")
home_dir="$work/home"; mkdir -p -- "$home_dir"

PORCELAIN=(
    lkml-cover.sh
    lkml-fleet.sh
    lkml-fleet-kickoff.sh
    lkml-fleet-status.sh
    lkml-forklift.sh
    lkml-mailbox.sh
    lkml-render.py
    lkml-revise.sh
    lkml-round.sh
    lkml-series.sh
    lkml-status.sh
    lkml-summarize.sh
)
PLUMBING=(
    lkml-seats-parse.py
    lkml-seats-resolve
)
FARMS=(
    "$home_dir/.claude/skills"
    "$home_dir/.agents/skills"
    "$home_dir/.pi/agent/skills"
)

printf '\n== the lists here agree with install.sh ==\n'
# This test keeps its own copy of install.sh's two lists, deliberately:
# importing them would make every later check a tautology. The price
# is two copies of one fact, so the copies are pinned here -- a name
# moved between lists in install.sh without the matching move here
# fails this section instead of passing over the old classification.
inst_p="$(install_list PORCELAIN | sort)"
inst_l="$(install_list PLUMBING | sort)"
test_p="$(printf '%s\n' "${PORCELAIN[@]}" | sort)"
test_l="$(printf '%s\n' "${PLUMBING[@]}" | sort)"
assert_set_eq "porcelain: install.sh and this test agree" "$inst_p" "$test_p"
assert_set_eq "plumbing: install.sh and this test agree" "$inst_l" "$test_l"
both="$(comm -12 <(printf '%s\n' "$inst_p") <(printf '%s\n' "$inst_l") | tr '\n' ' ')"
if [[ -z "$both" ]]; then
    ok "install.sh: porcelain and plumbing are disjoint"
else
    no "install.sh: porcelain and plumbing are disjoint" "in both lists: $both"
fi
list_union="$(printf '%s\n' "$inst_p" "$inst_l" | sort -u)"
scripts_now=""
for f in "$repo_dir/scripts"/*; do
    [[ -f "$f" ]] || continue
    scripts_now+="${f##*/}"$'\n'
done
scripts_now="$(printf '%s' "$scripts_now" | sort)"
# Same file test install.sh's fail-closed check uses: a regular file,
# or a symlink to one.
assert_set_eq "union of install.sh's lists is exactly scripts/" "$list_union" "$scripts_now"

printf '\n== install: porcelain linked, plumbing not ==\n'
OUT="$(HOME="$home_dir" "$install" 2>&1)"; RC=$?
check "install exits 0" "0" "$RC"
for name in "${PORCELAIN[@]}"; do
    target="$home_dir/.claude/scripts/$name"
    if [[ -L "$target" ]]; then ok "porcelain linked: $name"; else no "porcelain linked: $name" "not a symlink"; fi
    check "porcelain resolves to the checkout: $name" \
        "$repo_dir/scripts/$name" "$(readlink -f -- "$target" 2>/dev/null || echo gone)"
done
for name in "${PLUMBING[@]}"; do
    if [[ -e "$home_dir/.claude/scripts/$name" || -L "$home_dir/.claude/scripts/$name" ]]; then
        no "plumbing NOT linked: $name" "present in the scripts dir"
    else
        ok "plumbing NOT linked: $name"
    fi
done

printf '\n== install: the skill lands in all three farms ==\n'
for farm in "${FARMS[@]}"; do
    link="$farm/lkml-mode"
    if [[ -L "$link" ]]; then ok "skill linked in $farm"; else no "skill linked in $farm" "not a symlink"; fi
    check "skill resolves to the checkout: $farm" \
        "$repo_dir/skills/lkml-mode" "$(readlink -f -- "$link" 2>/dev/null || echo gone)"
done

printf '\n== install: says something useful about PATH ==\n'
# The controlled HOME's scripts dir is a temp dir, so it cannot already
# be on PATH: the install must print the export line instead of staying
# silent.
contains "prints the export PATH line" "$OUT" "export PATH=\"$home_dir/.claude/scripts:\$PATH\""

printf '\n== drift: a file in scripts/ that is in neither list ==\n'
# A throwaway copy of the checkout, so the real repo is never written.
tmp_repo="$work/drift-unlisted"; mkdir -p -- "$tmp_repo"
cp -- "$install" "$tmp_repo/install.sh"
cp -r -- "$repo_dir/scripts" "$tmp_repo/scripts"
cp -r -- "$repo_dir/skills" "$tmp_repo/skills"
chmod +x -- "$tmp_repo/install.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$tmp_repo/scripts/lkml-newtool.sh"
home2="$work/home-drift1"; mkdir -p -- "$home2"
OUT="$(HOME="$home2" "$tmp_repo/install.sh" 2>&1)"; RC=$?
if (( RC != 0 )); then ok "unlisted file: exits non-zero"; else no "unlisted file: exits non-zero" "exit 0"; fi
contains "unlisted file: names the offending file" "$OUT" "lkml-newtool.sh"
contains "unlisted file: says it is in neither list" "$OUT" "neither list"
if [[ -e "$home2/.claude" ]]; then
    no "unlisted file: linked nothing" "$home2/.claude exists"
else
    ok "unlisted file: linked nothing"
fi

printf '\n== drift: a listed name that does not exist ==\n'
tmp_repo2="$work/drift-missing"; mkdir -p -- "$tmp_repo2"
cp -- "$install" "$tmp_repo2/install.sh"
cp -r -- "$repo_dir/scripts" "$tmp_repo2/scripts"
cp -r -- "$repo_dir/skills" "$tmp_repo2/skills"
chmod +x -- "$tmp_repo2/install.sh"
rm -f -- "$tmp_repo2/scripts/lkml-status.sh"
home3="$work/home-drift2"; mkdir -p -- "$home3"
OUT="$(HOME="$home3" "$tmp_repo2/install.sh" 2>&1)"; RC=$?
if (( RC != 0 )); then ok "missing listed name: exits non-zero"; else no "missing listed name: exits non-zero" "exit 0"; fi
contains "missing listed name: names the offending file" "$OUT" "lkml-status.sh"
contains "missing listed name: says it is missing from scripts/" "$OUT" "missing from scripts/"
if [[ -e "$home3/.claude" ]]; then
    no "missing listed name: linked nothing" "$home3/.claude exists"
else
    ok "missing listed name: linked nothing"
fi

printf '\n== --check: exits 0 when config files are missing ==\n'
# home4 has a fresh, empty .config: both config files are absent.
home4="$work/home-check"; mkdir -p -- "$home4/.config"
OUT="$(HOME="$home4" "$install" --check 2>&1)"; RC=$?
check "--check with missing config exits 0" "0" "$RC"
contains "--check names the missing seats file" "$OUT" "$home4/.config/lkml/seats.yaml"
contains "--check names the missing summarize env" "$OUT" "$home4/.config/lkml/summarize.env"
contains "--check reports the scripts dir is not on PATH" "$OUT" "$home4/.claude/scripts is not on PATH"
# An orphaned pre-move file at the old fork-sandbox path is called out
# by name, not just reported as a plain miss.
mkdir -p -- "$home4/.config/fork-sandbox"
: > "$home4/.config/fork-sandbox/lkml-seats.yaml"
: > "$home4/.config/fork-sandbox/lkml-summarize.env"
OUT="$(HOME="$home4" "$install" --check 2>&1)"; RC=$?
check "--check with an orphaned old file exits 0" "0" "$RC"
contains "--check names the orphaned old seats file" "$OUT" "$home4/.config/fork-sandbox/lkml-seats.yaml"
contains "--check names the orphaned old summarize env" "$OUT" "$home4/.config/fork-sandbox/lkml-summarize.env"
contains "--check says the orphaned old file is not read" "$OUT" "not read"
rm -rf -- "$home4/.config/fork-sandbox"
OUT="$(HOME="$home4" "$install" --check 2>&1)"; RC=$?
check "--check without the old files stays plain-miss" "0" "$RC"
case "$OUT" in
    *"fork-sandbox"*) no "--check without old files does not mention the old path" "$OUT" ;;
    *) ok "--check without old files does not mention the old path" ;;
esac
# And when they exist, it says so and still exits 0.
mkdir -p -- "$home4/.config/lkml"
: > "$home4/.config/lkml/seats.yaml"
: > "$home4/.config/lkml/summarize.env"
OUT="$(HOME="$home4" "$install" --check 2>&1)"; RC=$?
check "--check with present config exits 0" "0" "$RC"
contains "--check reports the seats file ok" "$OUT" "ok       $home4/.config/lkml/seats.yaml"
contains "--check reports the summarize env ok" "$OUT" "ok       $home4/.config/lkml/summarize.env"

printf '\n== install: a pre-existing real directory at a link target is refused ==\n'
# The failure state: a hand-copied skill directory (and a stray
# directory at a scripts target) instead of symlinks. ln -sfn would
# create the links INSIDE those directories and report success, so the
# install must refuse before linking anything, name the offender, and
# leave the stale contents untouched.
home5="$work/home-dirtarget"
mkdir -p -- "$home5/.claude/scripts/lkml-round.sh" "$home5/.claude/skills/lkml-mode"
printf 'stale hand-copied skill\n' > "$home5/.claude/skills/lkml-mode/SKILL.md"
OUT="$(HOME="$home5" "$install" 2>&1)"; RC=$?
if (( RC != 0 )); then ok "directory target: exits non-zero"; else no "directory target: exits non-zero" "exit 0"; fi
contains "directory target: names the scripts directory" "$OUT" "$home5/.claude/scripts/lkml-round.sh"
contains "directory target: says it is a real directory" "$OUT" "real directory"
check "directory target: the stale skill file is untouched" \
    "stale hand-copied skill" "$(cat "$home5/.claude/skills/lkml-mode/SKILL.md" 2>/dev/null)"
if [[ -e "$home5/.claude/skills/lkml-mode/lkml-mode" ]]; then
    no "directory target: nothing was nested inside" "$home5/.claude/skills/lkml-mode/lkml-mode exists"
else
    ok "directory target: nothing was nested inside"
fi
if [[ -e "$home5/.claude/skills/lkml-mode" && -L "$home5/.claude/skills/lkml-mode" ]]; then
    no "directory target: no link was created" "a symlink now exists"
else
    ok "directory target: no link was created"
fi
# Moving the first offender aside gets the SECOND refusal (the farm
# target), so both call sites of the guard are covered by the same run.
rm -rf -- "$home5/.claude/scripts/lkml-round.sh"
OUT="$(HOME="$home5" "$install" 2>&1)"; RC=$?
if (( RC != 0 )); then ok "second directory target: still refuses"; else no "second directory target: still refuses" "exit 0"; fi
contains "second directory target: names the farm directory" "$OUT" "$home5/.claude/skills/lkml-mode"
# Once both directories are gone, the very same run installs cleanly.
rm -rf -- "$home5/.claude/skills/lkml-mode"
OUT="$(HOME="$home5" "$install" 2>&1)"; RC=$?
check "after moving the directories aside: install exits 0" "0" "$RC"
check "after moving the directories aside: the scripts link resolves" \
    "$repo_dir/scripts/lkml-round.sh" "$(readlink -f -- "$home5/.claude/scripts/lkml-round.sh" 2>/dev/null || echo gone)"
for farm in "${FARMS[@]}"; do
    check "after moving the directories aside: skill resolves in $farm" \
        "$repo_dir/skills/lkml-mode" "$(readlink -f -- "$farm/lkml-mode" 2>/dev/null || echo gone)"
done

printf '\n== re-running the install is idempotent ==\n'
OUT="$(HOME="$home_dir" "$install" 2>&1)"; RC=$?
check "second install run exits 0" "0" "$RC"
n_porc=$(find "$home_dir/.claude/scripts" -maxdepth 1 -type l | wc -l | tr -d '[:space:]')
check "second run leaves exactly the porcelain links" "${#PORCELAIN[@]}" "$n_porc"
check "second run: lkml-round.sh still resolves to the checkout" \
    "$repo_dir/scripts/lkml-round.sh" "$(readlink -f -- "$home_dir/.claude/scripts/lkml-round.sh")"
for farm in "${FARMS[@]}"; do
    check "second run: skill still resolves in $farm" \
        "$repo_dir/skills/lkml-mode" "$(readlink -f -- "$farm/lkml-mode")"
done

printf '\n== --help ==\n'
h_out="$("$install" --help 2>&1)"; h_rc=$?
if (( h_rc == 0 )); then ok "--help alone exits 0"; else no "--help alone exits 0" "exit $h_rc: $h_out"; fi
contains "--help prints the header usage" "$h_out" "install.sh — Install lkml-review onto this machine."

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
