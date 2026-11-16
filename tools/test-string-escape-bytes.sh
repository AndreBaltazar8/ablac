#!/usr/bin/env bash
# String escapes by the bytes they stand for (tests/cases/string-escape-bytes, a table: \uXXXX is exactly four hex digits, so a hex digit after
# it is text: "\u0000argument" was read as \u0000a plus "rgument", byte 10, #953), at run time and in a # build, fast and release builds;
# and the malformed ones are refused with E_PARSE_INVALID_ESCAPE: a surrogate, a value above 10FFFF, too few digits, an empty or
# unclosed brace, a non-digit, an unknown letter. A copy that expects one byte too many must fail.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/string-escape-bytes"
mkdir -p "$out"
source="$project_root/tests/cases/string-escape-bytes/main.ab"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build "$source" -o "$out/program" $mode --no-cache
    set +e
    "$out/program" > "$out/program.log" 2>&1
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "string escapes: status $status (mode '$mode'):" >&2; cat "$out/program.log" >&2; exit 1; }
done
mutated="$out/mutated.ab"
sed 's|Case("ascii then letters", "\\u0041bc", \[65, 98, 99\])|Case("ascii then letters", "\\u0041bc", [65, 98, 99, 0])|' "$source" > "$mutated"
cmp -s "$mutated" "$source" && { echo "string escapes: the negative control changed nothing" >&2; exit 1; }
"$compiler" build "$mutated" -o "$out/mutated" --fast --no-cache
set +e
"$out/mutated" > "$out/mutated.log" 2>&1
status=$?
set -e
[[ $status -eq 1 ]] && grep -q 'ascii then letters' "$out/mutated.log" ||
    { echo "string escapes: the negative control was not caught" >&2; exit 1; }
# Malformed escapes. (The literal is written into a program with printf %s, so the backslashes arrive as written.)
index=0
while IFS= read -r literal; do
    index=$((index + 1))
    printf 'fun main: int {\n    val s = "%s"\n    s.size\n}\n' "$literal" > "$out/bad-$index.ab"
    set +e
    "$compiler" --emit-llvm "$out/bad-$index.ab" > /dev/null 2> "$out/bad-$index.err"
    status=$?
    set -e
    [[ $status -ne 0 ]] && grep -q 'E_PARSE_INVALID_ESCAPE' "$out/bad-$index.err" ||
        { echo "string escapes: \"$literal\" was not refused with E_PARSE_INVALID_ESCAPE" >&2; cat "$out/bad-$index.err" >&2; exit 1; }
done <<'LITERALS'
\ud800
\udfff
\uDBFFx
\u{d800}
\u{110000}
\u{FFFFFF}
\u{1234567}
\u00e
\u0
\u
\u{}
\u{41
\u{4 1}
\u{g}
\ug000
\xg1
\x1
\x
\q
\e
\a
\1
\z
LITERALS
echo "string escapes: the table holds at run time and under #, and malformed escapes are refused"
