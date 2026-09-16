#!/usr/bin/env bash
# lkml-fleet.sh — Run fork-sandbox against lkml-review's fleet registry.
#
# Usage: lkml-fleet.sh <fork-sandbox arguments...>
#
# Sets lkml-review's persona directory and a private fleet-file path before
# passing every argument to fork-sandbox. The fleet file is optional: persona
# frontmatter alone is enough for `fleet expand` and postmaster delivery.
# Set LKML_FLEET_FILE to use a different optional fleet file for one command.
#
# The wrapper resolves its own location, so a symlink installed on PATH still
# selects the personas from this checkout. It refuses a missing directory
# before invoking fork-sandbox, rather than allowing an empty panel later.

set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo_dir="$(readlink -f "$script_dir/..")"
personas_dir="$repo_dir/fleet/personas"

usage() {
    sed -n '2,/^set -euo/{ /^#/s/^# \?//p }' "$0"
}

case "${1-}" in
    -h|--help) usage; exit 0 ;;
esac

if [[ ! -d "$personas_dir" ]]; then
    echo "Error: lkml fleet personas directory '$personas_dir' does not exist." >&2
    exit 1
fi

export FORK_SANDBOX_PERSONAS_DIR="$personas_dir"
export FORK_SANDBOX_FLEET_FILE="${LKML_FLEET_FILE:-$HOME/.config/lkml/fleet.yaml}"

exec fork-sandbox "$@"
