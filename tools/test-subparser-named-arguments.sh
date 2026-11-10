#!/usr/bin/env bash
# A subparser builds a call's named arguments with syntaxNamedArgument, and they
# are the ones the parser builds for `f(name = value)`: reordered names, skipped
# defaults and positional-then-named calls work, at run time and under `#`, with
# the interpreter and with native compile-time code; each E_NAMED_ARGUMENT_* error
# is reported at the subparser's site; a named argument outside a call's argument
# list is refused.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/subparser-named-arguments"
output_directory="$project_root/build/subparser-named-arguments"
rm -rf "$output_directory"
mkdir -p "$output_directory"

fail() {
    echo "subparser named arguments: $1" >&2
    exit 1
}

for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/main.ab" \
        -o "$output_directory/main-$mode" || fail "main.ab did not build ($mode)"
    set +e
    output=$("$output_directory/main-$mode")
    status=$?
    set -e
    [[ $status -eq 42 && $output == "341 251 687 1279" ]] ||
        fail "$mode: status $status, output: $output"
done

# case code: the error's code, "-" when the refusal is the subparser's own
expect_error() {
    local name=$1 code=$2 file="$cases/error-$1.ab"
    local log="$output_directory/error-$name.err"
    for mode in interp jit; do
        if ABLA_COMPILE_EVAL=$mode "$compiler" build "$file" \
            -o "$output_directory/error-$name" > "$log" 2>&1; then
            fail "$name ($mode): the build succeeded"
        fi
        grep -q "$code" "$log" || { cat "$log" >&2; fail "$name ($mode): no $code"; }
        # The error is located inside the subparser's text, `$name()`, in main.
        local site
        site=$(grep -m1 -E 'source\[(named-argument|extension-expression)\]' "$log" || true)
        [[ -n $site ]] || { cat "$log" >&2; fail "$name ($mode): no source location"; }
        local begin end text
        begin=$(sed -E 's/.*:([0-9]+):([0-9]+)$/\1/' <<< "$site")
        end=$(sed -E 's/.*:([0-9]+):([0-9]+)$/\2/' <<< "$site")
        text=$(head -c "$end" "$file" | tail -c +"$((begin + 1))")
        [[ $end -gt $begin && $text == *"\$$name()"* ]] ||
            { cat "$log" >&2; fail "$name ($mode): location $begin:$end is not the site (got: $text)"; }
    done
}

expect_error unknown E_NAMED_ARGUMENT_UNKNOWN
expect_error order E_NAMED_ARGUMENT_ORDER
expect_error arity E_NAMED_ARGUMENT_ARITY
expect_error duplicate E_NAMED_ARGUMENT_DUPLICATE
expect_error required E_NAMED_ARGUMENT_REQUIRED
expect_error notarget E_NAMED_ARGUMENT_TARGET
expect_error inarray E_SUBPARSER_NAMED_ARGUMENT
expect_error bare E_SUBPARSER_NAMED_ARGUMENT
expect_error nested E_SUBPARSER_NAMED_ARGUMENT
expect_error badname E_EVAL_EXPRESSION
echo "subparser named arguments: reordered, skipped and mixed calls; every error at the site"
