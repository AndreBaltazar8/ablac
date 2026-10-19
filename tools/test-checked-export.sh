#!/usr/bin/env bash
# Checked exports from C: results, contained panics (runtime ones and `panic`),
# message prefixes and full lengths, invalid result pointers, calls after a panic.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory=$project_root/build/checked-export
cases=$project_root/tests/cases/checked-export
mkdir -p "$output_directory"

library=$output_directory/libchecked.so
if [[ $(uname -s) == Darwin ]]; then library=$output_directory/libchecked.dylib; fi
"$compiler" build "$cases/library.ab" --emit shared-library -o "$library" --no-cache
clang "$cases/caller.c" -L"$output_directory" -lchecked \
    -Wl,-rpath,"$output_directory" -o "$output_directory/caller"

set +e
ABLA_MAX_MEMORY_MB=256 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/caller"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

# The same foreign ABI must work on ELF and both Mach-O architectures.
abi_library=$output_directory/libabla_app.so
if [[ $(uname -s) == Darwin ]]; then abi_library=$output_directory/libabla_app.dylib; fi
"$compiler" build "$project_root/tests/cases/program-build/exported-library.ab" \
    --emit shared-library -o "$abi_library" --no-cache
clang "$project_root/tests/cases/program-build/export-caller.c" \
    -L"$output_directory" -labla_app -Wl,-rpath,"$output_directory" \
    -o "$output_directory/foreign-caller"
"$output_directory/foreign-caller"
echo "foreign export: owned bytes survive GC, concatenation, callbacks, and checked results"
