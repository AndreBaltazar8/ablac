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
