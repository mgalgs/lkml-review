#!/usr/bin/env bash
# lkml-wake-gate-install-test.sh — Exercise lkml-wake-gate-install.sh.
#
# Every case stages into a hooks directory created under a temp dir, via
# --hooks-dir or FORK_SANDBOX_HOOKS_DIR; nothing under $HOME is touched.
#
# Usage: tests/lkml-wake-gate-install-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
inst="$repo_dir/scripts/lkml-wake-gate-install.sh"

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}
contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}

work="$(mktemp -d)"; tmpdirs+=("$work")
OUT=""; RC=0
run() { OUT="$("$inst" "$@" 2>&1)"; RC=$?; }
mode_of() { stat -c %a -- "$1"; }

[[ -x "$inst" ]] || { echo "not executable: $inst" >&2; exit 1; }

printf '\n== --help ==\n'
run --help
check "--help exits 0" "0" "$RC"
contains "--help prints the usage" "$OUT" "Usage: lkml-wake-gate-install.sh"

printf '\n== a missing hooks dir is refused ==\n'
run --hooks-dir "$work/nope"
check "install exits 1" "1" "$RC"
contains "install names the path" "$OUT" "$work/nope"
check "install did not create it" "no" "$([[ -e "$work/nope" ]] && echo yes || echo no)"
run --check --hooks-dir "$work/nope"
check "--check exits 1" "1" "$RC"
contains "--check names the path" "$OUT" "$work/nope"
check "--check did not create it" "no" "$([[ -e "$work/nope" ]] && echo yes || echo no)"
OUT="$(env -u FORK_SANDBOX_HOOKS_DIR HOME="$work/home" "$inst" 2>&1)"; RC=$?
check "default dir under \$HOME is refused too" "1" "$RC"
contains "default dir is named" "$OUT" "$work/home/.config/fork-sandbox/hooks"
check "default dir was not created" "no" "$([[ -e "$work/home" ]] && echo yes || echo no)"

printf '\n== install ==\n'
hooks="$work/hooks"; mkdir -p -- "$hooks"
printf '#!/bin/sh\necho other project hook\n' > "$hooks/notify.other"
chmod 0750 "$hooks/notify.other"
cp -p -- "$hooks/notify.other" "$work/notify.other.before"

run --hooks-dir "$hooks"
check "install exits 0" "0" "$RC"
contains "install says what it wrote (gate)" "$OUT" "$hooks/wake-when.lkml-panel"
contains "install says what it wrote (panel-state)" "$OUT" "$hooks/lkml-panel-state.py"
check "gate is mode 0755" "755" "$(mode_of "$hooks/wake-when.lkml-panel")"
check "panel-state is mode 0755" "755" "$(mode_of "$hooks/lkml-panel-state.py")"
check "gate is byte-identical to the repo copy" "same" \
    "$(cmp -s "$repo_dir/scripts/lkml-wake-gate.py" "$hooks/wake-when.lkml-panel" && echo same || echo differ)"
check "panel-state is byte-identical to the repo copy" "same" \
    "$(cmp -s "$repo_dir/scripts/lkml-panel-state.py" "$hooks/lkml-panel-state.py" && echo same || echo differ)"
check "an unrelated hook is byte-identical" "same" \
    "$(cmp -s "$work/notify.other.before" "$hooks/notify.other" && echo same || echo differ)"
check "an unrelated hook keeps its mode" "750" "$(mode_of "$hooks/notify.other")"
check "the dir holds exactly the two staged files and the other hook" \
    "lkml-panel-state.py notify.other wake-when.lkml-panel" "$(find "$hooks" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"
run --hooks-dir "$hooks"
check "re-running is safe" "0" "$RC"

printf '\n== --check ==\n'
run --check --hooks-dir "$hooks"
check "passes after install" "0" "$RC"
contains "reports the gate ok" "$OUT" "ok       $hooks/wake-when.lkml-panel"
printf '#' >> "$hooks/lkml-panel-state.py"
run --check --hooks-dir "$hooks"
check "fails after a byte is appended to the staged panel-state" "1" "$RC"
contains "names the stale file" "$OUT" "STALE    $hooks/lkml-panel-state.py"
contains "does not call the intact gate stale" "$OUT" "ok       $hooks/wake-when.lkml-panel"
check "--check did not repair it" "differ" \
    "$(cmp -s "$repo_dir/scripts/lkml-panel-state.py" "$hooks/lkml-panel-state.py" && echo same || echo differ)"
run --hooks-dir "$hooks"
run --check --hooks-dir "$hooks"
check "passes again after a re-install" "0" "$RC"
chmod 0644 "$hooks/wake-when.lkml-panel"
run --check --hooks-dir "$hooks"
check "fails when the gate is not executable" "1" "$RC"
contains "names the non-executable gate" "$OUT" "STALE    $hooks/wake-when.lkml-panel"
rm -- "$hooks/wake-when.lkml-panel"
run --check --hooks-dir "$hooks"
check "fails when a file is missing" "1" "$RC"
contains "names the missing file" "$OUT" "MISSING  $hooks/wake-when.lkml-panel"
check "--check did not recreate it" "no" "$([[ -e "$hooks/wake-when.lkml-panel" ]] && echo yes || echo no)"

printf '\n== FORK_SANDBOX_HOOKS_DIR and a PATH symlink ==\n'
hooks2="$work/hooks2"; mkdir -p -- "$hooks2" "$work/bin"
ln -s -- "$inst" "$work/bin/lkml-wake-gate-install.sh"
OUT="$(FORK_SANDBOX_HOOKS_DIR="$hooks2" "$work/bin/lkml-wake-gate-install.sh" 2>&1)"; RC=$?
check "installs through a symlink into the env dir" "0" "$RC"
check "the symlinked install staged this checkout's gate" "same" \
    "$(cmp -s "$repo_dir/scripts/lkml-wake-gate.py" "$hooks2/wake-when.lkml-panel" && echo same || echo differ)"
OUT="$(FORK_SANDBOX_HOOKS_DIR="$hooks2" "$work/bin/lkml-wake-gate-install.sh" --check 2>&1)"; RC=$?
check "--check through the symlink passes" "0" "$RC"

printf '\n== unknown arguments ==\n'
run --bogus
check "an unknown argument exits 1" "1" "$RC"
run --hooks-dir
check "--hooks-dir without a value exits 1" "1" "$RC"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
