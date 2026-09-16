#!/usr/bin/env bash
# lkml-fleet-status-test.sh — Exercise lkml-fleet-status.sh against a
# fixture agent-mail store built by writing .msg files directly. The
# fleet message format is plain text (a header block, a blank line, the
# body verbatim), so no part of this suite needs fork-sandbox present;
# a stub on PATH stands in for the one allowed external call,
# `fork-sandbox fleet expand`, the same "stub the external command on
# PATH" pattern tests/lkml-fleet-kickoff-test.sh uses.
#
# Fixture fleet: @author posts; @ci and (via the @panel list)
# @review-one and @review-three reply; @review-two sits on the panel and
# never speaks; @maintainer is Cc'd on the kickoff and never speaks.
#
# Usage: tests/lkml-fleet-status-test.sh

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
status="$repo_dir/scripts/lkml-fleet-status.sh"

pass=0; fail=0; tmpdirs=()
cleanup() { local d; for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ok "$label" ;;
        *) no "$label" "'$needle' not found in: $haystack" ;;
    esac
}
not_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) no "$label" "'$needle' found in: $haystack" ;;
        *) ok "$label" ;;
    esac
}
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}

work="$(mktemp -d)"; tmpdirs+=("$work")

t1="11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
t2="11111111-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
t3="33333333-cccc-4ccc-8ccc-cccccccccccc"

root="$work/store1"
mkdir -p -- "$root/threads/$t1" "$root/threads/$t2" "$root/threads/.stray"
root2="$work/store2"
mkdir -p -- "$root2/threads/$t3"

# write_msg <store> <thread> <nnn> <id> <date> <from> <to> <cc> <subject>
#            <hops> <in-reply-to> <body>
write_msg() {
    local store="$1" t="$2" nnn="$3" id="$4" date="$5" from="$6" to="$7" cc="$8" subj="$9" hops="${10}" irt="${11}" body="${12}"
    local f="$store/threads/$t/$nnn-$id.msg"
    {
        printf 'Message-ID: %s\n' "$id"
        printf 'Thread-ID: %s\n' "$t"
        printf 'Date: %s\n' "$date"
        printf 'From: %s\n' "$from"
        printf 'To: %s\n' "$to"
        [[ -n "$cc" ]] && printf 'Cc: %s\n' "$cc"
        printf 'Subject: %s\n' "$subj"
        [[ -n "$irt" ]] && printf 'In-Reply-To: %s\n' "$irt"
        printf 'X-Hops: %s\n' "$hops"
        printf '\n'
        printf '%s\n' "$body"
    } > "$f"
}

D() { printf 'Mon, 02 Mar 2026 10:%02d:00 +0000' "$1"; }

# thread t1: a two-version patch review with one unanswered NAK
write_msg "$root" "$t1" 001 b0010000-0000-4000-8000-000000000001 "$(D 0)" \
    '@author' '@ci,@panel' '@maintainer' '[PATCH v1 0/2] Improve the thing' 8 '' \
    'Cover letter for v1.'
write_msg "$root" "$t1" 002 b0020000-0000-4000-8000-000000000002 "$(D 1)" \
    '@author' '@ci,@panel' '' '[PATCH v1 1/2] Add the feature' 8 b0010000-0000-4000-8000-000000000001 \
    'The v1 diff.'
write_msg "$root" "$t1" 003 b0030000-0000-4000-8000-000000000003 "$(D 2)" \
    '@ci' '@author' '' 'Re: [PATCH v1 0/2] Improve the thing' 7 b0010000-0000-4000-8000-000000000001 \
    'Suite green on both patches.

Tested-by: CI'
write_msg "$root" "$t1" 004 b0040000-0000-4000-8000-000000000004 "$(D 3)" \
    '@review-one' '@author' '' 'Re: [PATCH v1 1/2] Add the feature' 7 b0020000-0000-4000-8000-000000000002 \
    'The error path is untested.

Changes-requested'
write_msg "$root" "$t1" 005 b0050000-0000-4000-8000-000000000005 "$(D 4)" \
    '@author' '@review-one' '' 'Re: [PATCH v1 1/2] Add the feature' 6 b0040000-0000-4000-8000-000000000004 \
    'Fair -- reworked, see v2.'
write_msg "$root" "$t1" 006 b0060000-0000-4000-8000-000000000006 "$(D 5)" \
    '@author' '@ci,@panel' '' '[PATCH v2 0/2] Improve the thing' 6 b0050000-0000-4000-8000-000000000005 \
    'Version two.'
write_msg "$root" "$t1" 007 b0070000-0000-4000-8000-000000000007 "$(D 6)" \
    '@review-one' '@author' '' 'Re: [PATCH v2 0/2] Improve the thing' 5 b0060000-0000-4000-8000-000000000006 \
    'Looks good now.

Reviewed-by: Review One'
write_msg "$root" "$t1" 008 b0080000-0000-4000-8000-000000000008 "$(D 7)" \
    '@author' '@ci,@panel' '' '[PATCH v2 1/2] Add the feature' 5 b0060000-0000-4000-8000-000000000006 \
    'The improved diff.'
write_msg "$root" "$t1" 009 b0090000-0000-4000-8000-000000000009 "$(D 8)" \
    '@review-one' '@author' '' 'Re: [PATCH v2 1/2] Add the feature' 4 b0080000-0000-4000-8000-000000000008 \
    'Question: is the lock order documented?

Question'
# 010 replies to the Question from a DIFFERENT sender -> answered
write_msg "$root" "$t1" 010 b0100000-0000-4000-8000-000000000010 "$(D 9)" \
    '@author' '@review-one' '' 'Re: [PATCH v2 1/2] Add the feature' 3 b0090000-0000-4000-8000-000000000009 \
    'Yes, section 4 of the doc.'
write_msg "$root" "$t1" 011 b0110000-0000-4000-8000-000000000011 "$(D 10)" \
    '@review-one' '@author' '' 'Re: [PATCH v2 1/2] Add the feature' 2 b0100000-0000-4000-8000-000000000010 \
    'NAK: still missing the race test.

NAK'
# 012 replies to the NAK but from the SAME sender -> still unanswered
write_msg "$root" "$t1" 012 b0120000-0000-4000-8000-000000000012 "$(D 11)" \
    '@review-one' '@author' '' 'Re: [PATCH v2 1/2] Add the feature' 1 b0110000-0000-4000-8000-000000000011 \
    'I will add that test.'
write_msg "$root" "$t1" 013 b0130000-0000-4000-8000-000000000013 "$(D 12)" \
    '@review-three' '@author' '' 'Re: [PATCH v2 0/2] Improve the thing' 5 b0060000-0000-4000-8000-000000000006 \
    'The naming is inconsistent.

Changes-requested'
write_msg "$root" "$t1" 014 b0140000-0000-4000-8000-000000000014 "$(D 13)" \
    '@author' '@review-three' '' 'Re: [PATCH v2 0/2] Improve the thing' 4 b0130000-0000-4000-8000-000000000013 \
    'Renamed as asked.'
write_msg "$root" "$t1" 015 b0150000-0000-4000-8000-000000000015 "$(D 14)" \
    '@review-three' '@author' '' 'Re: [PATCH v2 0/2] Improve the thing' 4 b0140000-0000-4000-8000-000000000014 \
    'Good.

Reviewed-by: Review Three'

# a second thread sharing t1's 8-hex prefix (ambiguity fixture)
write_msg "$root" "$t2" 001 c0010000-0000-4000-8000-000000000001 'Tue, 03 Mar 2026 09:00:00 +0000' \
    '@author' '@panel' '' 'Unrelated thread' 8 '' 'Something else entirely.'

# a stray dot-directory under threads/ with a plausible-looking message:
# must not be rendered as a thread
write_msg "$root" '.stray' 001 d0010000-0000-4000-8000-000000000001 "$(D 0)" \
    '@author' '@panel' '' 'Should not appear' 8 '' 'scratch state, not mail.'

# store2: a single-message, version-less thread, NO .postmaster at all
write_msg "$root2" "$t3" 001 e0010000-0000-4000-8000-000000000001 "$(D 0)" \
    '@author' '@panel' '' 'Discussion: where to keep the state' 8 '' 'No patches here.'

# Stub fork-sandbox: only the one call the script is allowed to make.
stub_bin="$work/stub"; mkdir -p -- "$stub_bin"
cat > "$stub_bin/fork-sandbox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == "fleet" && "${2-}" == "expand" ]]; then
    case "${3-}" in
        @panel) printf '%s\n' '@review-one' '@review-three' '@review-two' ;;
        @author|@ci|@review-one|@review-three|@review-two) printf '%s\n' "${3-}" ;;
        *) echo "Error: expand: unknown address '${3}'." >&2; exit 1 ;;
    esac
    exit 0
fi
echo "Error: unexpected fork-sandbox invocation: $*" >&2
exit 1
STUB
chmod +x -- "$stub_bin/fork-sandbox"
STUB_PATH="$stub_bin:$PATH"

# Snapshot the whole store: every path, and every file's content.
snapshot_store() {
    {
        (cd "$1" && find . | sort)
        (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null)
    }
}

printf '\n== --help and usage errors ==\n'
OUT="$(PATH="$STUB_PATH" "$status" --help 2>&1)"; RC=$?
check "--help exits 0" "0" "$RC"
contains "--help prints the usage line" "$OUT" "Usage: lkml-fleet-status.sh"

PATH="$STUB_PATH" "$status" >/dev/null 2>&1
check "no arguments exits non-zero" "1" "$?"

OUT="$(PATH="$STUB_PATH" "$status" 99999999 --mail-root "$root" 2>&1)"; RC=$?
if (( RC != 0 )); then ok "unknown thread-id exits non-zero"; else no "unknown thread-id exits non-zero" "exit 0"; fi
contains "unknown thread-id names the root it looked in" "$OUT" "$root"

OUT="$(PATH="$STUB_PATH" "$status" 11111111 --mail-root "$root" 2>&1)"; RC=$?
if (( RC != 0 )); then ok "ambiguous prefix exits non-zero"; else no "ambiguous prefix exits non-zero" "exit 0"; fi
contains "ambiguous prefix names candidate t1" "$OUT" "$t1"
contains "ambiguous prefix names candidate t2" "$OUT" "$t2"

OUT="$(PATH="$STUB_PATH" "$status" --mail-root "$work/no-such-root" --list 2>&1)"; RC=$?
if (( RC != 0 )); then ok "missing mail root exits non-zero"; else no "missing mail root exits non-zero" "exit 0"; fi
contains "missing mail root names the path it wanted" "$OUT" "$work/no-such-root"

printf '\n== --list: one line per thread ==\n'
OUT="$(PATH="$STUB_PATH" "$status" --list --mail-root "$root" 2>&1)"; RC=$?
check "--list exits 0" "0" "$RC"
check "--list prints one line per thread" "2" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
contains "--list shows t1's short id" "$OUT" "1111111"
contains "--list shows t2's root Subject" "$OUT" "Unrelated thread"
contains "--list shows t1's root Subject" "$OUT" "[PATCH v1 0/2] Improve the thing"
contains "--list shows t1's newest date" "$OUT" "$(D 14)"
not_contains "--list does not render the dot-directory as a thread" "$OUT" ".stray"

printf '\n== the screen: header, versions, seats, unanswered ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "$t1" --mail-root "$root" 2>&1)"; RC=$?
check "thread screen exits 0" "0" "$RC"
contains "header: short id and root Subject" "$OUT" "Thread: 1111111  [PATCH v1 0/2] Improve the thing"
contains "header: total message count" "$OUT" "Messages: 15"
contains "header: date span oldest..newest" "$OUT" "$(D 0) .. $(D 14)"
contains "versions: v1 first seen and count" "$OUT" "v1  first seen $(D 0)  5 messages"
contains "versions: v2 first seen and count" "$OUT" "v2  first seen $(D 5)  10 messages"
not_contains "versions: the token is not doubled" "$OUT" "vv"

contains "seats: @author sent count" "$OUT" '@author  sent 7'
contains "seats: @ci latest tag" "$OUT" '@ci  sent 1  last '"$(D 2)"'  tags: Tested-by'
LINE="$(grep -F '@review-one ' <<<"$OUT" | head -n1)"
contains "seats: @review-one latest tag is the NAK" "$LINE" "tags: NAK"
LINE="$(grep -F '@review-three ' <<<"$OUT" | head -n1)"
contains "seats: superseding Reviewed-by reported" "$LINE" "tags: Reviewed-by"
not_contains "seats: superseded Changes-requested not reported" "$LINE" "Changes-requested"

contains "never-replied: panel member reached only via the list" "$OUT" '@review-two (via @panel)'
contains "never-replied: direct Cc address that never sent" "$OUT" '@maintainer (unexpanded)'
not_contains "never-replied: a sending seat is not listed" "$OUT" '@review-one (via'
not_contains "never-replied: a sending list member is not listed" "$OUT" '@review-three (via'

contains "unanswered: the unanswered NAK is listed" "$OUT" 'b011000  @review-one  NAK  Re: [PATCH v2 1/2] Add the feature'
not_contains "unanswered: Question answered by a different sender is not listed" "$OUT" "b009000"
not_contains "unanswered: Changes-requested answered by a different sender is not listed" "$OUT" "b004000"
not_contains "unanswered: no convergence verdict is printed" "$OUT" "converged"

printf '\n== a thread that is not a patch series ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "$t3" --mail-root "$root2" 2>&1)"; RC=$?
check "version-less thread screen exits 0" "0" "$RC"
contains "version-less thread says so" "$OUT" "(no version in any Subject"
not_contains "version-less thread is not given an invented v1" "$OUT" "v1  first seen"

printf '\n== prefix resolution ==\n'
OUT="$(PATH="$STUB_PATH" "$status" "${t1:0:12}" --mail-root "$root" 2>&1)"; RC=$?
check "unambiguous prefix resolves" "0" "$RC"
contains "unambiguous prefix shows the resolved screen" "$OUT" "Thread: 1111111"

printf '\n== the script writes nothing ==\n'
BEFORE="$(snapshot_store "$root")"
PATH="$STUB_PATH" "$status" "$t1" --mail-root "$root" >/dev/null 2>&1
PATH="$STUB_PATH" "$status" --list --mail-root "$root" >/dev/null 2>&1
AFTER="$(snapshot_store "$root")"
check "store is byte-identical after runs" "$BEFORE" "$AFTER"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
