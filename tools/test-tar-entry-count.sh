#!/usr/bin/env bash
# The tar readers check an entry against the earlier ones in constant time: 16,000 entries within a few seconds, the same conflicts refused; fast and release builds, (no GC stress: the time bound is wall-clock).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/tar-entry-count"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/tar-entry-count/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0; do
        status=0
        ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" || status=$?
        [[ $status -eq 42 ]] || { echo "tar entry count: status $status (mode '$mode', stress $stress)" >&2; exit 1; }
    done
done
echo "tar-entry-count: the tar readers check 16,000 entries in time and refuse the same conflicts as before"
