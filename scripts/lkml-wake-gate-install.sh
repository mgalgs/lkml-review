#!/usr/bin/env bash
# lkml-wake-gate-install.sh — Stage the author seat's wake gate where the
# postmaster looks for hooks.
#
# Usage: lkml-wake-gate-install.sh [--check] [--hooks-dir DIR]
#
# DIR defaults to ${FORK_SANDBOX_HOOKS_DIR:-$HOME/.config/fork-sandbox/hooks}.
#
# (no args) Copy two files out of this checkout's scripts/ into DIR, both
#           mode 0755:
#             lkml-wake-gate.py     -> DIR/wake-when.lkml-panel
#             lkml-panel-state.py   -> DIR/lkml-panel-state.py
#           The gate runs its sibling lkml-panel-state.py, so the two
#           must travel together. Each is written to a temp file in DIR
#           and moved into place, so a half-written gate is never live.
#           Prints what it wrote and touches nothing else in DIR: other
#           projects' hooks live there. DIR must already exist; it is
#           never created, because a missing directory means a
#           misconfigured machine and the loud failure is the feature
#           (exit 1, naming the path).
# --check   Write nothing. Exit 0 when both staged files exist, are
#           executable and are byte-identical to this checkout's copies;
#           otherwise exit 1, listing each missing or stale file. The
#           staged lkml-panel-state.py drifts silently whenever the
#           repo's changes, so run this before a postmaster install.
#
# The checkout is found from this script's own resolved location, so a
# symlink on PATH still stages this checkout's files.

set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

usage() {
    sed -n '2,/^set -euo/{ /^#/s/^# \?//p }' "$0"
}

# repo file : staged name
FILES=(
    "lkml-wake-gate.py:wake-when.lkml-panel"
    "lkml-panel-state.py:lkml-panel-state.py"
)

mode="install"
hooks_dir="${FORK_SANDBOX_HOOKS_DIR:-$HOME/.config/fork-sandbox/hooks}"
while (( $# > 0 )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --check) mode="check" ;;
        --hooks-dir)
            [[ $# -ge 2 ]] || { echo "Error: --hooks-dir needs a directory." >&2; exit 1; }
            hooks_dir="$2"; shift ;;
        *) echo "Error: unknown argument '$1'. See --help." >&2; exit 1 ;;
    esac
    shift
done

if [[ ! -d "$hooks_dir" ]]; then
    echo "Error: hooks directory '$hooks_dir' does not exist; refusing to create it." >&2
    exit 1
fi

for entry in "${FILES[@]}"; do
    src="$script_dir/${entry%%:*}"
    [[ -f "$src" ]] || { echo "Error: '$src' does not exist." >&2; exit 1; }
done

do_check() {
    local entry src dest bad=0
    for entry in "${FILES[@]}"; do
        src="$script_dir/${entry%%:*}"
        dest="$hooks_dir/${entry#*:}"
        if [[ ! -f "$dest" ]]; then
            echo "check: MISSING  $dest"; bad=1
        elif [[ ! -x "$dest" ]]; then
            echo "check: STALE    $dest (not executable)"; bad=1
        elif ! cmp -s -- "$src" "$dest"; then
            echo "check: STALE    $dest (differs from $src)"; bad=1
        else
            echo "check: ok       $dest"
        fi
    done
    exit "$bad"
}

tmp=""
trap '[[ -z "$tmp" ]] || rm -f -- "$tmp"' EXIT

do_install() {
    local entry src dest
    for entry in "${FILES[@]}"; do
        src="$script_dir/${entry%%:*}"
        dest="$hooks_dir/${entry#*:}"
        tmp="$(mktemp "$hooks_dir/.${entry#*:}.XXXXXX")"
        install -m 0755 -- "$src" "$tmp"
        mv -f -- "$tmp" "$dest"
        tmp=""
        echo "install: wrote $dest"
    done
}

if [[ "$mode" == "check" ]]; then
    do_check
else
    do_install
fi
