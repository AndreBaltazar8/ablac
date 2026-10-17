#!/usr/bin/env bash
# An int passed where a narrower integer is expected (a function, method or
# constructor argument) is an error at that argument, with the explicit
# conversion as the fix; an integer literal that fits converts implicitly.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/integer-narrowing"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/integer-narrowing.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-integer-narrowing.ab" \
    > "$output_directory/invalid.ll" 2> "$output_directory/invalid.err"
invalid=$?
set -e
[[ $status -eq 42 && $invalid -ne 0 ]] || exit 1
err=$output_directory/invalid.err
# The constructor, function (a variable, a nominal int, a literal too large,
# a negative literal) and method arguments; the literal that fits is not
# reported.
[[ $(grep -c 'integer.narrowing:' "$err") -eq 6 ]] || { cat "$err" >&2; exit 1; }
grep -q 'integer.narrowing:Pixel@[0-9]*:u8:i64' "$err"
grep -q 'integer.narrowing:take@[0-9]*:u8:i64' "$err"
grep -q 'integer.narrowing:Counter.add@[0-9]*:u16:i64' "$err"
grep -q '^help: .*u8(value)' "$err"
! grep -q 'E_LLVM\|E_IR' "$err"
echo "integer narrowing: implicit at a call only for literals that fit"
