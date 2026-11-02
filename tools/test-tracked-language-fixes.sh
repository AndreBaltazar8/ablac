#!/usr/bin/env bash
# when arms returning globals, aliases through `export import`, named calls through
# implicit `this`, nominal ints as indexes and in receiver capture, reserved words
# as names, a method named `transform` under `#compiler.transform`, and an import
# path without quotes.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
output="$project_root/build/tracked-language-fixes"
cases="$project_root/tests/cases/modules"
mkdir -p -- "$output"

expect_exit() { # fixture, status
    "$compiler" build "$cases/$1.ab" -o "$output/$1"
    local status=0
    "$output/$1" || status=$?
    if [[ $status -ne $2 ]]; then
        printf '%s returned %d, expected %d\n' "$1" "$status" "$2" >&2
        exit 1
    fi
}
expect_error() { # fixture, text
    local status=0
    "$compiler" build "$cases/$1.ab" -o "$output/$1" >"$output/$1.log" 2>&1 || status=$?
    if [[ $status -eq 0 ]] || ! grep -qF -- "$2" "$output/$1.log"; then
        printf '%s: expected a failure with: %s\n' "$1" "$2" >&2
        cat "$output/$1.log" >&2
        exit 1
    fi
}

expect_exit when-returns-globals 42
expect_error invalid-when-returns-parameter ownership.managed-return-borrow-contract
expect_exit import-alias-export 42
expect_error invalid-import-alias-export-ambiguous E_IMPORT_ALIAS_MEMBER_AMBIGUOUS
expect_error invalid-import-alias-export-unknown E_IMPORT_ALIAS_MEMBER_UNKNOWN
expect_error invalid-import-alias-export-private E_IMPORT_ALIAS_MEMBER_UNKNOWN
expect_exit named-implicit-this 42
expect_exit named-default-scope 42
expect_exit constructor-array-interface 42
expect_exit nullable-array-field 42
expect_exit nullable-function-type 42
expect_exit function-value-result-return 42
expect_error invalid-closure-argument-fnmut 'declare the parameter `var g: FnMut() -> int`'
expect_exit default-closure-two-callers 42
expect_error invalid-named-default-hidden-generic E_NAMED_ARGUMENT_HIDDEN
expect_exit named-default-hidden-value 42
expect_error invalid-call-not-function call.not-function:double
expect_error invalid-call-not-function-field call.not-function:scale
expect_exit operator-annotation-after 42
expect_exit lambda-inferred-result 42
expect_exit nominal-index 42
expect_error invalid-nominal-index index.type
expect_exit nominal-method-capture 42
expect_error invalid-reserved-generator '`generator` is a reserved word'
expect_error invalid-reserved-generator '`task` is a reserved word'
expect_error invalid-reserved-generator '`thread` is a reserved word'
expect_exit transform-method-effects 42
expect_exit address-taken-unreachable 0
if ! grep -aq used-function-text "$output/address-taken-unreachable" ||
    grep -aq dead-function-text "$output/address-taken-unreachable"; then
    echo 'a function only unreachable code takes the value of is in the program' >&2
    exit 1
fi
# A compiler started with no runtime in reach says so, and a failed thread creation does.
if [[ -x $compiler.bin ]]; then
    empty=$(mktemp -d "$output/no-sysroot.XXXXXX")
    printf 'fun main: int = 7\n' > "$empty/m.ab"
    status=0
    (cd "$empty" && env -u ABLA_SYSROOT -u ABLA_STDLIB "$compiler.bin" build m.ab -o m --no-cache) >"$empty/log" 2>&1 || status=$?
    if [[ $status -eq 0 ]] || ! grep -q E_TOOLCHAIN_ROOT "$empty/log"; then
        echo 'a compiler with no runtime in reach did not say so' >&2
        cat "$empty/log" >&2
        exit 1
    fi
fi
"$compiler" build "$cases/concurrency.ab" -o "$output/concurrency-limited"
status=0
(ulimit -s 131072; ABLA_MAX_MEMORY_MB=128 "$project_root/tools/run-limited.sh" "$output/concurrency-limited") \
    >"$output/concurrency-limited.log" 2>&1 || status=$?
if [[ $status -ne 101 ]] || ! grep -q "a thread couldn't start" "$output/concurrency-limited.log"; then
    printf 'a thread that cannot start: status %d\n' "$status" >&2
    cat "$output/concurrency-limited.log" >&2
    exit 1
fi
expect_exit transform-implicit-this 42
expect_exit compile-effect-unmade-implementer 42
expect_error invalid-compile-effect-made-implementer compile.effect-denied:
expect_error invalid-transform-failing-loop E_EVAL_EXPRESSION
if (( $(wc -l <"$output/invalid-transform-failing-loop.log") > 200 )) ||
    grep -q E_EVAL_STEP_LIMIT "$output/invalid-transform-failing-loop.log"; then
    echo 'a failing loop in compile-time code ran on, or its report is not short' >&2
    wc -l "$output/invalid-transform-failing-loop.log" >&2
    exit 1
fi
expect_error invalid-import-unquoted E_IMPORT_PATH_UNQUOTED
if grep -q E_EVAL_DIVISION_BY_ZERO "$output/invalid-import-unquoted.log"; then
    echo 'an unquoted import still reports a division by zero' >&2
    exit 1
fi
expect_error invalid-transform-method-effects compile.effect-denied:filesystem.write
echo "tracked language fixes: pass"
