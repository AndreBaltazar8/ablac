#!/usr/bin/env bash
# `if (ablaAtCompileTime()) a else b`: compile-time evaluation takes `a` and
# its effects alone count, so the standard library's raw-memory paths stay out
# of compile-time code (#$jsons, compile funs building text).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compile-time-branch"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/compile-time-branch/buffer.ab" \
    -o "$output_directory/buffer" --no-cache
set +e
"$output_directory/buffer"
status=$?
"$compiler" --emit-llvm \
    "$project_root/tests/cases/compile-time-branch/invalid-native-then.ab" \
    > "$output_directory/invalid.ll" 2> "$output_directory/invalid.err"
invalid_status=$?
set -e
[[ $status -eq 42 ]]
[[ $invalid_status -ne 0 ]]
grep -q 'compile.effect-denied:trusted.native' "$output_directory/invalid.err"
echo "compile-time branch: buffers match, the reachable branch is still checked"
