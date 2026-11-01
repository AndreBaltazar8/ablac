#!/usr/bin/env bash
# jsonParse limits are per call: large documents parse with raised limits.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/json-limits"
mkdir -p "$output_directory"

cd "$project_root"
# Builds and runs one case; every case has its own files, so they run at once.
check() { # label, mode (or ""), source, flags
    local label=$1 mode=$2 source=$3 flags=$4 status=0
    ABLA_COMPILE_EVAL=${mode:-${ABLA_COMPILE_EVAL:-}} "$compiler" build "$source" \
        -o "$output_directory/$label" $flags --no-cache || { echo "json limits: $label did not build"; return 1; }
    "$output_directory/$label" > /dev/null || status=$?
    [[ $status -eq 42 ]] || { echo "json limits: $label exited $status"; return 1; }
}

pids=()
check program "" tests/cases/modules/json-large-limits.ab "" &
pids+=("$!")
for mode in interp jit; do
    # jsonPermissiveLimits: JSON.parse's limits and duplicate keys, run time and `#`.
    check "permissive-$mode" "$mode" tests/cases/modules/json-permissive.ab "" &
    pids+=("$!")
    # Get and has through a key index, and JSON at compile time: a parse needs only
    # the grant reading its file, and lookups in a large object stay in the step limit.
    check "key-index-$mode" "$mode" tests/cases/modules/json-key-index.ab --fast &
    pids+=("$!")
    check "compile-time-$mode" "$mode" tests/cases/json-compile-time/main.ab --fast &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
echo "json limits: per call, above the defaults, depth bounded, the permissive preset (JSON.parse's limits and duplicate keys)"
