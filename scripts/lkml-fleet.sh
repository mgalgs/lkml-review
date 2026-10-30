#!/usr/bin/env bash
# lkml-fleet.sh — Run fork-sandbox against lkml-review's fleet registry.
#
# Usage: lkml-fleet.sh <fork-sandbox arguments...>
#
# Sets lkml-review's persona directory, its prompts directory (the shared
# protocol files a persona names with `protocol:`, e.g. protocol-reviewer.md)
# and a private fleet-file path before passing every argument to
# fork-sandbox. The fleet file is optional: persona frontmatter alone is
# enough for `fleet expand` and postmaster delivery.
# Set LKML_FLEET_FILE to use a different optional fleet file for one command.
#
# A cluster postmaster deploy (`k8s install ... --postmaster`, or
# `k8s upgrade-postmaster`) defaults to ~/.config/lkml/fleet-cluster.yaml
# instead, since the cluster can run only k8s seats, and is refused when that
# file is missing rather than falling back to the local fleet. This default is
# interim: it goes away once a deploy repository's CI owns postmaster installs.
#
# The wrapper resolves its own location, so a symlink installed on PATH still
# selects the personas and prompts from this checkout. It refuses a missing
# personas or prompts directory before invoking fork-sandbox, rather than
# allowing an empty panel, or seats without their protocol, later.

set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo_dir="$(readlink -f "$script_dir/..")"
personas_dir="$repo_dir/fleet/personas"
prompts_dir="$repo_dir/fleet/prompts"

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
if [[ ! -d "$prompts_dir" ]]; then
    echo "Error: lkml fleet prompts directory '$prompts_dir' does not exist." >&2
    exit 1
fi

default_fleet="$HOME/.config/lkml/fleet.yaml"
if [[ "${1-}" == k8s ]]; then
    cluster_deploy=false
    case "${2-}" in
        upgrade-postmaster) cluster_deploy=true ;;
        install)
            for arg in "${@:3}"; do
                if [[ "$arg" == --postmaster ]]; then cluster_deploy=true; fi
            done
            ;;
    esac
    if $cluster_deploy; then
        default_fleet="$HOME/.config/lkml/fleet-cluster.yaml"
        if [[ -z "${LKML_FLEET_FILE-}" && ! -f "$default_fleet" ]]; then
            echo "Error: a cluster postmaster deploy ships $default_fleet, which does" >&2
            echo "not exist. Create it, or set LKML_FLEET_FILE." >&2
            exit 1
        fi
    fi
fi

export FORK_SANDBOX_PERSONAS_DIR="$personas_dir"
export FORK_SANDBOX_PROMPTS_DIR="$prompts_dir"
export FORK_SANDBOX_FLEET_FILE="${LKML_FLEET_FILE:-$default_fleet}"

exec fork-sandbox "$@"
