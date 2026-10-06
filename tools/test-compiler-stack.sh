#!/usr/bin/env bash
# The compiler raises its own stack limit: a deeply nested program builds
# under the default 8 MB soft limit without the build/ablac launcher. A
# program without `fun main` is named as such.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
# The launcher raises the stack itself: test the compiler binary it runs.
payload=$compiler
if [[ -x $compiler.bin ]]; then payload=$compiler.bin; fi
output_directory="$project_root/build/compiler-stack"
mkdir -p "$output_directory"

(
    ulimit -S -s 8192
    "$payload" build "$project_root/tests/cases/modules/deep-nesting.ab" \
        -o "$output_directory/program" --no-cache
)
set +e
"$output_directory/program"
status=$?
"$compiler" build "$project_root/tests/cases/modules/invalid-no-main.ab" \
    -o "$output_directory/no-main" --no-cache \
    > "$output_directory/no-main.out" 2> "$output_directory/no-main.err"
no_main=$?
set -e
[[ $status -eq 42 && $no_main -ne 0 ]] || exit 1
grep -q 'E_NO_MAIN' "$output_directory/no-main.err"
echo "compiler stack: deep nesting builds on an 8 MB soft limit; no main is named"
