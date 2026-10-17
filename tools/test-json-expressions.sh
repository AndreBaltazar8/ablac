#!/usr/bin/env bash
# `$json` keys and values are Abla expressions (tests/cases/modules/
# json-expressions.ab): locals, calls, operators, nested arrays and objects,
# f64 values and lossless number literals, at run time and at compile time with
# identical bytes. A value of a type JSON cannot hold, a key that is not a
# string, and a malformed literal are diagnosed at the source position, without
# code generation noise.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/json-expressions"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/json-expressions.ab" \
    -o "$output_directory/json-expressions" --no-cache
"$output_directory/json-expressions"

# rejected <name> <expected diagnostic pattern> <offending text> <source>
rejected() {
    local name=$1 pattern=$2 offending=$3 source=$4
    printf '%s\n' "$source" > "$output_directory/$name.ab"
    set +e
    "$compiler" build "$output_directory/$name.ab" \
        -o "$output_directory/$name" --no-cache \
        > "$output_directory/$name.log" 2>&1
    local status=$?
    set -e
    if [[ $status -eq 0 ]] || ! grep -q "$pattern" "$output_directory/$name.log" ||
       grep -q 'E_LLVM\|E_IR_EMISSION' "$output_directory/$name.log"; then
        printf 'json expressions: %s was not diagnosed as expected:\n' "$name" >&2
        cat "$output_directory/$name.log" >&2
        exit 1
    fi
    # The diagnostic's source span starts at the offending text.
    local begin
    begin=$(grep -o "source\[[a-z-]*\]:[^:]*$name.ab:[0-9]*" \
        "$output_directory/$name.log" | head -1 | sed 's/.*://')
    local actual=${source:$begin:${#offending}}
    if [[ $actual != "$offending" ]]; then
        printf 'json expressions: %s points at %q, not %q\n' \
            "$name" "$actual" "$offending" >&2
        cat "$output_directory/$name.log" >&2
        exit 1
    fi
}

rejected class-value 'ablaJsonValue' 'Point(1, 2)' 'import "abla/json"

class Point(val x: int, val y: int)

fun main: int {
    val value = $json {"point": Point(1, 2)}
    value.size()
}'

rejected integer-key 'ablaJsonKey' 'count()' 'import "abla/json"

fun count(): int = 7

fun main: int {
    val value = $json {count(): 1}
    value.size()
}'

rejected missing-colon 'expected `:` after a \$json object key' '1' 'import "abla/json"

fun main: int {
    val value = $json {"a" 1}
    value.size()
}'

echo "json expressions: runtime and staged values, lossless literals, located diagnostics passed"
