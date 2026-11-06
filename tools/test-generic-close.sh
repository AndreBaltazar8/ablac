#!/usr/bin/env bash
# Contextual > splitting never changes expression operators or shared lexer data.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
cd "$root"
out=$root/build/generic-close
mkdir -p "$out"
fixture=$root/tests/cases/generic-close/main.ab
for mode in --fast --o1; do
    "$compiler" build "$fixture" "$mode" --no-cache -o "$out/main"
    set +e
    output=$("$out/main")
    status=$?
    set -e
    [[ $status == 42 && $output == 'generic closes: passed' ]] || {
        printf 'generic closes (%s): status %s: %s\n' "$mode" "$status" "$output" >&2
        exit 1
    }
done
"$compiler" build "$root/tests/cases/generic-close/parser.ab" --fast --no-cache -o "$out/parser"
set +e
output=$("$out/parser")
status=$?
set -e
[[ $status == 42 && $output == 'generic closes parser: passed' ]] || {
    printf 'generic closes parser: status %s: %s\n' "$status" "$output" >&2
    exit 1
}
"$compiler" fmt - < "$fixture" > "$out/formatted.ab"
"$compiler" fmt - < "$out/formatted.ab" > "$out/twice.ab"
cmp "$out/formatted.ab" "$out/twice.ab"
"$compiler" build "$out/formatted.ab" --fast --no-cache -o "$out/formatted"
set +e
output=$("$out/formatted")
status=$?
set -e
[[ $status == 42 && $output == 'generic closes: passed' ]]
printf 'generic closes: native fast/O1, shared tokens, negative syntax and fmt passed\n'
