#!/usr/bin/env bash
# What a failed build says: a compile-time evaluation failure names its file,
# line and column and is the whole diagnosis (no code-generation noise after
# it); positions count characters; a missing entry file and a program with
# no main each say so once, with the error count matching the error lines;
# compile-time effects follow scope.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler=$PWD/$compiler
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
grep -qx 'error\[E_EVAL_OUT_OF_BOUNDS\]: index 7 out of bounds for array of size 3' "$log" ||
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

log=$output/memory.log
build_fails compile-time-memory.ab "$log"
grep -q '^error\[E_EVAL_MEMORY_UNAVAILABLE\]: `runtimeMemoryCollect` has no program heap' "$log" ||
    fail "memory: not denied" "$log"

log=$output/compile-fun.log
build_fails compile-fun-at-run-time.ab "$log"
grep -q '^error\[E_SEMANTIC\]: compile.call-runtime:twice' "$log" ||
    fail "compile fun at run time: not reported" "$log"
! grep -qE 'E_IR_|E_LLVM_' "$log" || fail "compile fun at run time: code-generation noise" "$log"

log=$output/run-time-local.log
build_fails run-time-local-in-compile.ab "$log"
grep -q '^error\[E_SEMANTIC\]: compile.runtime-local:n' "$log" ||
    fail "run-time local in #: not reported" "$log"
! grep -qE 'E_IR_|E_LLVM_|E_EVAL_' "$log" || fail "run-time local in #: noise" "$log"

log=$output/parse-error.log
build_fails parse-error-before-main.ab "$log"
! grep -q 'E_NO_MAIN' "$log" || fail "parse error: a skipped main reported missing" "$log"

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

# Effects follow scope: a parameter or local named like an effectful function
# isn't charged its effects, a call of the function itself is.
log=$output/scoped-effects.log
build_fails scoped-call-effects.ab "$log"
[[ $(grep -c '^error\[E_SEMANTIC\]: compile.effect-denied:' "$log") -eq 2 ]] ||
    fail "scoped effects: not two denials" "$log"
grep -q 'effect-denied:trusted.native:printsInBody->loud->poke->' "$log" ||
    fail "scoped effects: a call beside a lambda parameter not charged" "$log"
grep -q 'effect-denied:trusted.native:printsBeforeLocal->later->poke->' "$log" ||
    fail "scoped effects: a call before a local not charged" "$log"
! grep -q 'allowed\|quiet' "$log" || fail "scoped effects: a parameter charged" "$log"

echo "compile-time diagnostics: located, counted, no code-generation noise"
