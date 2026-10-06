#!/usr/bin/env bash
# exit(code) and panic(message) end the process from any call depth.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/process-exit"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/process-exit.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program" > "$output_directory/plain.out"
plain=$?
"$output_directory/program" exit > "$output_directory/exit.out"
exited=$?
"$output_directory/program" panic > "$output_directory/panic.out" \
    2> "$output_directory/panic.err"
panicked=$?
set -e
[[ $plain -eq 42 && $exited -eq 7 && $panicked -eq 101 ]] || exit 1
grep -q '^start$' "$output_directory/exit.out"
grep -qx 'panic: deep failure' "$output_directory/panic.err"
echo "process exit: exit(code) and panic(message) from any depth"
