#!/usr/bin/env bash
# Compile-time code is a program the compiler runs with no arguments: reading the
# arguments under `#` needs no grant and sees none.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compile-time-arguments"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/compile-time-arguments.ab" \
    -o "$output_directory/program" --no-cache
[[ $("$output_directory/program") == "0 | 0" ]] || exit 1
[[ $("$output_directory/program" one two) == "2 one two | 0" ]] || exit 1
echo "compile-time arguments: staged code sees no arguments"
