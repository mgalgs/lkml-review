#!/usr/bin/env bash
# lkml-fleet-test.sh — Exercise lkml-fleet.sh with a fork-sandbox stub.
#
# Usage: tests/lkml-fleet-test.sh
#
# The stub records its environment and arguments so this suite checks the
# registry boundary at the wrapper, without needing fork-sandbox installed.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fleet="${LKML_FLEET:-$repo_dir/scripts/lkml-fleet.sh}"

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
    case "$haystack" in *"$needle"*) ok "$label" ;; *) no "$label" "'$needle' not found in: $haystack" ;; esac
}

work="$(mktemp -d)"; tmpdirs+=("$work")
stub_bin="$work/stub"; mkdir -p -- "$stub_bin"
record="$work/record"
cat > "$stub_bin/fork-sandbox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'personas=%s\n' "$FORK_SANDBOX_PERSONAS_DIR"
    printf 'fleet=%s\n' "$FORK_SANDBOX_FLEET_FILE"
    printf 'prompts=%s\n' "$FORK_SANDBOX_PROMPTS_DIR"
    printf 'args:\n'
    printf '%s\n' "$@"
} > "$LKML_FLEET_TEST_RECORD"
STUB
chmod +x -- "$stub_bin/fork-sandbox"

run_fleet() {
    HOME="$home_dir" PATH="$stub_bin:$PATH" LKML_FLEET_TEST_RECORD="$record" "$@"
}

home_dir="$work/home"; mkdir -p -- "$home_dir"
expected_personas="$repo_dir/fleet/personas"
expected_prompts="$repo_dir/fleet/prompts"

printf '\n== registry environment ==\n'
run_fleet "$fleet" fleet expand '@all'; rc=$?
check "wrapper exits with the stub's status" "0" "$rc"
recorded="$(cat "$record")"
contains "exports the repository personas directory" "$recorded" "personas=$expected_personas"
contains "exports the repository prompts directory" "$recorded" "prompts=$expected_prompts"
contains "exports the default fleet-file path" "$recorded" "fleet=$home_dir/.config/lkml/fleet.yaml"
check "passes the first argument" "fleet" "$(sed -n '5p' "$record")"
check "passes the final argument" "@all" "$(sed -n '7p' "$record")"

printf '\n== caller environment cannot select another registry ==\n'
other_personas="$work/other-personas"; mkdir -p -- "$other_personas"
FORK_SANDBOX_PERSONAS_DIR="$other_personas" run_fleet "$fleet" mail tree 'thread with spaces'; rc=$?
check "pre-existing personas directory is overridden" "personas=$expected_personas" "$(sed -n '1p' "$record")"
FORK_SANDBOX_PROMPTS_DIR="$other_personas" run_fleet "$fleet" fleet expand '@all'; rc=$?
check "pre-existing prompts directory is overridden" "prompts=$expected_prompts" "$(sed -n '3p' "$record")"
FORK_SANDBOX_PERSONAS_DIR="$other_personas" run_fleet "$fleet" mail tree 'thread with spaces'; rc=$?
check "arguments containing spaces pass verbatim" "thread with spaces" "$(sed -n '7p' "$record")"

printf '\n== explicit fleet-file override ==\n'
override="$work/custom fleet.yaml"
LKML_FLEET_FILE="$override" run_fleet "$fleet" postmaster deliver --project "$work/project"; rc=$?
check "override invocation exits 0" "0" "$rc"
check "LKML_FLEET_FILE overrides the default" "fleet=$override" "$(sed -n '2p' "$record")"
check "fleet file remains exported when absent" "fleet=$override" "$(sed -n '2p' "$record")"
check "all postmaster arguments pass through" "--project" "$(sed -n '7p' "$record")"

printf '\n== cluster postmaster deploys default to fleet-cluster.yaml ==\n'
cluster_fleet="$home_dir/.config/lkml/fleet-cluster.yaml"
rm -f -- "$record"
out="$(run_fleet "$fleet" k8s install --postmaster 2>&1)"; rc=$?
if (( rc != 0 )); then ok "install --postmaster with no fleet-cluster.yaml exits non-zero"; else no "install --postmaster with no fleet-cluster.yaml exits non-zero" "exit 0"; fi
contains "the refusal names fleet-cluster.yaml" "$out" "$cluster_fleet"
if [[ -e "$record" ]]; then no "the refusal does not exec fork-sandbox" "stub record exists"; else ok "the refusal does not exec fork-sandbox"; fi
mkdir -p -- "$(dirname "$cluster_fleet")"; : > "$cluster_fleet"
run_fleet "$fleet" k8s install --dry-run --postmaster; rc=$?
check "install --postmaster exits 0" "0" "$rc"
check "install --postmaster ships fleet-cluster.yaml" "fleet=$cluster_fleet" "$(sed -n '2p' "$record")"
run_fleet "$fleet" k8s upgrade-postmaster; rc=$?
check "upgrade-postmaster ships fleet-cluster.yaml" "fleet=$cluster_fleet" "$(sed -n '2p' "$record")"
run_fleet "$fleet" k8s install; rc=$?
check "plain k8s install keeps the default fleet" "fleet=$home_dir/.config/lkml/fleet.yaml" "$(sed -n '2p' "$record")"
run_fleet "$fleet" postmaster deliver --postmaster; rc=$?
check "--postmaster outside k8s install keeps the default fleet" "fleet=$home_dir/.config/lkml/fleet.yaml" "$(sed -n '2p' "$record")"
LKML_FLEET_FILE="$override" run_fleet "$fleet" k8s install --postmaster; rc=$?
check "LKML_FLEET_FILE still wins for a cluster deploy" "fleet=$override" "$(sed -n '2p' "$record")"
rm -f -- "$cluster_fleet"

printf '\n== missing personas directory ==\n'
missing_root="$work/missing"; mkdir -p -- "$missing_root/scripts"
mkdir -p -- "$missing_root/fleet/prompts"
cp -- "$fleet" "$missing_root/scripts/lkml-fleet.sh"
chmod +x -- "$missing_root/scripts/lkml-fleet.sh"
rm -f -- "$record"
out="$(HOME="$home_dir" PATH="$stub_bin:$PATH" LKML_FLEET_TEST_RECORD="$record" "$missing_root/scripts/lkml-fleet.sh" fleet expand '@all' 2>&1)"; rc=$?
if (( rc != 0 )); then ok "missing personas exits non-zero"; else no "missing personas exits non-zero" "exit 0"; fi
contains "missing personas names the resolved directory" "$out" "$missing_root/fleet/personas"
if [[ -e "$record" ]]; then
    no "missing personas does not exec fork-sandbox" "stub record exists"
else
    ok "missing personas does not exec fork-sandbox"
fi

printf '\n== missing prompts directory ==\n'
rm -rf -- "$missing_root/fleet/prompts"; mkdir -p -- "$missing_root/fleet/personas"
rm -f -- "$record"
out="$(HOME="$home_dir" PATH="$stub_bin:$PATH" LKML_FLEET_TEST_RECORD="$record" "$missing_root/scripts/lkml-fleet.sh" fleet expand '@all' 2>&1)"; rc=$?
if (( rc != 0 )); then ok "missing prompts exits non-zero"; else no "missing prompts exits non-zero" "exit 0"; fi
contains "missing prompts names the resolved directory" "$out" "$missing_root/fleet/prompts"
if [[ -e "$record" ]]; then
    no "missing prompts does not exec fork-sandbox" "stub record exists"
else
    ok "missing prompts does not exec fork-sandbox"
fi

printf '\n== --help ==\n'
out="$("$fleet" --help 2>&1)"; rc=$?
check "--help exits 0" "0" "$rc"
contains "--help prints the header" "$out" "lkml-fleet.sh — Run fork-sandbox against lkml-review's fleet registry."

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
