#!/usr/bin/env bash
# lkml-fleet-personas-test.sh — Confirm every fleet/personas/*.md file's
# frontmatter parses cleanly under the REAL fork-sandbox fleet parser,
# not a stub or a reimplementation. A fixture written by whoever wrote
# the persona files cannot catch a misread of that external format (see
# CLAUDE.md's "false green" hazard) -- only the real parser can, which
# is why this suite shells out to `fork-sandbox fleet resolve` instead
# of parsing the YAML itself.
#
# Usage: tests/lkml-fleet-personas-test.sh

set -uo pipefail

if ! command -v fork-sandbox >/dev/null 2>&1; then
    echo "SKIP: fork-sandbox not installed; this suite needs the real fleet parser on PATH."
    exit 0
fi

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
personas_dir="$repo_dir/fleet/personas"

pass=0; fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

fleet_file="$(mktemp)"
trap 'rm -f -- "$fleet_file"' EXIT
printf 'agents: {}\nlists: {}\n' > "$fleet_file"

export FORK_SANDBOX_PERSONAS_DIR="$personas_dir"
export FORK_SANDBOX_FLEET_FILE="$fleet_file"

if out="$(fork-sandbox fleet check 2>&1)"; then
    ok "fleet check accepts every persona file's frontmatter"
else
    no "fleet check accepts every persona file's frontmatter" "$out"
fi

for f in "$personas_dir"/*.md; do
    name="$(basename "$f" .md)"
    resolved="$(fork-sandbox fleet resolve "$name" 2>&1)"
    description="$(printf '%s\n' "$resolved" | sed -n '6p')"
    if [[ -n "$description" ]]; then
        ok "$name resolves a non-empty description"
    else
        no "$name resolves a non-empty description" "$resolved"
    fi
done

# ci pins network: sealed in its own persona frontmatter -- the seat
# that executes untrusted code -- and it must resolve, not silently
# fall into an ignored comment.
ci_network="$(fork-sandbox fleet resolve ci 2>&1 | sed -n '4p')"
if [[ "$ci_network" == "sealed" ]]; then
    ok "ci resolves network=sealed"
else
    no "ci resolves network=sealed" "got '$ci_network'"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
