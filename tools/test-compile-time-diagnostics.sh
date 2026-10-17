#!/usr/bin/env bash
# What a failed build says: a compile-time evaluation failure names its file,
# line and column and is the whole diagnosis (no code-generation noise after
# it); positions count characters; a missing entry file and a program with
# no main each say so once, with the error count matching the error lines.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases=$project_root/tests/cases/diagnostics
output=$project_root/build/compile-time-diagnostics
rm -rf "$output"
mkdir -p "$output"

fail() {
    echo "compile-time diagnostics: $1" >&2
    cat "$2" >&2
    exit 1
}

# build <case> <log>: the build must fail; the summary's total must match
# the error lines.
build_fails() {
    if (cd "$cases" && "$compiler" build "$1" -o "$output/program" --no-cache) \
        >"$2" 2>&1; then
        fail "$1 built" "$2"
    fi
    local errors total
    errors=$(grep -c '^error\[' "$2" || true)
    total=$(sed -nE 's/.* ([0-9]+) total error.*/\1/p' "$2")
    [[ -z $total || $errors -eq $total ]] || fail "$1: $errors error lines, $total counted" "$2"
}

log=$output/index.log
build_fails compile-time-index.ab "$log"
[[ $(grep -c '^error\[' "$log") -eq 1 ]] || fail "index: not one error" "$log"
grep -q '^error\[E_EVAL_EXPRESSION\]: compile-time evaluation failed' "$log" ||
    fail "index: no evaluation error" "$log"
grep -q '^source\[eval\]:compile-time-index.ab:48:61$' "$log" || fail "index: no record" "$log"
grep -q '^  --> compile-time-index.ab:1:49$' "$log" || fail "index: no line:column" "$log"
! grep -qE 'E_IR_|E_LLVM_' "$log" || fail "index: code-generation noise" "$log"
grep -q '1 semantic, 0 IR, 1 total' "$log" || fail "index: summary" "$log"

log=$output/unicode.log
build_fails unicode-column.ab "$log"
# The first record's line and column, counted in characters from its offset.
record=$(grep -m1 '^source\[semantic\]:unicode-column.ab:' "$log") || fail "unicode: no record" "$log"
begin=$(echo "$record" | awk -F: '{ print $(NF-1) }')
before=$(head -c "$begin" "$cases/unicode-column.ab")
line=$(( $(printf '%s' "$before" | wc -l) + 1 ))
column=$(( $(printf '%s' "$before" | tail -n1 | LC_ALL=en_US.UTF-8 wc -m) + 1 ))
[[ $(printf '%s' "$before" | tail -n1 | wc -c) -gt $column ]] ||
    fail "unicode: the case has no multibyte character before the error" "$log"
grep -q "^  --> unicode-column.ab:$line:$column\$" "$log" ||
    fail "unicode: expected unicode-column.ab:$line:$column" "$log"

log=$output/no-main.log
build_fails no-main.ab "$log"
[[ $(grep -c '^error\[' "$log") -eq 1 ]] || fail "no-main: not one error" "$log"
grep -q '^error\[E_NO_MAIN\]' "$log" || fail "no-main: no E_NO_MAIN" "$log"

log=$output/missing.log
build_fails missing.ab "$log"
grep -q '^error\[E_SOURCE_NOT_FOUND\]: no such file: missing.ab$' "$log" ||
    fail "missing: not reported" "$log"
! grep -q 'E_NO_MAIN' "$log" || fail "missing: reported as no main" "$log"
if (cd "$cases" && "$compiler" run missing.ab) >"$log" 2>&1; then fail "run missing ran" "$log"; fi
grep -q 'E_SOURCE_NOT_FOUND' "$log" || fail "run missing: not reported" "$log"

echo "compile-time diagnostics: located, counted, no code-generation noise"
