#!/usr/bin/env bash
# The blocking WebSocket reader: two frames within the payload limit that arrive pipelined with the end of a partial one are both read; fast and release builds, with and without GC stress.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/websocket-pipelined"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/websocket-pipelined/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" || status=$?
        [[ $status -eq 42 ]] || { echo "websocket pipelined: status $status (mode '$mode', stress $stress)" >&2; exit 1; }
    done
done
echo "WebSocket: frames within the limit that arrive pipelined are all read, a frame over the limit is refused"
