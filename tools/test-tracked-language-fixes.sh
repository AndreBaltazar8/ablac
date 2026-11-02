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
expect_error invalid-import-unquoted E_IMPORT_PATH_UNQUOTED
if grep -q E_EVAL_DIVISION_BY_ZERO "$output/invalid-import-unquoted.log"; then
    echo 'an unquoted import still reports a division by zero' >&2
    exit 1
fi
expect_error invalid-transform-method-effects compile.effect-denied:filesystem.write
echo "tracked language fixes: pass"
