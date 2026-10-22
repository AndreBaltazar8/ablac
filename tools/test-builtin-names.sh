#!/usr/bin/env bash
# A program's declaration named like a built-in (Cell, Shared, Mutex, Map,
# filledArray, move) hides the built-in in its module and in its importers, at
# run time and under `#` (both tiers); a module that doesn't import it keeps the
# built-in.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/builtin-names"
output_directory="$project_root/build/builtin-names"
mkdir -p "$output_directory"

export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/main.ab" \
        -o "$output_directory/main-$mode" --no-cache
    set +e
    output=$("$output_directory/main-$mode")
    status=$?
    set -e
    [[ $status == 42 && $output == "25 25 10 16" ]] ||
        { echo "builtin-names: main ($mode) exited with $status, printed:"; echo "$output"; exit 1; }
done
echo "builtin-names: a program's Cell/Shared/Mutex/Map/filledArray/move win where seen, # (both tiers), built-ins elsewhere"
