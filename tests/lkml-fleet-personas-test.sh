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

# The ci persona's suite source is a two-path contract: an executable
# .agents/ci/run-tests at the repo root wins (the repo's own statement
# of how to run its whole suite); otherwise the persona falls back to
# tests/*-test.sh. Pin both paths and the contract path's reporting.
ci_md="$personas_dir/ci.md"
has() { # $1=file $2=fixed string $3=description
    if grep -qF -- "$2" "$1"; then
        ok "$3"
    else
        no "$3" "'$2' not found in $(basename "$1")"
    fi
}

has "$ci_md" '.agents/ci/run-tests' \
    "ci.md names the .agents/ci/run-tests entrypoint"
has "$ci_md" 'executable' \
    "ci.md requires the entrypoint to be executable"
has "$ci_md" 'repo root' \
    "ci.md runs the entrypoint from the repo root"
has "$ci_md" 'ls tests/*-test.sh' \
    "ci.md keeps the tests/*-test.sh fallback"
has "$ci_md" 'exit code' \
    "ci.md's contract path records the exit code"
has "$ci_md" 'non-zero' \
    "ci.md states a non-zero exit is not green"

# Only the seat that executes anything may grow the contract; the other
# eight personas must not pick it up.
mentioners=""
for f in "$personas_dir"/*.md; do
    if grep -qF '.agents/ci/run-tests' "$f"; then
        mentioners+=" $(basename "$f" .md)"
    fi
done
if [[ "$mentioners" == " ci" ]]; then
    ok "only ci.md mentions .agents/ci/run-tests"
else
    no "only ci.md mentions .agents/ci/run-tests" "mentioned in:$mentioners"
fi

# The reply-format section is a hard contract with the router, not
# advice: a malformed stanza is discarded wholesale and the seat
# respawned, so every persona carries the same salient section. The
# suite compares the sections against each other rather than trusting
# one file to be right.
extract_reply_format() {
    awk '/^## Reply format$/{ f = 1; print; next }
         f && /^## / { exit }
         f { print }' "$1"
}

count=0
baseline=""
baseline_name=""
for f in "$personas_dir"/*.md; do
    name="$(basename "$f" .md)"
    count=$(( count + 1 ))
    section="$(extract_reply_format "$f")"
    if [[ -z "$section" ]]; then
        no "$name carries the Reply format section" "no '## Reply format' heading"
        continue
    fi
    if [[ -z "$baseline" ]]; then
        baseline="$section"
        baseline_name="$name"
        ok "$name carries the Reply format section"
        continue
    fi
    if [[ "$section" == "$baseline" ]]; then
        ok "$name's Reply format section matches $baseline_name's"
    else
        no "$name's Reply format section matches $baseline_name's" "section text diverges"
    fi
done
if (( count == 10 )); then
    ok "fleet/personas holds exactly ten personas"
else
    no "fleet/personas holds exactly ten personas" "found $count"
fi
if [[ -n "$baseline" ]]; then
    if grep -q 'Reply-To-Id:' <<<"$baseline" && ! grep -q 'In-Reply-To:' <<<"$baseline"; then
        ok "Reply format section names Reply-To-Id and no In-Reply-To"
    else
        no "Reply format section names Reply-To-Id and no In-Reply-To"
    fi
    # @localhost is the dialect the router cannot parse; a persona that
    # shows it as an example primes the seats to write it.
    if ! grep -rqF '@localhost' "$personas_dir"; then
        ok "no persona file contains @localhost"
    else
        no "no persona file contains @localhost" "found '@localhost' in fleet/personas/"
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
