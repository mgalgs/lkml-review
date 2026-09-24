#!/usr/bin/env bash
# lkml-series-check-test.sh — Exercise lkml-series-check.sh against a real,
# throwaway git repo. Every scenario is a small range of real commits above
# a "frozen" boundary commit, so the checker reads real objects.
#
# Usage: tests/lkml-series-check-test.sh
#
# Covers:
#   - a clean series exits 0 and prints nothing.
#   - each violation exits 1 and the printed line names the commit:
#     fixup!/squash!/amend! subjects, a merge commit, an empty range, a
#     boundary that is not an ancestor.
#   - comment-only detection: a docstring-only .py change is a violation,
#     the same with a `Comment-only:` trailer is clean, a .py change that
#     alters code as well as a comment is clean, an unparseable .py is
#     clean (conservative), a `//` comment change in another language is a
#     violation, a .md-only change is clean, a mixed commit is clean, and
#     added files, a preprocessor `#` line in a C file and a chmod are not
#     comment-only.
#   - usage and git errors exit 2, --help prints the header.

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
checker="$repo_dir/scripts/lkml-series-check.sh"

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
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed."; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed."; exit 0; }

work="$(mktemp -d)"; tmpdirs+=("$work")

# fresh_repo <name>: a repo whose frozen boundary commit holds a spread of
# files, tagged `frozen`. Sets $r.
fresh_repo() {
    r="$work/$1"
    git init -q -b main "$r"
    git -C "$r" config user.name "Test Author"
    git -C "$r" config user.email "author@example.com"
    git -C "$r" config commit.gpgsign false
    mkdir -p "$r/docs" "$r/src"
    cat > "$r/src/mod.py" <<'EOF'
"""Module docstring."""


def add(a, b):
    """Add two numbers."""
    # plain comment
    return a + b
EOF
    printf 'int main(void)\n{\n\t/* old */\n\treturn 0;\n}\n' > "$r/src/main.c"
    printf '#include <stdio.h>\n' > "$r/src/inc.c"
    printf 'const x = 1;\n// old note\n' > "$r/src/app.js"
    printf '# Title\n\nSome docs.\n' > "$r/README.md"
    printf 'notes\n' > "$r/docs/guide"
    printf 'echo hi\n' > "$r/src/run.sh"
    git -C "$r" add -A
    git -C "$r" commit -q -m "frozen: the reviewed pull request"
    git -C "$r" tag frozen
}

# commit <msg> [more -m args]: commit whatever is staged.
commit() { git -C "$r" -c commit.gpgsign=false commit -q -m "$@"; }
stage() { git -C "$r" add -A; }

# run_check: runs the checker over frozen..HEAD, sets OUT and RC.
run_check() {
    OUT="$("$checker" --repo "$r" --boundary "${1:-frozen}" "${2:-HEAD}" 2>&1)"; RC=$?
}

expect_clean() {
    run_check
    check "$1: exits 0" "0" "$RC"
    check "$1: prints nothing" "" "$OUT"
}
expect_violation() {
    local label="$1" subject="$2" why="$3"
    run_check
    check "$label: exits 1" "1" "$RC"
    contains "$label: names the commit" "$OUT" "$(git -C "$r" rev-parse --short HEAD) $subject: "
    contains "$label: says why" "$OUT" "$why"
}

printf '\n== a clean series ==\n'
fresh_repo clean
printf 'def sub(a, b):\n    return a - b\n' >> "$r/src/mod.py"; stage
commit "mod: add sub()"
printf 'const y = 2;\n' >> "$r/src/app.js"; stage
commit "app: add y"
expect_clean "two ordinary commits"
check "explicit sha boundary works too" "0" \
    "$("$checker" --repo "$r" --boundary "$(git -C "$r" rev-parse frozen)" "$(git -C "$r" rev-parse HEAD)" >/dev/null 2>&1; echo $?)"

printf '\n== fixup!/squash!/amend! subjects ==\n'
for kind in fixup squash amend; do
    fresh_repo "kind-$kind"
    printf 'const z = 3;\n' >> "$r/src/app.js"; stage
    commit "$kind! app: add y"
    expect_violation "$kind! subject" "$kind! app: add y" "fold it into the commit it belongs to"
done

printf '\n== the violation lines are per commit ==\n'
fresh_repo multi
printf 'const a = 1;\n' >> "$r/src/app.js"; stage
commit "fixup! one"
first="$(git -C "$r" rev-parse --short HEAD)"
printf 'const b = 1;\n' >> "$r/src/app.js"; stage
commit "squash! two"
run_check
check "two bad commits: exits 1" "1" "$RC"
check "two bad commits: two lines" "2" "$(printf '%s\n' "$OUT" | wc -l | tr -d '[:space:]')"
contains "two bad commits: first is named" "$OUT" "$first fixup! one: "

printf '\n== an empty range ==\n'
fresh_repo empty
run_check
check "empty range: exits 1" "1" "$RC"
contains "empty range: says so" "$OUT" "no commits above the boundary"

printf '\n== a boundary that is not an ancestor ==\n'
fresh_repo notanc
printf 'const q = 1;\n' >> "$r/src/app.js"; stage
commit "on main"
git -C "$r" checkout -q -b rewritten frozen
git -C "$r" -c commit.gpgsign=false commit -q --allow-empty -m "the rewritten frozen commit"
printf 'const w = 1;\n' >> "$r/src/app.js"; stage
commit "series commit on the rewritten base"
run_check main
check "not an ancestor: exits 1" "1" "$RC"
contains "not an ancestor: says why" "$OUT" "the frozen commits were rewritten or the series is not on the boundary"
contains "not an ancestor: names the tip" "$OUT" "$(git -C "$r" rev-parse --short HEAD) series commit on the rewritten base: "

printf '\n== a merge commit ==\n'
fresh_repo merge
git -C "$r" checkout -q -b side
printf 'side\n' > "$r/src/side.txt"; stage
commit "side: add a file"
git -C "$r" checkout -q main
printf 'const m = 1;\n' >> "$r/src/app.js"; stage
commit "main: add m"
git -C "$r" merge -q --no-ff -m "Merge branch 'side'" side
expect_violation "merge commit" "Merge branch 'side'" "merge commit"

printf '\n== comment-only: python docstring ==\n'
fresh_repo pydoc
sed -i 's/Add two numbers\./Add two numbers, returning the sum./' "$r/src/mod.py"; stage
commit "mod: reword the docstring"
expect_violation "docstring-only .py change" "mod: reword the docstring" "changes only comments"

fresh_repo pydoc-trailer
sed -i 's/Add two numbers\./Add two numbers, returning the sum./' "$r/src/mod.py"; stage
commit "mod: reword the docstring" -m "The docstring in the frozen commit misdescribes the return value." \
    -m "Comment-only: the code being documented is in a frozen commit"
expect_clean "the same with a Comment-only: trailer"

fresh_repo pydoc-glued-trailer
sed -i 's/Add two numbers\./Add two numbers, returning the sum./' "$r/src/mod.py"; stage
commit "mod: reword the docstring" -m "The docstring misdescribes the return value.
Comment-only: the code being documented is in a frozen commit"
expect_clean "a Comment-only: line glued to a body paragraph counts"

fresh_repo pydoc-empty-trailer
sed -i 's/Add two numbers\./Add two numbers, returning the sum./' "$r/src/mod.py"; stage
commit "mod: reword the docstring" -m "Comment-only:"
expect_violation "an empty Comment-only: reason does not count" "mod: reword the docstring" "changes only comments"

printf '\n== comment-only: python # comment ==\n'
fresh_repo pycomment
sed -i 's/# plain comment/# a better comment/' "$r/src/mod.py"; stage
commit "mod: reword a comment"
expect_violation "# comment-only .py change" "mod: reword a comment" "changes only comments"

printf '\n== a python change that alters code as well as a comment ==\n'
fresh_repo pycode
sed -i 's/# plain comment/# a better comment/; s/return a + b/return b + a/' "$r/src/mod.py"; stage
commit "mod: swap the operands"
expect_clean "code + comment change in .py"

printf '\n== an unparseable python file ==\n'
fresh_repo pybroken
printf 'def broken(:\n' > "$r/src/bad.py"; stage
commit "bad: add a file that does not parse" >/dev/null
git -C "$r" tag base2
printf '# another comment\ndef broken(:\n' > "$r/src/bad.py"; stage
commit "bad: touch it again"
run_check base2
check "unparseable .py: exits 0 (conservative)" "0" "$RC"
check "unparseable .py: prints nothing" "" "$OUT"

printf '\n== comment-only: other languages ==\n'
fresh_repo jscomment
sed -i 's#// old note#// a clearer note#' "$r/src/app.js"; stage
commit "app: reword a comment"
expect_violation "// comment-only .js change" "app: reword a comment" "changes only comments"

fresh_repo cblock
sed -i 's#/\* old \*/#/* new */#' "$r/src/main.c"; stage
commit "main: reword a block comment"
expect_violation "/* */ comment-only .c change" "main: reword a block comment" "changes only comments"

fresh_repo cpreproc
sed -i 's/<stdio.h>/<stdlib.h>/' "$r/src/inc.c"; stage
commit "inc: switch the include"
expect_clean "an #include change in a C file is code"

# `#` opens a comment only in file types that use it; a changed `#` line in
# any other file is code and must never be refused.
hash_is_code() {
    local file="$1" old="$2" new="$3"
    fresh_repo "hashcode-${file//[^A-Za-z0-9]/_}"
    printf 'first\n%s\n' "$old" > "$r/src/$file"; git -C "$r" add -A; commit "add $file" >/dev/null
    git -C "$r" tag -f frozen >/dev/null
    printf 'first\n%s\n' "$new" > "$r/src/$file"; stage
    commit "$file: change a hash line"
    expect_clean "a changed # line in $file is code"
}
hash_is_code board.dts '#address-cells = <1>;' '#address-cells = <2>;'
hash_is_code entry.S '#define X 1' '#define X 2'
hash_is_code style.css '#hdr { color: red; }' '#hdr { color: blue; }'
hash_is_code priv.js '#priv = 1;' '#priv = 2;'
hash_is_code unlisted.xyz '#anything 1' '#anything 2'

fresh_repo yamlcomment
printf '# old\nkey: 1\n' > "$r/src/conf.yaml"; git -C "$r" add -A; commit "add conf" >/dev/null
git -C "$r" tag -f frozen >/dev/null
printf '# new\nkey: 1\n' > "$r/src/conf.yaml"; stage
commit "conf: reword a comment"
expect_violation "# comment-only .yaml change" "conf: reword a comment" "changes only comments"

fresh_repo makecomment
printf '# old\nall:\n' > "$r/src/Makefile"; git -C "$r" add -A; commit "add Makefile" >/dev/null
git -C "$r" tag -f frozen >/dev/null
printf '# new\nall:\n' > "$r/src/Makefile"; stage
commit "Makefile: reword a comment"
expect_violation "# comment-only Makefile change" "Makefile: reword a comment" "changes only comments"

fresh_repo shcomment
printf '# now with a comment\necho hi\n' > "$r/src/run.sh"; stage
commit "run: document it"
expect_violation "# comment-only .sh change" "run: document it" "changes only comments"

fresh_repo shshebang
printf '#!/bin/sh\necho hi\n' > "$r/src/run.sh"; git -C "$r" add -A; commit "run: add a shebang" >/dev/null
git -C "$r" tag -f frozen >/dev/null
sed -i '1s|.*|#!/usr/bin/env bash|' "$r/src/run.sh"; stage
commit "run: use env bash"
expect_clean "a shebang change in a shell script is code"

fresh_repo shdash
printf 'tool \\\n  --beta 2\n' > "$r/src/run.sh"; git -C "$r" add -A; commit "run: add a call" >/dev/null
git -C "$r" tag -f frozen >/dev/null
sed -i 's/--beta 2/--beta 3/' "$r/src/run.sh"; stage
commit "run: bump beta"
expect_clean "a -- option continuation line in a shell script is code"

fresh_repo sqlcomment
printf 'select 1;\n-- old note\n' > "$r/src/q.sql"; git -C "$r" add -A; commit "q: add a query" >/dev/null
git -C "$r" tag -f frozen >/dev/null
sed -i 's/old note/a clearer note/' "$r/src/q.sql"; stage
commit "q: reword a comment"
expect_violation "-- comment-only .sql change" "q: reword a comment" "changes only comments"

fresh_repo jscode
sed -i 's#// old note#// a clearer note#; s/const x = 1;/const x = 2;/' "$r/src/app.js"; stage
commit "app: change x"
expect_clean "code + comment change in .js"

printf '\n== documentation is real content ==\n'
fresh_repo md
printf '# Title\n\nSome better docs.\n' > "$r/README.md"; stage
commit "readme: improve the docs"
expect_clean ".md-only change"

fresh_repo docsdir
printf '// notes\n' > "$r/docs/guide"; stage
commit "docs: touch the guide"
expect_clean "a change under docs/"

printf '\n== other things that are not comment-only ==\n'
fresh_repo added
printf '// just a comment file\n' > "$r/src/new.js"; stage
commit "new: add a comment-only file"
expect_clean "an added file"

fresh_repo removed
git -C "$r" rm -q src/app.js
commit "app: drop it"
expect_clean "a deleted file"

fresh_repo chmod
git -C "$r" update-index --chmod=+x src/run.sh
commit "run: make it executable"
expect_clean "a mode-only change"

fresh_repo mixed
sed -i 's#// old note#// a clearer note#' "$r/src/app.js"
printf 'a second file\n' > "$r/README.md"; stage
commit "app: reword a comment and rewrite the readme"
expect_clean "a comment change alongside a real change in another file"

printf '\n== usage and git errors exit 2 ==\n'
fresh_repo usage
printf 'const u = 1;\n' >> "$r/src/app.js"; stage
commit "app: add u"
"$checker" --boundary frozen HEAD >/dev/null 2>&1; check "no --repo" "2" "$?"
"$checker" --repo "$r" HEAD >/dev/null 2>&1; check "no --boundary" "2" "$?"
"$checker" --repo "$r" --boundary frozen >/dev/null 2>&1; check "no tip" "2" "$?"
"$checker" --repo "$r" --boundary nosuchref HEAD >/dev/null 2>&1; check "unknown boundary" "2" "$?"
"$checker" --repo "$r" --boundary frozen nosuchref >/dev/null 2>&1; check "unknown tip" "2" "$?"
"$checker" --repo "$work/not-a-repo" --boundary frozen HEAD >/dev/null 2>&1; check "not a repo" "2" "$?"
"$checker" --repo "$r" --boundary frozen --bogus HEAD >/dev/null 2>&1; check "unknown option" "2" "$?"

printf '\n== --help ==\n'
h_out="$("$checker" --help 2>&1)"; h_rc=$?
check "--help exits 0" "0" "$h_rc"
contains "--help prints the header" "$h_out" "lkml-series-check.sh — Refuse a series that is not a clean re-roll."

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
