#!/usr/bin/env bash
# lkml-pr-tier-test.sh — Exercise scripts/lkml-pr-tier.py against
# throwaway git repositories built here with invented paths, and tiers
# files written here (LKML_TIERS_FILE points at them; HOME is a temp dir,
# so no real ~/.config/lkml/tiers.yaml can leak in).
#
# Usage: tests/lkml-pr-tier-test.sh

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
tier_py="$repo_dir/scripts/lkml-pr-tier.py"
shipped="$repo_dir/fleet/tiers.yaml"

pass=0; fail=0; tmpdirs=()
stub_pid=""
cleanup() { [[ -n "$stub_pid" ]] && kill "$stub_pid" 2>/dev/null; local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
contains() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *) no "$1" "'$3' not found in: $2" ;;
    esac
}
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi
}

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed; this suite reads the JSON output with it."
    exit 0
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "SKIP: PyYAML not installed; the tiers file parser needs it."
    exit 0
fi

work="$(mktemp -d)"; tmpdirs+=("$work")
home_dir="$work/home"; mkdir -p -- "$home_dir"
export HOME="$home_dir"
unset LKML_TIERS_FILE

# -- fixtures ---------------------------------------------------------

cat > "$work/tiers.yaml" <<'YAML'
default-tier: standard
tiers:
  quick:
    roster: [core, tests]
    needs-env: false
    budget: 16
  standard:
    roster: [core, tests, architecture]
    needs-env: false
    budget: 40
    extra-seats: 1
  full:
    roster: [architecture, core, docs, newcomer, security, tests]
    needs-env: true
    budget: 96
labels:
  skip: [lkml-skip, Site-Skip]
  full: [lkml-full, lkml, site-full]
docs-paths: ["docs/**", "**/*.md"]
tests-paths: ["tests/**"]
dependency-manifests: [package.json, "requirements*.txt"]
rules:
  - name: docs-only
    docs-only: true
    tier: quick
  - name: tests-only
    tests-only: true
    tier: quick
  - name: migrations
    paths: ["**/migrations/**"]
    tier: full
  - name: big-change
    min-lines: 400
    tier: full
  - name: new-dep
    new-dependency: true
    tier: full
    ambiguous: true
  - name: auth
    paths: ["src/auth/**"]
    add-seat: security
  - name: wire
    paths: ["src/wire/**"]
    add-seat: newcomer
  - name: docs-touched
    paths: ["docs/**"]
    add-seat: docs
YAML
export LKML_TIERS_FILE="$work/tiers.yaml"

# A tiers file head that is valid on its own; error cases append to it.
cfg_head() {
    cat <<'YAML'
default-tier: standard
tiers:
  quick: {roster: [core], budget: 1}
  standard: {roster: [core, tests], budget: 2}
  full: {roster: [core, tests, docs], budget: 3}
YAML
}

git_q() { git -c user.name=Tester -c user.email=t@example.com "$@"; }

# new_repo <name>: a repo with a base commit on main, topic checked out.
new_repo() {
    local r="$work/$1"
    mkdir -p -- "$r"
    git_q -C "$r" init -q -b main
    printf 'base\n' > "$r/base.txt"
    git_q -C "$r" add -A
    git_q -C "$r" commit -qm base
    git_q -C "$r" checkout -qb topic
    printf '%s' "$r"
}
# add_commit <repo> <path> <lines> [msg]: write <lines> lines, commit.
add_commit() {
    local r="$1" p="$2" n="$3" m="${4:-change $2}"
    mkdir -p -- "$(dirname "$r/$p")"
    seq 1 "$n" | sed "s|^|$p |" > "$r/$p"
    git_q -C "$r" add -A
    git_q -C "$r" commit -qm "$m"
}

out=""; err=""; rc=0
# meta <json>: write metadata file, echo its path.
meta() { printf '%s' "$1" > "$work/meta.json"; printf '%s' "$work/meta.json"; }
# tier <repo> <meta-json> [extra args...]
tier() {
    local r="$1" m="$2"; shift 2
    out="$(python3 "$tier_py" "$r" main..topic --meta "$(meta "$m")" "$@" 2> "$work/err")"
    rc=$?
    err="$(cat "$work/err")"
}
j() { jq -r "$1" <<<"$out"; }
jc() { jq -c "$1" <<<"$out"; }
EMPTY='{}'

printf '\n== config: missing and invalid files ==\n'
r="$(new_repo cfg)"; add_commit "$r" src/a.txt 3
saved="$LKML_TIERS_FILE"
export LKML_TIERS_FILE="$work/nope.yaml"
tier "$r" "$EMPTY"
check "T1a: missing LKML_TIERS_FILE exits 1" 1 "$rc"
contains "T1a: names the path it wanted" "$err" "$work/nope.yaml"
check "T1a: nothing on stdout" "" "$out"
unset LKML_TIERS_FILE
mkdir -p "$work/emptyhome"
out="$(HOME="$work/emptyhome" python3 "$tier_py" "$r" main..topic --meta "$(meta "$EMPTY")" 2> "$work/err")"; rc=$?; err="$(cat "$work/err")"
check "T1b: no file at the default path exits 1" 1 "$rc"
contains "T1b: names ~/.config/lkml/tiers.yaml under HOME" "$err" "$work/emptyhome/.config/lkml/tiers.yaml"
export LKML_TIERS_FILE="$saved"

bad_cfg() { # <label> <expected-substring> ; config body on stdin
    cat > "$work/bad.yaml"
    export LKML_TIERS_FILE="$work/bad.yaml"
    tier "$r" "$EMPTY"
    check "$1: exits 1" 1 "$rc"
    contains "$1: names the offending key" "$err" "$2"
    check "$1: nothing on stdout" "" "$out"
    export LKML_TIERS_FILE="$saved"
}
bad_cfg "T2a: missing tier" "tiers.full" <<'YAML'
default-tier: quick
tiers:
  quick: {roster: [core], budget: 1}
  standard: {roster: [core], budget: 1}
YAML
{ cfg_head; printf 'rules:\n  - name: x\n    frobnicate: true\n    tier: full\n'; } | bad_cfg "T2b: unknown rule key" "rules[x].frobnicate"
for s in pr-author secretary author; do
    cfg_head | sed "s/^  quick: .*/  quick: {roster: [core, '@$s'], budget: 1}/" | bad_cfg "T2c: roster naming $s" "tiers.quick.roster[1]"
done
{ cfg_head; printf 'rules:\n  - name: x\n    paths: ["a/**"]\n'; } | bad_cfg "T2d: rule with no effect" "has no effect"
{ cfg_head; printf 'default-tier: full\n'; } | bad_cfg "T2e: duplicate YAML key" "duplicate key 'default-tier'"
cfg_head | sed 's/^default-tier: .*/default-tier: huge/' | bad_cfg "T2f: default-tier not a tier" "default-tier"
cfg_head | sed 's/budget: 2/budget: 0/' | bad_cfg "T2g: non-positive budget" "tiers.standard.budget"
{ cfg_head; printf 'rules:\n  - {name: x, paths: ["a"], tier: full}\n  - {name: x, paths: ["b"], tier: full}\n'; } | bad_cfg "T2h: duplicate rule name" "duplicate rule name 'x'"

printf '\n== the shipped example ==\n'
export LKML_TIERS_FILE="$shipped"
r="$(new_repo shipped)"; add_commit "$r" src/wire/a.txt 5
tier "$r" "$EMPTY"
check "T3: shipped fleet/tiers.yaml loads" 0 "$rc"
export LKML_TIERS_FILE="$work/tiers.yaml"
shipped_roster="$(sed -n 's/^PANEL=//p' "$repo_dir/fleet/kickoffs/pr-review.roster" | tr -d '@')"
for t in quick standard full; do
    out_t="$(
        python3 - "$shipped" "$t" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["tiers"][sys.argv[2]]
print(",".join(d["roster"]), d.get("needs-env", False), d["budget"])
PY
    )"
    case "$t" in
        full) check "T3: shipped full roster = pr-review.roster" \
                "$(tr ',' '\n' <<<"$shipped_roster" | sort | tr '\n' ',')" \
                "$(tr ',' '\n' <<<"${out_t%% *}" | sort | tr '\n' ',')"
              check "T3: full needs-env, budget 96" "True 96" "${out_t#* }" ;;
        quick) check "T3: quick: core+tests, no env, 16" "core,tests False 16" "$out_t" ;;
        standard) check "T3: standard: core,tests,architecture, no env, 40" "core,tests,architecture False 40" "$out_t" ;;
    esac
done

printf '\n== rules ==\n'
r="$(new_repo rules)"
add_commit "$r" docs/guide.md 4
add_commit "$r" db/migrations/001.sql 4
{ cfg_head; printf 'rules:\n  - {name: small, max-lines: 20, tier: quick}\n  - {name: migrations, paths: ["**/migrations/**"], tier: full}\n'; } > "$work/hi.yaml"
LKML_TIERS_FILE="$work/hi.yaml" tier "$r" "$EMPTY"
check "T4: highest tier wins (quick and full both match)" full "$(j .tier)"
contains "T4: both rule names reported" "$(jc '[.signals.rules_matched[].name]')" '"small"'
contains "T4: migrations reported too" "$(jc '[.signals.rules_matched[].name]')" '"migrations"'

r="$(new_repo nomatch)"; add_commit "$r" src/core/x.txt 6
tier "$r" "$EMPTY"
check "T5: no rule matches -> default tier" standard "$(j .tier)"
check "T5: default_tier_applied" true "$(j .signals.default_tier_applied)"
check "T5: roster from config" "core,tests,architecture" "$(j '.roster|join(",")')"
check "T5: budget from config" 40 "$(j .budget)"
check "T5: needs_env from config" false "$(j .needs_env)"
sed 's/^default-tier: .*/default-tier: quick/' "$work/tiers.yaml" > "$work/q.yaml"
LKML_TIERS_FILE="$work/q.yaml" tier "$r" "$EMPTY"
check "T5: default tier is config, not code" quick "$(j .tier)"

r="$(new_repo docsonly)"; add_commit "$r" docs/a.md 2; add_commit "$r" README.md 2
tier "$r" "$EMPTY"
check "T6a: docs-only signal" true "$(j .signals.docs_only)"
check "T6a: docs-only -> quick" quick "$(j .tier)"
r="$(new_repo docsmixed)"; add_commit "$r" docs/a.md 2; add_commit "$r" src/x.txt 2
tier "$r" "$EMPTY"
check "T6a: docs plus a source file is not docs-only" false "$(j .signals.docs_only)"
r="$(new_repo testsonly)"; add_commit "$r" tests/a-test.sh 2
tier "$r" "$EMPTY"
check "T6b: tests-only signal" true "$(j .signals.tests_only)"
check "T6b: tests-only -> quick" quick "$(j .tier)"
r="$(new_repo deps)"; add_commit "$r" requirements-dev.txt 2
tier "$r" "$EMPTY"
check "T6c: dependency manifest signal" true "$(j .signals.new_dependency)"
check "T6c: new-dependency -> full" full "$(j .tier)"
check "T6c: ambiguous flag set by the rule" true "$(j .signals.ambiguous)"

r="$(new_repo lines)"; add_commit "$r" src/big.txt 500
tier "$r" "$EMPTY"
check "T7: 500 lines counted" 500 "$(j .signals.lines)"
check "T7: min-lines 400 fires" full "$(j .tier)"
r="$(new_repo binary)"
head -c 4096 /dev/zero > "$r/src.bin"; git_q -C "$r" add -A; git_q -C "$r" commit -qm bin
tier "$r" "$EMPTY"
check "T7: a binary file counts 0 lines" 0 "$(j .signals.lines)"
check "T7: binary-only change does not hit min-lines" standard "$(j .tier)"

cat > "$work/glob.yaml" <<'YAML'
default-tier: quick
tiers:
  quick: {roster: [core], budget: 1}
  standard: {roster: [core, tests], budget: 2}
  full: {roster: [core, tests, docs], budget: 3}
rules:
  - {name: star, paths: ["src/*"], tier: standard}
  - {name: dstar, paths: ["lib/**"], tier: full}
  - {name: md, paths: ["*.md"], add-seat: docs}
YAML
r="$(new_repo glob1)"; add_commit "$r" src/a/b.py 2
LKML_TIERS_FILE="$work/glob.yaml" tier "$r" "$EMPTY"
check "T8: src/* does not match src/a/b.py" quick "$(j .tier)"
r="$(new_repo glob2)"; add_commit "$r" src/b.py 2
LKML_TIERS_FILE="$work/glob.yaml" tier "$r" "$EMPTY"
check "T8: src/* matches src/b.py" standard "$(j .tier)"
r="$(new_repo glob3)"; add_commit "$r" lib/a/b/c.py 2
LKML_TIERS_FILE="$work/glob.yaml" tier "$r" "$EMPTY"
check "T8: lib/** spans directories" full "$(j .tier)"
r="$(new_repo glob4)"; add_commit "$r" docs/x.md 2
LKML_TIERS_FILE="$work/glob.yaml" tier "$r" "$EMPTY"
check "T8: *.md does not match docs/x.md" "" "$(j '.signals.rules_matched[0].name // ""')"

printf '\n== skip and force-full ==\n'
r="$(new_repo skips)"; add_commit "$r" src/x.txt 2
tier "$r" '{"draft": true}'
check "T9a: draft skips, exit 0" "0 skip draft" "$rc $(j .decision) $(j .skip_reason)"
check "T9a: tier null on skip" null "$(j .tier)"
tier "$r" '{"author-is-bot": true}'
check "T9b: bot author skips" "skip bot-author" "$(j .decision) $(j .skip_reason)"
tier "$r" '{"labels": ["lkml-skip"]}'
check "T9c: default skip label" "skip label:lkml-skip" "$(j .decision) $(j .skip_reason)"
tier "$r" '{"labels": ["SITE-skip"]}'
check "T9c: configured skip label, any case" "skip label:site-skip" "$(j .decision) $(j .skip_reason)"
tier "$r" '{"title": "hello", "labels": ["bug"], "draft": false, "author-is-bot": false}'
check "T9d: nothing holds -> review" review "$(j .decision)"
tier "$r" '{"draft": true, "author-is-bot": true}'
check "T9: draft is reported before bot" draft "$(j .skip_reason)"

r="$(new_repo force)"; add_commit "$r" docs/a.md 2
tier "$r" '{"labels": ["lkml-full"]}'
check "T10a: lkml-full beats a quick rule" full "$(j .tier)"
check "T10a: forced_full signal" true "$(j .signals.forced_full)"
check "T10a: rules still reported" docs-only "$(j '.signals.rules_matched[0].name')"
tier "$r" '{"labels": ["lkml"]}'
check "T10b: legacy lkml label forces full" full "$(j .tier)"
tier "$r" '{"labels": ["site-full"]}'
check "T10c: configured force label" full "$(j .tier)"
tier "$r" '{"labels": ["LKML-FULL"]}'
check "T10d: labels compare case-insensitively" full "$(j .tier)"

printf '\n== extra seats ==\n'
r="$(new_repo extras)"; add_commit "$r" src/auth/login.txt 2; add_commit "$r" src/wire/w.txt 2
tier "$r" "$EMPTY"
check "T11: standard appends the first add-seat rule's seat only" \
    "core,tests,architecture,security" "$(j '.roster|join(",")')"
check "T11: extra_seats reported" '["security"]' "$(jc .signals.extra_seats)"
tier "$r" '{"labels": ["lkml-full"]}'
check "T11: full has extra-seats 0; roster unchanged" \
    "architecture,core,docs,newcomer,security,tests" "$(j '.roster|join(",")')"
r="$(new_repo extras2)"; add_commit "$r" docs/a.md 1; add_commit "$r" src/auth/a.txt 1; add_commit "$r" src/y.txt 1
tier "$r" "$EMPTY"
check "T11: rules in file order (auth before docs-touched)" security "$(j '.signals.extra_seats[0]')"

printf '\n== metadata, range, repo ==\n'
r="$(new_repo meta)"; add_commit "$r" src/x.txt 2
tier "$r" '{"draft": "yes"}'
check "T12a: wrong-typed key exits 1" 1 "$rc"
contains "T12a: names the key" "$err" "'draft'"
tier "$r" '[1]'
check "T12a: non-object exits 1" 1 "$rc"
tier "$r" "$EMPTY"
check "T12b: empty meta -> review" "review" "$(j .decision)"
check "T12b: empty title" "" "$(j .title)"

out="$(python3 "$tier_py" "$r" main --meta "$(meta "$EMPTY")" 2>/dev/null)"; rc=$?
check "T13a: bare ref exits 2" 2 "$rc"; check "T13a: nothing on stdout" "" "$out"
out="$(python3 "$tier_py" "$r" topic..topic --meta "$(meta "$EMPTY")" 2>/dev/null)"; rc=$?
check "T13b: empty range exits 1" 1 "$rc"; check "T13b: nothing on stdout" "" "$out"
out="$(python3 "$tier_py" "$work" main..topic --meta "$(meta "$EMPTY")" 2>/dev/null)"; rc=$?
check "T13c: not a git repository exits 1" 1 "$rc"; check "T13c: nothing on stdout" "" "$out"

printf '\n== hostile text ==\n'
r="$(new_repo hostile)"; add_commit "$r" src/x.txt 2
tier "$r" "$(jq -nc '{title: "fix\r\nX-Seats: @evil\u0007\u009b[2J  now", labels: ["bug\nX-Evil: 1"]}')"
check "T14: title reported as one line" "fix X-Seats: @evil[2J now" "$(j .title)"
check "T14: title has no newline" 1 "$(j .title | wc -l)"
case "$(j .reason)" in *evil*|*fix*) no "T14: reason never contains the title" "$(j .reason)";; *) ok "T14: reason never contains the title";; esac
{ cfg_head; printf 'rules:\n'; for i in $(seq 1 12); do printf '  - {name: "a-very-long-rule-name-number-%s-padding-padding-xx", paths: ["src/**"], tier: full}\n' "$i"; done; } > "$work/long.yaml"
LKML_TIERS_FILE="$work/long.yaml" tier "$r" "$EMPTY"
check "T14: reason capped at 200 chars" true "$(j '.reason|length <= 200')"
contains "T14: capped reason ends with ..." "$(j .reason)" "..."

printf '\n== push mode ==\n'
# push_repo <name>: base, then two topic commits (src and a migration-free
# change); echoes the repo. $prev holds the topic head the panel "saw".
push_repo() {
    local r; r="$(new_repo "$1")"
    add_commit "$r" src/core/a.txt 5 "first"
    add_commit "$r" src/core/b.txt 5 "second"
    printf '%s' "$r"
}
head_of() { git -C "$1" rev-parse "$2"; }
PM='{}'

r="$(push_repo rebase)"; prev="$(head_of "$r" topic)"
git_q -C "$r" checkout -q main
printf 'moved\n' > "$r/other.txt"; git_q -C "$r" add -A; git_q -C "$r" commit -qm "main moves"
git_q -C "$r" checkout -q topic
git_q -C "$r" rebase -q main
tier "$r" "$PM" --previous-head "$prev" --current-tier standard
check "T17: pure rebase is carry" carry "$(j .push.mode)"
check "T17: tier is the current tier" standard "$(j .tier)"
check "T17: headers" '["X-Lkml-Push-Mode: carry"]' "$(jc .push.headers)"
check "T17: no new commits, two carried" "0 2" "$(j '(.push.new_commits|length|tostring) + " " + (.push.carried_commits|length|tostring)')"
check "T17: new head differs from previous (a real rebase)" true "$([[ "$(head_of "$r" topic)" != "$prev" ]] && echo true || echo false)"

r="$(push_repo dropped)"; prev="$(head_of "$r" topic)"
git_q -C "$r" reset -q --hard HEAD~1
tier "$r" "$PM" --previous-head "$prev" --current-tier standard
check "T17b: a dropped commit is not carry" recheck "$(j .push.mode)"
check "T17b: the whole roster is rechecked" core,tests,architecture "$(j '.push.seats|join(",")')"

r="$(push_repo dropnew)"; prev="$(head_of "$r" topic)"
git_q -C "$r" reset -q --hard HEAD~1
add_commit "$r" docs/note.md 2 "docs"
tier "$r" "$PM" --previous-head "$prev" --current-tier standard
check "T17d: dropped plus new commit rechecks the whole roster" core,tests,architecture "$(j '.push.seats|join(",")')"

r="$(push_repo forcecarry)"; prev="$(head_of "$r" topic)"
tier "$r" '{"labels":["lkml-full"]}' --previous-head "$prev" --current-tier standard
check "T17e: force-full on an otherwise-carry push escalates" escalate "$(j .push.mode)"
check "T17e: tier is full" full "$(j .tier)"
tier "$r" '{"labels":["lkml-full"]}' --previous-head "$prev" --current-tier full
check "T17e: already full stays carry" carry "$(j .push.mode)"

r="$(push_repo badroster)"; prev="$(head_of "$r" topic)"
python3 "$tier_py" "$r" main..topic --meta "$(meta '{}')" --previous-head "$prev" --current-tier standard --current-roster core,secretary >/dev/null 2>&1; rc=$?
check "T17f: a reserved seat in --current-roster is refused" 2 "$rc"

r="$(push_repo mergeres)"; prev="$(head_of "$r" topic)"
git_q -C "$r" checkout -q main
printf 'moved\n' > "$r/other.txt"; git_q -C "$r" add -A; git_q -C "$r" commit -qm "main moves"
git_q -C "$r" checkout -q topic
git_q -C "$r" merge -q --no-ff -m "merge main" main
tier "$r" "$PM" --previous-head "$prev" --current-tier standard
check "T17c: a new merge commit is not carry" recheck "$(j .push.mode)"

r="$(push_repo recheck)"; prev="$(head_of "$r" topic)"
add_commit "$r" docs/note.md 2 "docs"
tier "$r" "$PM" --previous-head "$prev" --current-tier standard
check "T18: docs-only new commit -> recheck" recheck "$(j .push.mode)"
check "T18: tier unchanged" standard "$(j .tier)"
check "T18: quick roster intersected with the standard roster" "core,tests" "$(j '.push.seats|join(",")')"
check "T18: recheck header" "X-Lkml-Push-Mode: recheck|X-Lkml-Recheck-Seats: core, tests" "$(j '.push.headers|join("|")')"
check "T18: only the new commit counts" "1 2" "$(j '(.push.new_commits|length|tostring) + " " + (.push.carried_commits|length|tostring)')"
check "T18: new_tier reported" quick "$(j .push.new_tier)"

r="$(push_repo escalate)"; prev="$(head_of "$r" topic)"
add_commit "$r" db/migrations/002.sql 3 "migration"
tier "$r" "$PM" --previous-head "$prev" --current-tier standard
check "T19a: migration push escalates" escalate "$(j .push.mode)"
check "T19a: tier is the higher one" full "$(j .tier)"
check "T19a: add_seats are what the roster lacked" "docs,newcomer,security" "$(j '.push.add_seats|sort|join(",")')"
check "T19a: headers" "X-Lkml-Push-Mode: escalate|X-Lkml-Add-Seats: docs, newcomer, security|X-Lkml-Tier: full" "$(j '.push.headers|join("|")')"
check "T19a: roster is current plus added" 6 "$(j '.roster|length')"
tier "$r" "$PM" --previous-head "$prev" --current-tier standard --current-roster "architecture,core,docs,newcomer,security,tests"
check "T19b: nothing to add -> empty add_seats" "escalate []" "$(j .push.mode) $(jc .push.add_seats)"
case "$(j '.push.headers|join("|")')" in *Add-Seats*) no "T19b: no Add-Seats header when empty";; *) ok "T19b: no Add-Seats header when empty";; esac
check "T19b: tier header still names the new tier" "X-Lkml-Tier: full" "$(j '.push.headers[-1]')"

r="$(push_repo noratchet)"; prev="$(head_of "$r" topic)"
add_commit "$r" docs/note.md 2 "docs"
tier "$r" "$PM" --previous-head "$prev" --current-tier full
check "T20: docs-only on a full thread stays full" "recheck full" "$(j .push.mode) $(j .tier)"
check "T20: new_tier shows what the commit alone would be" quick "$(j .push.new_tier)"

r="$(push_repo emptyx)"; prev="$(head_of "$r" topic)"
add_commit "$r" docs/note.md 2 "docs"
tier "$r" "$PM" --previous-head "$prev" --current-tier standard --current-roster "security,newcomer"
check "T21: empty intersection -> whole current roster" "security,newcomer" "$(j '.push.seats|join(",")')"
tier "$r" "$PM" --previous-head "$prev" --current-tier standard --current-roster "tests,security"
check "T22a: --current-roster is intersected against" "tests" "$(j '.push.seats|join(",")')"
check "T22a: source recorded as flag" flag "$(j .push.roster_source)"
tier "$r" "$PM" --previous-head "$prev" --current-tier standard
check "T22b: without the flag the config roster stands in" "config core,tests" "$(j .push.roster_source) $(j '.push.seats|join(",")')"

out="$(python3 "$tier_py" "$r" main..topic --meta "$(meta "$PM")" --previous-head "$prev" 2>/dev/null)"; rc=$?
check "T23a: --previous-head without --current-tier exits 2" 2 "$rc"
tier "$r" "$PM" --previous-head 0123456789abcdef0123456789abcdef01234567 --current-tier standard
check "T23b: unresolvable previous head exits 1" 1 "$rc"
contains "T23b: names the sha" "$err" "0123456789abcdef"
check "T23b: nothing on stdout" "" "$out"
tier "$r" "$PM" --current-tier standard
check "T23c: --current-tier alone exits 2" 2 "$rc"

tier "$r" '{"draft": true}' --previous-head "$prev" --current-tier standard
check "T24: skip on a push" "skip null" "$(j .decision) $(jc .push)"
tier "$r" '{"labels": ["lkml-full"]}' --previous-head "$prev" --current-tier standard
check "T25: force-full label on a standard thread escalates" "escalate full" "$(j .push.mode) $(j .tier)"
tier "$r" '{"labels": ["lkml-full"]}' --previous-head "$prev" --current-tier full
check "T25: force-full on a full thread is a recheck of the roster" "recheck full" "$(j .push.mode) $(j .tier)"

printf '\n== corpus ==\n'
cdir="$work/corpus"; mkdir -p "$cdir/meta"
printf '{}' > "$cdir/meta/none.json"
printf '{"draft": true}' > "$cdir/meta/draft.json"
r1="$(new_repo corp1)"; add_commit "$r1" docs/a.md 2
r2="$(push_repo corp2)"; cprev="$(head_of "$r2" topic)"; add_commit "$r2" db/migrations/9.sql 2
ln -s "$r1" "$cdir/repo1"; ln -s "$r2" "$cdir/repo2"
cat > "$cdir/ok.json" <<JSON
[{"repo": "repo1", "range": "main..topic", "meta": "meta/none.json", "expected": "quick"},
 {"repo": "repo1", "range": "main..topic", "meta": "meta/draft.json", "expected": "skip"},
 {"repo": "repo2", "range": "main..topic", "meta": "meta/none.json", "expected": "full",
  "previous-head": "$cprev", "current-tier": "standard", "expected-mode": "escalate"}]
JSON
out="$(cd / && python3 "$tier_py" --corpus "$cdir/ok.json" 2>&1)"; rc=$?
check "T26a: every case matches -> exit 0" 0 "$rc"
check "T26a: summary line" "3 cases, 0 mismatches" "$(tail -1 <<<"$out")"
sed 's/"expected": "quick"/"expected": "full"/' "$cdir/ok.json" > "$cdir/bad.json"
out="$(python3 "$tier_py" --corpus "$cdir/bad.json" 2>&1)"; rc=$?
check "T26b: a wrong expectation exits 1" 1 "$rc"
contains "T26b: the mismatch is named" "$out" "case 0 (repo1 main..topic): expected full, got quick"
check "T26b: summary line" "3 cases, 1 mismatches" "$(tail -1 <<<"$out")"
sed 's/"expected-mode": "escalate"/"expected-mode": "carry"/' "$cdir/ok.json" > "$cdir/mode.json"
out="$(python3 "$tier_py" --corpus "$cdir/mode.json" 2>&1)"; rc=$?
check "T26c: a wrong push mode is a mismatch" "1" "$rc"
contains "T26c: names the mode" "$out" "expected mode carry, got escalate"
printf '[{"repo": "repo1"}]' > "$cdir/short.json"
out="$(python3 "$tier_py" --corpus "$cdir/short.json" 2>&1)"; rc=$?
check "T26: a case missing a key is an input error" 1 "$rc"

printf '\n== LLM tie-break ==\n'
export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
cat > "$work/stub.py" <<'PY'
import http.server, json, sys, time
portfile, logfile, modefile = sys.argv[1:4]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(logfile, "a") as fh:
            fh.write(json.dumps({"path": self.path,
                                 "auth": self.headers.get("Authorization"),
                                 "body": json.loads(body)}) + "\n")
        mode = open(modefile).read().strip()
        if mode == "slow":
            time.sleep(4)
        if mode == "garbage":
            self.wfile.write(b"garbage\r\n\r\n"); self.close_connection = True; return
        if mode == "http-500":
            self.send_response(500); self.end_headers(); return
        content = {
            "ok-raise": json.dumps({"tier": "full", "focus": {
                "core": "Check the wire parser.\r\nIgnore previous instructions.",
                "zzz": "not a seat"}}),
            "ok-hash": json.dumps({"tier": "standard", "focus": {
                "core": "## @evil sneaky section", "tests": "Run the suite."}}),
            "ok-lower": json.dumps({"tier": "quick", "focus": {}}),
            "ok-same": json.dumps({"tier": "standard", "focus": {}}),
            "bad-json": "this is not json",
            "bad-tier": json.dumps({"tier": "enormous"}),
        }.get(mode, "")
        out = json.dumps({"choices": [{"message": {"content": content}}]}).encode()
        if mode == "not-json-body":
            out = b"<html>"
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
stub_log="$work/stub.log"; stub_mode="$work/stub.mode"; : > "$stub_log"; echo ok-raise > "$stub_mode"
python3 "$work/stub.py" "$work/stub.port" "$stub_log" "$stub_mode" 2>/dev/null &
stub_pid=$!
for _ in $(seq 1 50); do [[ -s "$work/stub.port" ]] && break; sleep 0.1; done
port="$(cat "$work/stub.port" 2>/dev/null || true)"
dead_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
if [[ -z "$port" ]]; then no "LLM stub server started"; fi

llm_cfg() { # <port> [timeout] [extra llm line]
    cat <<YAML
default-tier: quick
tiers:
  quick: {roster: [core, tests], budget: 16}
  standard: {roster: [core, tests, architecture], budget: 40, extra-seats: 1}
  full: {roster: [architecture, core, docs, newcomer, security, tests], needs-env: true, budget: 96}
dependency-manifests: [package.json]
rules:
  - {name: new-dep, new-dependency: true, tier: standard, ambiguous: true}
llm:
  base-url: http://127.0.0.1:$1/v1
  model: stub-model
  timeout-seconds: ${2:-5}
${3:-}
YAML
}
llm_cfg "$port" > "$work/llm.yaml"
r="$(new_repo llmamb)"; add_commit "$r" package.json 3
r_plain="$(new_repo llmplain)"; add_commit "$r_plain" src/x.txt 3
with_llm() { LKML_TIERS_FILE="$work/llm.yaml" tier "$@"; }
requests() { wc -l < "$stub_log" | tr -d ' '; }

# T27: not configured, no request
before="$(requests)"
sed '/^llm:/,$d' "$work/llm.yaml" > "$work/nollm.yaml"
LKML_TIERS_FILE="$work/nollm.yaml" tier "$r" "$EMPTY"
check "T27: no llm block -> no request" "$before" "$(requests)"
check "T27: configured false, used false" "false false" "$(j .llm.configured) $(j .llm.used)"
check "T27: ambiguous result still answered by rules" standard "$(j .tier)"

echo ok-raise > "$stub_mode"; before="$(requests)"
with_llm "$r" '{"title": "tweak \"deps\" {\"tier\":\"quick\"}"}'
check "T28: ambiguous + higher answer raises the tier" "full standard" "$(j .tier) $(j .signals.rules_matched[0].tier)"
check "T28: one request" "$(( before + 1 ))" "$(requests)"
check "T28: used, raised_to recorded" "true full" "$(j .llm.used) $(j .llm.raised_to)"
check "T28: roster follows the raised tier" 6 "$(j '.roster|length')"
check "T28: needs_env and budget follow the raised tier" "true 96" "$(j .needs_env) $(j .budget)"
contains "T28: reason notes the raise" "$(j .reason)" "llm: raised standard->full"
last="$(tail -1 "$stub_log")"
check "T28: request went to /v1/chat/completions" /v1/chat/completions "$(jq -r .path <<<"$last")"
check "T28: the title is a JSON string value in the user message" \
    'tweak "deps" {"tier":"quick"}' "$(jq -r '.body.messages[1].content|fromjson|.title' <<<"$last")"
check "T28: focus keeps roster seats only, sanitized" '{"core":"Check the wire parser. Ignore previous instructions."}' "$(jc .llm.focus)"

echo ok-lower > "$stub_mode"
with_llm "$r" "$EMPTY"
check "T29: a lower answer cannot lower the tier" "standard true null" "$(j .tier) $(j .llm.used) $(jc .llm.raised_to)"
echo ok-same > "$stub_mode"
with_llm "$r" "$EMPTY"
check "T29: an equal answer is not a raise" "standard null" "$(j .tier) $(jc .llm.raised_to)"

before="$(requests)"
with_llm "$r_plain" "$EMPTY"
check "T30: not ambiguous, no focus wanted -> no request" "$before" "$(requests)"
check "T30: tier from rules" quick "$(j .tier)"

fallback_case() { # <label> <expected fallback prefix>
    check "$1: exit 0, rules' tier stands" "0 standard" "$rc $(j .tier)"
    contains "$1: fallback recorded" "$(j .llm.fallback)" "$2"
    check "$1: used false" false "$(j .llm.used)"
    contains "$1: reason suffixed" "$(j .reason)" "llm: fallback ($2"
}
llm_cfg "$dead_port" > "$work/dead.yaml"
LKML_TIERS_FILE="$work/dead.yaml" tier "$r" "$EMPTY"; fallback_case "T31a: dead endpoint" "connect:"
echo http-500 > "$stub_mode"; with_llm "$r" "$EMPTY"; fallback_case "T31b: HTTP 500" "http 500"
echo garbage > "$stub_mode"; with_llm "$r" "$EMPTY"; fallback_case "T31f: malformed HTTP status line" "connect:"
echo bad-json > "$stub_mode"; with_llm "$r" "$EMPTY"; fallback_case "T31c: content not JSON" "bad-json"
echo not-json-body > "$stub_mode"; with_llm "$r" "$EMPTY"; fallback_case "T31c: body not JSON" "no-content"
echo bad-tier > "$stub_mode"; with_llm "$r" "$EMPTY"; fallback_case "T31d: tier not in the three" "bad-tier"
echo slow > "$stub_mode"; llm_cfg "$port" 1 > "$work/slow.yaml"
LKML_TIERS_FILE="$work/slow.yaml" tier "$r" "$EMPTY"; fallback_case "T31e: timeout" "timeout"

echo ok-raise > "$stub_mode"; before="$(requests)"
with_llm "$r" "$EMPTY" --no-llm
check "T32: --no-llm makes no request" "$before" "$(requests)"
check "T32: fallback disabled, tier from rules" "disabled standard" "$(j .llm.fallback) $(j .tier)"

llm_cfg "$port" 5 "  api-key-env: LKML_TEST_LLM_KEY" > "$work/key.yaml"
LKML_TEST_LLM_KEY=s3cret LKML_TIERS_FILE="$work/key.yaml" tier "$r" "$EMPTY"
check "T33a: bearer header from the named variable" "Bearer s3cret" "$(tail -1 "$stub_log" | jq -r .auth)"
check "T33b-pre: the key never appears in the output" "" "$(grep -c s3cret <<<"$out" | grep -v '^0$')"
env -u LKML_TEST_LLM_KEY LKML_TIERS_FILE="$work/key.yaml" \
    python3 "$tier_py" "$r" main..topic --meta "$(meta "$EMPTY")" > "$work/o33b"
check "T33b: unset variable -> no Authorization header, still called" "null full" "$(tail -1 "$stub_log" | jq -r .auth) $(jq -r .tier "$work/o33b")"

llm_cfg "$port" 5 "  frobnicate: 1" > "$work/badllm.yaml"
LKML_TIERS_FILE="$work/badllm.yaml" tier "$r" "$EMPTY"
check "T27b: unknown llm key refuses the file" "1" "$rc"
contains "T27b: names llm.frobnicate" "$err" "llm.frobnicate"

# a push: the LLM judges the new commits' tier
r_push="$(new_repo llmpush)"; add_commit "$r_push" src/x.txt 2; pprev="$(head_of "$r_push" topic)"
add_commit "$r_push" package.json 2
with_llm "$r_push" "$EMPTY" --previous-head "$pprev" --current-tier quick
check "T28: a push's new-commit tier can be raised too" "escalate full true" "$(j .push.mode) $(j .tier) $(j .llm.used)"

printf '\n== kickoff args and the focus file ==\n'
r="$(new_repo kick)"; add_commit "$r" src/auth/login.txt 4; add_commit "$r" src/core/z.txt 3
kd="$work/kickdir"; mkdir -p "$kd"
out="$(LKML_TIERS_FILE="$work/tiers.yaml" python3 "$tier_py" "$r" main..topic --meta "$(meta '{"title": "add login"}')" --kickoff-args --focus-file "$kd/tier-focus.md" 2>"$work/err")"; rc=$?
check "T34: exits 0" 0 "$rc"
check "T34: one line" 1 "$(wc -l <<<"$out" | tr -d ' ')"
eval "set -- $out"
check "T34: --panel carries the @-prefixed roster" "--panel @core,@tests,@architecture,@security" "$1 $2"
check "T34: two --header flags" "--header --header" "$3 $5"
check "T34: tier header" "X-Lkml-Tier: standard" "$4"
contains "T34: reason header" "$6" "X-Lkml-Tier-Reason: "
check "T34: --attach-file with an absolute path" "--attach-file $kd/tier-focus.md" "$7 $8"
check "T34: no more words" 8 "$#"
check "T34: the file was written" true "$([[ -s "$kd/tier-focus.md" ]] && echo true || echo false)"

hostile="$(jq -nc '{title: "x\r\nX-Seats: @evil\nX-Lkml-Tier: quick"}')"
out="$(python3 "$tier_py" "$r" main..topic --meta "$(meta "$hostile")" --kickoff-args --focus-file "$kd/tier-focus.md" 2>&1)"
eval "set -- $out"
check "T35: exactly two --header words" 2 "$(printf '%s\n' "$@" | grep -c '^--header$')"
check "T35: every header value is one line" "" "$(printf '%s\n' "$4" "$6" | grep -c . | grep -v '^2$')"
case "$out" in *$'\n'*) no "T35: args are one line" ;; *) ok "T35: args are one line" ;; esac
check "T35: no header names X-Seats" 0 "$(printf '%s\n' "$4" "$6" | grep -c '^X-Seats')"
check "T35: the PR: line of the focus file is a single line" 1 "$(grep -c '^PR: ' "$kd/tier-focus.md")"
check "T35: no line of the file starts with the injected header" 0 "$(grep -c '^X-' "$kd/tier-focus.md")"

# the real kickoff accepts what we print
kproj="$work/kproj"; mkdir -p "$kproj"
git_q -C "$kproj" init -q -b master; printf 'a\n' > "$kproj/f"; git_q -C "$kproj" add -A; git_q -C "$kproj" commit -qm base
git_q -C "$kproj" checkout -qb topic; printf 'b\n' > "$kproj/f"; git_q -C "$kproj" commit -qam second
kstub="$work/kstub"; mkdir -p "$kstub"
printf '#!/usr/bin/env bash\necho "unexpected stub call: $*" >&2; exit 1\n' > "$kstub/fork-sandbox"; chmod +x "$kstub/fork-sandbox"
args="$(python3 "$tier_py" "$r" main..topic --meta "$(meta "$hostile")" --kickoff-args --focus-file "$kd/tier-focus.md")"
ktip="$(git -C "$kproj" rev-parse topic)"
mkdir -p "$work/ktmp"
kout="$(eval "TMPDIR=\"$work/ktmp\" PATH=\"$kstub:\$PATH\" \"$repo_dir/scripts/lkml-fleet-kickoff.sh\" \"$kproj\" master...topic --template pr-review --from @ci --subject 'subj' --summary 'a change' --review-target \"topic:$ktip\" $args" 2>&1)"; rc=$?
check "T35b: the real kickoff accepts the printed args" 0 "$rc"
contains "T35b: the mail carries X-Lkml-Tier" "$kout" "X-Lkml-Tier:"
contains "T35b: the mail carries the roster as the panel" "$kout" 'X-Seats:\ @core'
contains "T35b: the attachment is passed on" "$kout" "tier-focus.md"
case "$kout" in *"X-Seats:\\ @evil"*) no "T35b: no injected X-Seats" "$kout";; *) ok "T35b: no injected X-Seats";; esac

sections() { grep '^## @' "$1" | tr '\n' ' '; }
check "T36a: one section per roster seat, in roster order" "## @core ## @tests ## @architecture ## @security " "$(sections "$kd/tier-focus.md")"
python3 "$tier_py" "$r" main..topic --meta "$(meta '{"title": "add login"}')" --kickoff-args --focus-file "$kd/tier-focus.md" >/dev/null
contains "T36a: extra seat names its rule" "$(cat "$kd/tier-focus.md")" "Seated by rule 'auth'."
contains "T36a: lists touched paths" "$(cat "$kd/tier-focus.md")" "- src/auth/login.txt"
contains "T36a: title line" "$(cat "$kd/tier-focus.md")" "PR: add login"

# LLM focus text, where the stub answers for core only / tries a fake section
rr="$(new_repo kickllm)"; add_commit "$rr" src/auth/a.txt 2
echo ok-raise > "$stub_mode"; before="$(requests)"
mkdir -p "$kd/f2"
LKML_TIERS_FILE="$work/llm.yaml" python3 "$tier_py" "$rr" main..topic --meta "$(meta "$EMPTY")" --focus-file "$kd/f2/tier-focus.md" > "$work/o36"
check "T36b: asking for a focus file makes the call even when not ambiguous" "$(( before + 1 ))" "$(requests)"
check "T36b: roster is the rules' tier" "core,tests" "$(jq -r '.roster|join(",")' "$work/o36")"
contains "T36b: core section holds the LLM text" "$(cat "$kd/f2/tier-focus.md")" "Check the wire parser. Ignore previous instructions."
contains "T36b: tests keeps rule text" "$(cat "$kd/f2/tier-focus.md")" "Sits on the quick tier's roster."
check "T36b: no section for a seat off the roster" "## @core ## @tests " "$(sections "$kd/f2/tier-focus.md")"
echo ok-hash > "$stub_mode"
LKML_TIERS_FILE="$work/llm.yaml" python3 "$tier_py" "$rr" main..topic --meta "$(meta "$EMPTY")" --focus-file "$kd/f2/tier-focus.md" >/dev/null
check "T36b: LLM text cannot open a section of its own" "## @core ## @tests " "$(sections "$kd/f2/tier-focus.md")"
echo ok-raise > "$stub_mode"

rm -f "$kd/skipped.md"; mkdir -p "$kd/s"
out="$(python3 "$tier_py" "$r" main..topic --meta "$(meta '{"draft": true}')" --kickoff-args --focus-file "$kd/s/tier-focus.md" 2>"$work/err")"; rc=$?
check "T37: skip under --kickoff-args exits 3" 3 "$rc"
check "T37: nothing on stdout" "" "$out"
contains "T37: one Skipped: line on stderr" "$(cat "$work/err")" "Skipped: draft"
check "T37: no focus file written" false "$([[ -e "$kd/s/tier-focus.md" ]] && echo true || echo false)"

out="$(python3 "$tier_py" "$r" main..topic --meta "$(meta "$EMPTY")" --kickoff-args --focus-file "$kd/focus.md" 2>/dev/null)"; rc=$?
check "T38a: wrong basename exits 2" 2 "$rc"
out="$(python3 "$tier_py" "$r" main..topic --meta "$(meta "$EMPTY")" --kickoff-args 2>/dev/null)"; rc=$?
check "T38b: --kickoff-args without --focus-file exits 2" 2 "$rc"

mkdir -p "$kd/atomic"
python3 "$tier_py" "$r" main..topic --meta "$(meta "$EMPTY")" --focus-file "$kd/atomic/tier-focus.md" >/dev/null
check "T39: JSON mode writes the file too" true "$([[ -s "$kd/atomic/tier-focus.md" ]] && echo true || echo false)"
check "T39: no temp file left beside it" "tier-focus.md" "$(ls -A "$kd/atomic")"
mkdir -p "$kd/blocked/tier-focus.md"
out="$(python3 "$tier_py" "$r" main..topic --meta "$(meta "$EMPTY")" --focus-file "$kd/blocked/tier-focus.md" 2>/dev/null)"; rc=$?
check "T39: a failed write exits 1 with nothing on stdout" "1 " "$rc $out"
check "T39: and leaves no temp file behind" "tier-focus.md" "$(ls -A "$kd/blocked")"

out="$(python3 "$tier_py" --corpus "$cdir/ok.json" --kickoff-args 2>/dev/null)"; rc=$?
check "T40: --kickoff-args with --corpus exits 2" 2 "$rc"
out="$(python3 "$tier_py" "$r" main..topic --meta "$(meta "$EMPTY")" --kickoff-args --focus-file "$kd/tier-focus.md" --previous-head "$prev" --current-tier standard 2>/dev/null)"; rc=$?
check "T40: --kickoff-args with --previous-head exits 2" 2 "$rc"

printf '\n== docs ==\n'
mentions() { # <label> <file> <needle>...
    local label="$1" f="$repo_dir/$2" n; shift 2
    for n in "$@"; do
        if ! grep -q -- "$n" "$f"; then no "$label" "'$n' missing from $f"; return; fi
    done
    ok "$label"
}
mentions "T41: README lists tiers.yaml and LKML_TIERS_FILE" README.md tiers.yaml LKML_TIERS_FILE
mentions "T41: CLAUDE.md lists tiers.yaml and LKML_TIERS_FILE" CLAUDE.md tiers.yaml LKML_TIERS_FILE
mentions "T41: README scripts table has lkml-pr-tier.py" README.md lkml-pr-tier.py
mentions "T41: cluster-panel.md has the push-mode table" docs/cluster-panel.md X-Lkml-Push-Mode X-Lkml-Recheck-Seats X-Lkml-Add-Seats

printf '\n== help and install ==\n'
help_out="$(python3 "$tier_py" --help)"; rc=$?
check "T15: --help exits 0" 0 "$rc"
contains "T15: --help prints usage" "$help_out" "Usage: lkml-pr-tier.py"
if python3 -m py_compile "$tier_py" 2>/dev/null; then ok "T15: py_compile"; else no "T15: py_compile"; fi
rm -rf "$repo_dir/scripts/__pycache__"
if grep -n 'triage' "$tier_py" "$shipped" >/dev/null; then no "T15: the word triage never appears"; else ok "T15: the word triage never appears"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
