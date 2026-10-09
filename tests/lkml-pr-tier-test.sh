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
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
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

printf '\n== help and install ==\n'
help_out="$(python3 "$tier_py" --help)"; rc=$?
check "T15: --help exits 0" 0 "$rc"
contains "T15: --help prints usage" "$help_out" "Usage: lkml-pr-tier.py"
if python3 -m py_compile "$tier_py" 2>/dev/null; then ok "T15: py_compile"; else no "T15: py_compile"; fi
rm -rf "$repo_dir/scripts/__pycache__"
if grep -n 'triage' "$tier_py" "$shipped" >/dev/null; then no "T15: the word triage never appears"; else ok "T15: the word triage never appears"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
