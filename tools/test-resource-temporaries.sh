#!/usr/bin/env bash
# A resource is dropped exactly once: a local that is a nested block's value
# moves out with it, and a discarded value is dropped where it is discarded.
# The program checks the drop order natively and under `#` on both tiers.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/resource-temporaries"
mkdir -p "$output_directory"

for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build \
        "$project_root/tests/cases/modules/resource-temporaries.ab" \
        -o "$output_directory/program-$mode" --no-cache
    set +e
    "$project_root/tools/run-limited.sh" "$output_directory/program-$mode"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        echo "resource temporaries: $mode expected 42, got $status" >&2
        exit 1
    fi
done

echo "resource temporaries: nested block values move out, discarded values drop, native = # (interp, jit)"
