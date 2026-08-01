#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "$0")/.." && pwd)
output_directory="$project_root/build/global-array-mutation"
source_file="$project_root/tests/cases/modules/global-array-mutation.ab"
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
opt --threads=1 -passes=verify -disable-output "$output_directory/program.ll"
"$compiler" build "$source_file" -o "$output_directory/program" --no-cache

set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' 'global arrays: direct/field/alias append + complete var replacement passed verified LLVM'
