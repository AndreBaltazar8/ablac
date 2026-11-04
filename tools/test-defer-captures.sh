#!/usr/bin/env bash
# A defer captures its enclosing binding before control flow can enter a loop
# or skip the first defer. Captures survive every exit and are read in LIFO order.
set -euo pipefail
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/defer-captures"
mkdir -p "$output_directory"

expect() {
    local status=0
    "$@" || status=$?
    [[ $status == 42 ]] || { echo "defer captures: $* exited $status" >&2; exit 1; }
}
for profile in release o1 fast; do
    flags=()
    [[ $profile == release ]] || flags=(--"$profile")
    "$compiler" build "$project_root/tests/cases/modules/defer-loop-capture.ab" \
        -o "$output_directory/$profile" --no-cache "${flags[@]}"
    for stress in 0 1; do
        expect env ABLA_GC_STRESS=$stress "$output_directory/$profile"
    done
done
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build \
        "$project_root/tests/cases/defer-loop-capture/staged.ab" \
        -o "$output_directory/staged-$mode" --no-cache
    expect "$output_directory/staged-$mode"
done
echo "defer captures: one/two defers, continue/break/fallthrough, branch and iterator, native/GC/interp/JIT"
