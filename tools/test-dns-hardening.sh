#!/usr/bin/env bash
# The DNS resolvers against hostile replies from a mock name server, and the name decoder's pointer and length rules; fast and release builds (no GC stress: the mock waits on real time).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/dns-hardening"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/dns-hardening/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0; do
        status=0
        ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" || status=$?
        [[ $status -eq 42 ]] || { echo "dns hardening: status $status (mode '$mode', stress $stress)" >&2; exit 1; }
    done
done
echo "dns hardening: replies from another source or to another question are ignored, foreign owners dropped, CNAME chains followed, pointer loops refused"
