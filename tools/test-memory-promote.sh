#!/usr/bin/env bash
# memoryPromoteString out of a region keeps every byte (tests/cases/memory-promote): empty, one byte,
# long, NULs, non-ASCII, a rope, and after the region's memory is reused; fast and release builds,
# with and without GC stress.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/memory-promote"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/memory-promote/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" || status=$?
        [[ $status -eq 42 ]] || { echo "memory promote: status $status (mode '$mode', stress $stress)" >&2; exit 1; }
    done
done
echo 'memory promote: every length, NULs and non-ASCII bytes, a rope and reused region memory keep their bytes'
