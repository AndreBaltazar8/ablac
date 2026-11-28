#!/usr/bin/env bash
# A rope first read inside a memory checkpoint it is older than keeps its flat copy through the reset
# (tests/cases/rope-checkpoint): one checkpoint, nested ones, a rope between them, and a reused marker, at sizes from
# 100 bytes to 200 KB, read again after the freed memory was reused. Fast and release builds, with and without GC stress.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/rope-checkpoint"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/rope-checkpoint/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0 1; do
        result=$(ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" 2>&1) || result="failed: $result"
        [[ $result == 'rope checkpoint ok' ]] || { echo "rope checkpoint (mode '$mode', stress $stress): $result" >&2; exit 1; }
    done
done
echo 'rope checkpoints: flat copies outlive the resets of checkpoints younger than their ropes'
