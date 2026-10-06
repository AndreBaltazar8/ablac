#!/usr/bin/env bash
# The compiler raises its own stack limit: a deeply nested program builds
# under the default 8 MB soft limit without the build/ablac launcher.
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
set -e
[[ $status -eq 42 ]] || exit 1
echo "compiler stack: deep nesting builds on an 8 MB soft limit"
