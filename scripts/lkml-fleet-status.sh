#!/usr/bin/env bash
# lkml-fleet-status.sh — One screen: where a fleet-transport review stands
#
# Usage: lkml-fleet-status.sh <thread-id> [--mail-root <dir>]
#        lkml-fleet-status.sh --list [--mail-root <dir>]
#
# The fleet counterpart of lkml-status.sh: that one screen, for threads in
# the agent-mail store ($FORK_SANDBOX_MAIL_ROOT, default
# /var/tmp/claude-scratch/agent-mail). This script is a READER: it writes
# nothing anywhere -- no temp files in the store, no caches, no flag
# files.
#
# It runs under `set -uo pipefail`, not the repo's usual
# `set -euo pipefail`. That is deliberate, and the reason is the whole
# point of the script: a screen that degrades is worth more than a screen
# that aborts. One unreadable message, or a `fork-sandbox fleet expand`
# that cannot resolve an address, shows up as a gap in the output rather
# than taking the entire report down with it. Failures the operator must
# not miss still exit: `die` covers a bad argument, a missing mail root,
# and a thread id that is unknown or ambiguous. Do not "fix" this to -e
# without re-reading those two sentences.
#
# <thread-id> may be given in full or as any unambiguous prefix, the way
# lkml-mailbox.sh accepts a short id. --list prints every thread in the
# store, one per line (short id, message count, the root message's
# Subject, the newest message's date): how an operator finds the id to
# pass. --mail-root overrides $FORK_SANDBOX_MAIL_ROOT.
#
# This script REPORTS STATE. It does not judge convergence: it never
# computes "converged / ready / done", never weighs one seat's verdict
# against another's, and never decides whether a NAK still stands. That
# model is owned by a separate implementation; a second, local copy here
# would produce a second answer that disagrees with it, which is worse
# than having none. What this screen prints is observable fact: who
# sent, who was addressed, what was tagged, what is unanswered.
#
# Screen sections, in order:
#   header     short id, root message's Subject, message count, date span
#   versions   each v<N> found in a Subject, with the date it first
#              appeared and how many messages carry it. Where no Subject
#              carries a version the thread is not a patch series, and is
#              said so in one line rather than given an invented v1.
#   seats      one row per sender: messages sent, date of its latest, the
#              tags it has applied; then, separately, every address that
#              was To/Cc'd but has never sent. That set is the most useful
#              thing on the screen: a seat that was woken and never spoke
#              is indistinguishable from one that agreed, and those are
#              opposite states.
#   hop and spawns  the lowest and newest X-Hops values, plus the router's
#              resettable spawn budget and never-reset sequence. A router
#              stop is printed loudly with its reason; absent router state
#              is distinguished from an exhausted budget.
#   cost per agent  completed router runs, grouped by agent. Runs without a
#              summary stay visible as "no summary", summaries with no
#              usable cost field (absent, null, or the wrong JSON type)
#              stay visible as "no cost", and summaries that could not be
#              parsed at all -- because python3 itself is unavailable, or
#              because the file is truncated, corrupt, or unreadable --
#              stay visible as "unreadable". None of the three is folded
#              into another: each is a different kind of not knowing, and
#              collapsing them would misreport which.
#   unanswered see the design decision below.
#
# Design decision -- tags: Reviewed-by, Acked-by, Tested-by,
# Changes-requested, Question, NAK are the lore convention already used
# across this repo, detected as line-initial occurrences in the message
# body the way lkml-mailbox.sh infers them: the three -by trailers count
# anywhere in the body, while the verdicts (Changes-requested, Question,
# NAK) count only on the first or last non-empty, non-quoted line, since
# a verdict opens a reply or closes it, and a quoted verdict (" > NAK")
# is not this reply's. The LATEST tag per seat is reported, not every tag
# ever applied, for the reason lkml-mailbox.sh's tally documents: a
# Changes-requested is routinely superseded by a later Reviewed-by from
# the same seat once the request is met, and reporting both would make a
# settled thread look permanently stuck.
#
# Design decision -- unanswered: a tagged message (Question,
# Changes-requested or NAK) is listed when no direct reply (In-Reply-To)
# comes from a DIFFERENT sender. The store cannot know who the message
# was addressed to -- that lives in prose -- so silence from anyone else
# is the closest computable proxy, the same one lkml-mailbox.sh open
# uses. It points at candidates; deciding who should actually answer is
# a person's job, not this script's. They are not called blockers.
#
# Dot-directories under <root>/threads/ are router/scratch state, not
# threads, and are ignored, like lkml-render.py does.

set -uo pipefail

MAIL_ROOT="${FORK_SANDBOX_MAIL_ROOT:-/var/tmp/claude-scratch/agent-mail}"

usage() {
    sed -n '2,/^set -uo/{ /^#/s/^# \?//p }' "$0"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

list_mode=0
thread_arg=""
while (( $# > 0 )); do
    case "$1" in
        --list) list_mode=1 ;;
        --mail-root)
            (( $# >= 2 )) || die "--mail-root requires a directory."
            MAIL_ROOT="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option '$1'. See --help." ;;
        *)
            [[ -z "$thread_arg" ]] || die "only one thread id may be given (got '$thread_arg' and '$1')."
            thread_arg="$1" ;;
    esac
    shift
done

(( list_mode )) || [[ -n "$thread_arg" ]] || { usage >&2; exit 1; }
[[ -d "$MAIL_ROOT" ]] || die "mail root '$MAIL_ROOT' does not exist (override with --mail-root or FORK_SANDBOX_MAIL_ROOT)."

# Thread ids are the names of directories under threads/. Dot-directories
# are router/scratch state, not threads, and are skipped.
list_threads() {
    local d name
    [[ -d "$MAIL_ROOT/threads" ]] || return 0
    for d in "$MAIL_ROOT/threads"/*/; do
        [[ -e "$d" ]] || continue
        name="${d%/}"; name="${name##*/}"
        [[ "$name" == .* ]] && continue
        printf '%s\n' "$name"
    done
}

# Resolves a (possibly abbreviated) thread id into RESOLVED, or errors:
# unknown (naming the root it looked in) or ambiguous (naming the
# candidates). An exact name always wins over prefix matches.
RESOLVED=""
resolve_thread() {
    local arg="$1" cand
    for cand in $(list_threads); do
        if [[ "$cand" == "$arg" ]]; then
            RESOLVED="$cand"
            return 0
        fi
    done
    local match="" count=0 cands=""
    for cand in $(list_threads); do
        if [[ "$cand" == "$arg"* ]]; then
            match="$cand"; count=$(( count + 1 ))
            cands+="$cand  "
        fi
    done
    if (( count == 0 )); then
        die "no thread matching '$arg' under '$MAIL_ROOT/threads'."
    elif (( count > 1 )); then
        die "thread id prefix '$arg' is ambiguous; candidates: $cands"
    fi
    RESOLVED="$match"
}

# Prints one header's value from a message file, or nothing if absent.
# Reads only up to the first blank line, which is where headers end.
fs_header() {
    local file="$1" name="$2" line
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        if [[ "$line" == "$name:"* ]]; then
            printf '%s' "${line#"$name": }"
            return 0
        fi
    done < "$file"
    return 0
}

# The v<N> tokens a Subject carries, one per line, deduplicated. The
# leading non-alphanumeric guard keeps "IPv4" out while letting the
# lore "[PATCH v2 0/7]" form (and a bare "v2") through.
fs_subject_versions() {
    printf '%s\n' "$1" | grep -oE '(^|[^[:alnum:]])v[0-9]+' | sed 's/^.*v//' | sort -un
}

# The tags a message body carries, space-separated in canonical order
# (Reviewed-by Acked-by Tested-by Changes-requested Question NAK), or
# nothing. Trailers count anywhere in the body; the verdicts count only
# on the first or last non-empty, non-quoted line (see the header
# comment). Quoted lines never count: a quoted verdict belongs to the
# message being quoted.
fs_body_tags() {
    awk '
        BEGIN {
            nt = split("Reviewed-by Acked-by Tested-by", T, " ")
            nv = split("Changes-requested Question NAK", V, " ")
        }
        /^$/ { body = 1; next }
        !body { next }
        /^[[:space:]]*>/ { next }
        NF == 0 { next }
        {
            line = $0
            if (first == "") first = line
            last = line
            for (i = 1; i <= nt; i++)
                if (line ~ ("^" T[i] "([[:space:]:.!,]|$)")) t_seen[i] = 1
        }
        END {
            for (i = 1; i <= nv; i++)
                if (first ~ ("^" V[i] "([[:space:]:.!,]|$)") ||
                    last ~ ("^" V[i] "([[:space:]:.!,]|$)")) v_seen[i] = 1
            out = ""
            for (i = 1; i <= nt; i++) if (i in t_seen) out = out T[i] " "
            for (i = 1; i <= nv; i++) if (i in v_seen) out = out V[i] " "
            if (out != "") print out
        }
    ' "$1"
}

# Loads every message of the resolved thread into the MSG_* arrays, in
# arrival order. File names are "<NNN>-<uuid>.msg" with NNN a fixed-width
# 3-digit arrival sequence, so plain lexicographic order IS arrival
# order (until a thread passes 999 messages).
MSG_FILE=(); MSG_NNN=(); MSG_ID=(); MSG_DATE=(); MSG_FROM=()
MSG_TO=(); MSG_CC=(); MSG_SUBJ=(); MSG_IRT=(); MSG_HOPS=(); MSG_TAGS=()
load_thread() {
    local t="$1" f base id
    local dir="$MAIL_ROOT/threads/$t"
    for f in "$dir"/*.msg; do
        [[ -e "$f" ]] || continue
        base="${f##*/}"
        id="${base#*-}"; id="${id%.msg}"
        MSG_NNN+=("${base%%-*}")
        MSG_ID+=("$id")
        MSG_DATE+=("$(fs_header "$f" Date)")
        MSG_FROM+=("$(fs_header "$f" From)")
        MSG_TO+=("$(fs_header "$f" To)")
        MSG_CC+=("$(fs_header "$f" Cc)")
        MSG_SUBJ+=("$(fs_header "$f" Subject)")
        MSG_IRT+=("$(fs_header "$f" In-Reply-To)")
        MSG_HOPS+=("$(fs_header "$f" X-Hops)")
        MSG_TAGS+=("$(fs_body_tags "$f")")
        MSG_FILE+=("$f")
    done
    (( ${#MSG_FILE[@]} > 0 )) || die "thread '$t' has no messages."
}

# Counts records in a router state file.  The caller checks readability so
# zero here means a readable, empty file rather than an unreadable one.
router_line_count() {
    local file="$1" line count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        count=$(( count + 1 ))
    done < "$file"
    printf '%s' "$count"
}

# Router state is intentionally read as files instead of through a
# postmaster command: this reporter remains useful where that command is
# absent.  A partial or unreadable state is reported as unknown, never as a
# plausible-looking zero.
print_hop_and_spawns() {
    local i hop lowest="" newest="${MSG_HOPS[$(( n - 1 ))]}"
    local pm spawn_file seq_file flag_file spawns seq reason

    printf '\n== Hop and Spawns ==\n'
    for (( i = 0; i < n; i++ )); do
        hop="${MSG_HOPS[$i]}"
        [[ "$hop" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$lowest" || "$hop" -lt "$lowest" ]]; then
            lowest="$hop"
        fi
    done
    if [[ -n "$lowest" && "$newest" =~ ^[0-9]+$ ]]; then
        printf 'hops: lowest %s, newest %s\n' "$lowest" "$newest"
    else
        echo 'hops: unknown (missing or malformed X-Hops)'
    fi

    pm="$MAIL_ROOT/.postmaster"
    if [[ ! -d "$pm" ]]; then
        echo '(no router state for this thread -- not routed yet)'
        return 0
    fi

    spawn_file="$pm/spawns/$RESOLVED"
    seq_file="$pm/seq/$RESOLVED"
    flag_file="$pm/needs-operator/$RESOLVED"
    if [[ -e "$flag_file" ]]; then
        if [[ -r "$flag_file" ]]; then
            reason="$(< "$flag_file")"
            [[ -n "$reason" ]] || reason='unknown reason'
        else
            reason='unknown reason (flag unreadable)'
        fi
        printf 'NEEDS OPERATOR: %s\n' "$reason"
        echo 'This thread will not restart until someone mails into it.'
    fi

    if [[ ! -r "$spawn_file" || ! -r "$seq_file" ]]; then
        echo '(router state unknown -- missing or unreadable budget files)'
        return 0
    fi
    spawns="$(router_line_count "$spawn_file")"
    seq="$(router_line_count "$seq_file")"
    printf 'spawns (budget): %s\n' "$spawns"
    printf 'seq (never reset): %s\n' "$seq"
    printf 'seq - spawns = %s (zeroed by an operator mail)\n' "$(( seq - spawns ))"

}

# Prints " (X no summary, Y no cost, Z unreadable)" for whichever counts
# are non-zero, or nothing at all if all three are zero.  Shared between
# the totals line and each per-agent row so the three states are joined
# identically in both places.
fs_cost_annotation() {
    local missing="$1" no_cost="$2" unreadable="$3" joined
    local parts=()
    (( missing > 0 )) && parts+=("$missing no summary")
    (( no_cost > 0 )) && parts+=("$no_cost no cost")
    (( unreadable > 0 )) && parts+=("$unreadable unreadable")
    (( ${#parts[@]} == 0 )) && return 0
    printf -v joined '%s, ' "${parts[@]}"
    printf ' (%s)' "${joined%, }"
}

# The router writes its run ledger as KEY=value files.  Read those values
# directly rather than sourcing them: router state is data, not shell code.
print_cost_per_agent() {
    local pm="$MAIL_ROOT/.postmaster" env line key value agent thread run_dir
    local prev total_runs=0 missing_summary=0 no_cost=0 unreadable=0
    local have_python=1 run_word
    declare -A RUN_COUNT=() MISSING_COUNT=() NO_COST_COUNT=() UNREADABLE_COUNT=() COST_BY_AGENT=()
    local parse_agents=() parse_paths=()

    printf '\n== Cost per agent ==\n'
    if [[ ! -d "$pm/runs" ]]; then
        echo '(no runs recorded)'
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || have_python=0
    for env in "$pm/runs"/*.env; do
        [[ -r "$env" ]] || continue
        agent=""; thread=""; run_dir=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == *=* ]] || continue
            key="${line%%=*}"
            value="${line#*=}"
            case "$key" in
                agent|AGENT) agent="$value" ;;
                thread|THREAD|thread_id|THREAD_ID) thread="$value" ;;
                run_dir|RUN_DIR) run_dir="$value" ;;
            esac
        done < "$env"
        [[ "$thread" == "$RESOLVED" ]] || continue
        [[ -n "$agent" ]] || agent='unknown agent'
        total_runs=$(( total_runs + 1 ))
        RUN_COUNT[$agent]=$(( ${RUN_COUNT[$agent]:-0} + 1 ))
        if [[ -z "$run_dir" || ! -f "$run_dir/summary.json" ]]; then
            missing_summary=$(( missing_summary + 1 ))
            MISSING_COUNT[$agent]=$(( ${MISSING_COUNT[$agent]:-0} + 1 ))
            continue
        fi
        if (( ! have_python )); then
            unreadable=$(( unreadable + 1 ))
            UNREADABLE_COUNT[$agent]=$(( ${UNREADABLE_COUNT[$agent]:-0} + 1 ))
            continue
        fi
        parse_agents+=("$agent")
        parse_paths+=("$run_dir/summary.json")
    done

    if (( total_runs == 0 )); then
        echo '(no runs recorded)'
        return 0
    fi

    # One interpreter for the whole ledger, not one per summary file: seq/
    # is never reset (see Hop and Spawns above), so a thread's run count
    # only grows, and a per-file fork that is invisible at ten runs comes
    # to dominate this section at hundreds. Each path prints exactly one
    # result line, in argv order, so the loop below can zip it back onto
    # the (agent, path) pair recorded above -- but only once the batch is
    # confirmed intact: a python3 that fails to run, or dies partway
    # through, must not be allowed to desync that zip and silently
    # misattribute one run's fate to another's.
    if (( ${#parse_paths[@]} > 0 )); then
        local results py_rc res
        local -a result_lines=()
        results="$(python3 -c '
import json, sys

# A routed continuation includes the prior context cost in total_cost_usd.
# Older summaries have only cost_usd. A JSON bool is excluded explicitly:
# isinstance(True, int) is true in Python, and a JSON true would
# otherwise be summed as 1. A file that cannot be opened or parsed as
# JSON is reported separately from one that parses but has no usable
# cost field: the two are different kinds of not knowing.
for path in sys.argv[1:]:
    try:
        data = json.load(open(path))
    except Exception:
        print("UNREADABLE")
        continue
    result = "NOCOST"
    try:
        for key in ("total_cost_usd", "cost_usd"):
            value = data.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                continue
            # Fixed-point, never exponent notation: repr() switches to
            # exponent form below 1e-4, which would fail the plain-digit
            # gate below and misreport a known, tiny, real cost as
            # unknown. This does not gate out extreme magnitudes either
            # (a huge value is still a real number, just an ugly one) --
            # it only tells a real number apart from the two sentinels
            # above.
            result = format(value, "f")
            break
    except Exception:
        pass
    print(result)
' "${parse_paths[@]}" 2>/dev/null)" && py_rc=0 || py_rc=$?
        if [[ -n "$results" ]]; then
            while IFS= read -r res; do
                result_lines+=("$res")
            done <<< "$results"
        fi
        if (( py_rc != 0 )) || (( ${#result_lines[@]} != ${#parse_paths[@]} )); then
            # python3 exited non-zero, or produced a different number of
            # result lines than paths given to it (a crash partway
            # through, an OOM kill, a broken shim on PATH that runs but
            # writes nothing): there is no reliable way to tell which
            # line belonged to which path, so nothing in this batch is
            # trusted as "no cost" -- every path in it is unreadable.
            for agent in "${parse_agents[@]}"; do
                unreadable=$(( unreadable + 1 ))
                UNREADABLE_COUNT[$agent]=$(( ${UNREADABLE_COUNT[$agent]:-0} + 1 ))
            done
        else
            for i in "${!result_lines[@]}"; do
                res="${result_lines[$i]}"
                agent="${parse_agents[$i]}"
                if [[ "$res" == "UNREADABLE" ]]; then
                    unreadable=$(( unreadable + 1 ))
                    UNREADABLE_COUNT[$agent]=$(( ${UNREADABLE_COUNT[$agent]:-0} + 1 ))
                elif [[ "$res" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                    prev="${COST_BY_AGENT[$agent]:-0}"
                    COST_BY_AGENT[$agent]="$(awk -v a="$prev" -v b="$res" 'BEGIN { printf "%.6f", a + b }')"
                else
                    no_cost=$(( no_cost + 1 ))
                    NO_COST_COUNT[$agent]=$(( ${NO_COST_COUNT[$agent]:-0} + 1 ))
                fi
            done
        fi
    fi

    if (( unreadable > 0 )); then
        if (( ! have_python )); then
            echo '(python3 not found: those summaries could not be parsed and are counted as unreadable)'
        else
            echo '(some summary.json files could not be parsed and are counted as unreadable)'
        fi
    fi
    printf 'runs: %s%s\n' "$total_runs" "$(fs_cost_annotation "$missing_summary" "$no_cost" "$unreadable")"
    for agent in $(printf '%s\n' "${!RUN_COUNT[@]}" | sort); do
        run_word=runs
        (( RUN_COUNT[$agent] == 1 )) && run_word=run
        printf '%s  %s %s  $%s%s\n' "$agent" "${RUN_COUNT[$agent]}" "$run_word" "${COST_BY_AGENT[$agent]:-0.000000}" \
            "$(fs_cost_annotation "${MISSING_COUNT[$agent]:-0}" "${NO_COST_COUNT[$agent]:-0}" "${UNREADABLE_COUNT[$agent]:-0}")"
    done
}

# --- --list: one line per thread ------------------------------------------
if (( list_mode )); then
    threads="$(list_threads)"
    if [[ -z "$threads" ]]; then
        die "no threads under '$MAIL_ROOT/threads'."
    fi
    while IFS= read -r cand; do
        dir="$MAIL_ROOT/threads/$cand"
        count="$(find "$dir" -maxdepth 1 -name '*.msg' -type f | wc -l | tr -d ' ')"
        if [[ "$count" -gt 0 ]]; then
            # First by file name == first by arrival seq == the root
            # message; the last one's Date is the newest.
            first="$(find "$dir" -maxdepth 1 -name '*.msg' -type f | sort | head -n1)"
            last="$(find "$dir" -maxdepth 1 -name '*.msg' -type f | sort | tail -n1)"
            subj="$(fs_header "$first" Subject)"
            newest="$(fs_header "$last" Date)"
        else
            subj="-"; newest="-"
        fi
        printf '%s  %3d  %s  %s\n' "${cand:0:7}" "$count" "$subj" "$newest"
    done <<< "$threads"
    exit 0
fi

# --- the screen -------------------------------------------------------------
resolve_thread "$thread_arg"
load_thread "$RESOLVED"
n="${#MSG_FILE[@]}"

printf 'Thread: %s  %s\n' "${RESOLVED:0:7}" "${MSG_SUBJ[0]}"
printf 'Messages: %d   %s .. %s\n' "$n" "${MSG_DATE[0]}" "${MSG_DATE[$(( n - 1 ))]}"

printf '\n== Versions ==\n'
declare -A V_FIRST=() V_COUNT=()
for (( i = 0; i < n; i++ )); do
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        if [[ -z "${V_FIRST[$v]:-}" ]]; then
            V_FIRST[$v]="${MSG_DATE[$i]}"
        fi
        V_COUNT[$v]=$(( ${V_COUNT[$v]:-0} + 1 ))
    done < <(fs_subject_versions "${MSG_SUBJ[$i]}")
done
if (( ${#V_COUNT[@]} == 0 )); then
    echo "(no version in any Subject -- this thread is not a patch series)"
else
    for v in $(printf '%s\n' "${!V_COUNT[@]}" | sort -n); do
        printf 'v%s  first seen %s  %d messages\n' "$v" "${V_FIRST[$v]}" "${V_COUNT[$v]}"
    done
fi

printf '\n== Seats ==\n'
declare -A SEAT_COUNT=() SEAT_LAST=() SEAT_TAGS=()
for (( i = 0; i < n; i++ )); do
    from="${MSG_FROM[$i]}"
    [[ -n "$from" ]] || continue
    SEAT_COUNT[$from]=$(( ${SEAT_COUNT[$from]:-0} + 1 ))
    # Iterating in arrival order, the last write is the seat's latest.
    SEAT_LAST[$from]="${MSG_DATE[$i]}"
    if [[ -n "${MSG_TAGS[$i]}" ]]; then
        SEAT_TAGS[$from]="${MSG_TAGS[$i]%"${MSG_TAGS[$i]##*[! ]}"}"
    fi
done
for s in $(printf '%s\n' "${!SEAT_COUNT[@]}" | sort); do
    printf '%s  sent %d  last %s  tags: %s\n' \
        "$s" "${SEAT_COUNT[$s]}" "${SEAT_LAST[$s]}" "${SEAT_TAGS[$s]:--}"
done

# Addressed but never sent. A list address is turned into its members
# with `fork-sandbox fleet expand` -- the one external call this script
# makes; when it is absent or does not know the address, the address is
# printed unexpanded rather than failing the screen.
declare -A ADDR_SEEN=()
for (( i = 0; i < n; i++ )); do
    for a in ${MSG_TO[$i]//,/ } ${MSG_CC[$i]//,/ }; do
        a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
        [[ -n "$a" ]] && ADDR_SEEN[$a]=1
    done
done
declare -A NEVER=()
have_expand=0
command -v fork-sandbox >/dev/null 2>&1 && have_expand=1
for a in $(printf '%s\n' "${!ADDR_SEEN[@]}" | sort); do
    [[ -n "${SEAT_COUNT[$a]:-}" ]] && continue
    members=""
    if (( have_expand )); then
        members="$(fork-sandbox fleet expand "$a" 2>/dev/null)" || members=""
    fi
    if [[ -n "$members" ]]; then
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            [[ -n "${SEAT_COUNT[$m]:-}" ]] && continue
            if [[ "$m" == "$a" ]]; then
                NEVER[$m]=""
            else
                NEVER[$m]="via $a"
            fi
        done <<< "$members"
    else
        NEVER[$a]="unexpanded"
    fi
done
echo "Addressed, never replied:"
if (( ${#NEVER[@]} == 0 )); then
    echo "  (none -- every address sent to has sent)"
else
    for a in $(printf '%s\n' "${!NEVER[@]}" | sort); do
        if [[ -n "${NEVER[$a]}" ]]; then
            printf '  %s (%s)\n' "$a" "${NEVER[$a]}"
        else
            printf '  %s\n' "$a"
        fi
    done
fi

print_hop_and_spawns
print_cost_per_agent

printf '\n== Unanswered ==\n'
found=0
for (( i = 0; i < n; i++ )); do
    tags=" ${MSG_TAGS[$i]} "
    matched=""
    for t in Question Changes-requested NAK; do
        case "$tags" in
            *" $t "*) matched+="${matched:+, }$t" ;;
        esac
    done
    [[ -n "$matched" ]] || continue
    # The computable proxy, same as lkml-mailbox.sh open: any direct
    # reply from a DIFFERENT sender counts as an answer. Silence from
    # anyone else is the signal; whose job it is to answer is not
    # this script's to decide.
    answered=0
    for (( j = 0; j < n; j++ )); do
        if [[ "${MSG_IRT[$j]}" == "${MSG_ID[$i]}" && "${MSG_FROM[$j]}" != "${MSG_FROM[$i]}" ]]; then
            answered=1
            break
        fi
    done
    if (( ! answered )); then
        found=1
        printf '  %s  %s  %s  %s\n' "${MSG_ID[$i]:0:7}" "${MSG_FROM[$i]}" "$matched" "${MSG_SUBJ[$i]}"
    fi
done
(( found )) || echo "  (none)"
