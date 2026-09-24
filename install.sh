#!/usr/bin/env bash
# install.sh — Install lkml-review onto this machine.
#
# Usage: install.sh [--check]
#
# (no args) Link the porcelain scripts from this checkout's scripts/
#           into $HOME/.claude/scripts, and symlink skills/lkml-mode
#           into each of the three skill farms:
#             $HOME/.claude/skills      (the claude harness)
#             $HOME/.agents/skills      (the codex harness)
#             $HOME/.pi/agent/skills    (the pi harness)
#           (three because seats run under claude, pi and codex
#           harnesses, and each looks in its own place). Re-running is
#           safe: every link is replaced in place, nothing is appended
#           -- except a target that exists as a real directory, which
#           is refused by name: ln -sfn would create the link INSIDE
#           it and report success, never replacing the stale directory.
# --check   Report, and never gate, the prerequisites: whether
#           ~/.config/lkml/seats.yaml exists, whether
#           ~/.config/lkml/summarize.env exists, and whether
#           $HOME/.claude/scripts is on PATH. A missing config file is
#           a thing to tell someone about, not a broken install, so
#           --check exits 0 regardless. A missing config file with an
#           orphaned copy still at the pre-move location
#           (~/.config/fork-sandbox/lkml-seats.yaml or
#           lkml-summarize.env) is called out by name: that file is
#           not read, and its seals or caps have silently stopped
#           applying.
#
# Only porcelain goes on PATH. Plumbing is reached by its callers
# through their own script_dir (the dirname of the caller's own
# resolved path), which finds this checkout regardless of PATH -- so
# linking plumbing would just clutter shell completion.
#
# The two script lists below are the traced result of following every
# call site, and the install FAILS CLOSED on drift: every regular file
# (or symlink to one) in scripts/ must appear in exactly one list, and
# every name in a list must exist in scripts/. This is what stops a new
# script from being added and silently never installed.
#
# If $HOME/.claude/scripts is not on PATH, the install prints the
# export line to add to your shell profile; it never edits your profile.

set -euo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
scripts_src="$repo_dir/scripts"
skill_src="$repo_dir/skills/lkml-mode"

SCRIPTS_DIR="$HOME/.claude/scripts"
SKILL_FARMS=(
    "$HOME/.claude/skills"
    "$HOME/.agents/skills"
    "$HOME/.pi/agent/skills"
)

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
    lkml-series-check.sh
    lkml-status.sh
    lkml-summarize.sh
)

PLUMBING=(
    lkml-seats-parse.py
    lkml-seats-resolve
    lkml-series-check-py.py
)

usage() {
    sed -n '2,/^set -euo/{ /^#/s/^# \?//p }' "$0"
}

# True when $1 appears as an exact entry of PATH.
path_has() {
    local dir="$1"
    local IFS=':'
    case ":$PATH:" in
        *":$dir:"*) return 0 ;;
    esac
    return 1
}

# Refuse to install when scripts/ and the two lists have drifted apart:
# a file on disk in neither list (a new script nobody added), a listed
# name missing from scripts/ (a renamed or removed script), or a name
# claimed by both lists.
fail_closed_check() {
    local errors=()
    local f name in_p in_l
    for name in "${PORCELAIN[@]}"; do
        for other in "${PLUMBING[@]}"; do
            if [[ "$name" == "$other" ]]; then
                errors+=("listed in BOTH lists: $name")
            fi
        done
    done
    for name in "${PORCELAIN[@]}" "${PLUMBING[@]}"; do
        if [[ ! -f "$scripts_src/$name" ]]; then
            errors+=("listed but missing from scripts/: $name")
        fi
    done
    for f in "$scripts_src"/*; do
        name="${f##*/}"
        [[ -f "$f" ]] || continue
        in_p=0; in_l=0
        for p in "${PORCELAIN[@]}"; do [[ "$p" == "$name" ]] && in_p=1; done
        for p in "${PLUMBING[@]}"; do [[ "$p" == "$name" ]] && in_l=1; done
        if (( in_p + in_l == 0 )); then
            errors+=("in scripts/ but in neither list: $name")
        elif (( in_p + in_l > 1 )); then
            errors+=("in BOTH lists: $name")
        fi
    done
    if (( ${#errors[@]} > 0 )); then
        echo "install: Error: the script lists have drifted from scripts/:" >&2
        for e in "${errors[@]}"; do
            echo "  - $e" >&2
        done
        exit 1
    fi
}

# Refuse a real-directory link target instead of nesting into it:
# ln -sfn treats an existing real directory by creating the symlink
# inside it, exits 0, and prints success -- the stale directory would
# never be replaced, the harness would keep reading it, and every
# re-run would nest one level deeper. (A regular-file target is fine:
# ln -sfn replaces it.)
link_replace() {
    local src="$1" dest="$2"
    if [[ -d "$dest" && ! -L "$dest" ]]; then
        echo "install: Error: $dest already exists and is a real directory, not a symlink." >&2
        echo "install: Move it aside (or remove it) and re-run; a link cannot replace it in place." >&2
        exit 1
    fi
    ln -sfn -- "$src" "$dest"
}

do_install() {
    fail_closed_check
    [[ -d "$skill_src" ]] || { echo "install: Error: $skill_src does not exist." >&2; exit 1; }

    mkdir -p -- "$SCRIPTS_DIR"
    local farm
    for farm in "${SKILL_FARMS[@]}"; do
        mkdir -p -- "$farm"
    done

    local name
    for name in "${PORCELAIN[@]}"; do
        link_replace "$scripts_src/$name" "$SCRIPTS_DIR/$name"
    done
    for farm in "${SKILL_FARMS[@]}"; do
        link_replace "$skill_src" "$farm/lkml-mode"
    done

    echo "install: linked ${#PORCELAIN[@]} porcelain scripts into $SCRIPTS_DIR"
    for farm in "${SKILL_FARMS[@]}"; do
        echo "install: linked $skill_src into $farm"
    done

    if path_has "$SCRIPTS_DIR"; then
        echo "install: $SCRIPTS_DIR is on PATH; the lkml porcelain is ready to run."
    else
        echo "install: $SCRIPTS_DIR is NOT on PATH; add it to your shell profile:"
        echo "  export PATH=\"$SCRIPTS_DIR:\$PATH\""
    fi
}

# Reports what is missing and exits 0 regardless: a missing config file
# is a thing to tell someone about, not a broken install.
do_check() {
    local f old
    for f in "$HOME/.config/lkml/seats.yaml" "$HOME/.config/lkml/summarize.env"; do
        if [[ -f "$f" ]]; then
            echo "check: ok       $f"
        else
            echo "check: MISSING  $f"
            old="$HOME/.config/fork-sandbox/lkml-$(basename -- "$f")"
            if [[ -f "$old" ]]; then
                echo "check:           an older pre-move file remains at $old; it is not read -- move it to $f"
            fi
        fi
    done
    if path_has "$SCRIPTS_DIR"; then
        echo "check: ok       $SCRIPTS_DIR is on PATH"
    else
        echo "check: MISSING  $SCRIPTS_DIR is not on PATH"
        echo "check:           add: export PATH=\"$SCRIPTS_DIR:\$PATH\""
    fi
    exit 0
}

mode="install"
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --check) mode="check" ;;
        *) echo "Error: unknown argument '$arg'. See --help." >&2; exit 1 ;;
    esac
done

if [[ "$mode" == "check" ]]; then
    do_check
else
    do_install
fi
