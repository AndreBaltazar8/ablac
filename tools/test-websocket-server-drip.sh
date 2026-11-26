#!/usr/bin/env bash
# A WebSocket frame sent a few bytes at a time costs the WebSocket server (abla/websocket/server) time in proportion to its size, not its
# square (#1139 area 4; tests/cases/websocket-server/drip.ab), and it reads plain HTTP requests as the HTTP servers do: request line,
# framing fields, absolute form (framing.ab, with the event server's upgrade line). Usage: tools/test-websocket-server-drip.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/websocket-server-drip
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/websocket-server/drip.ab -o "$out/drip" --no-cache
result=$("$root/tools/run-limited.sh" "$out/drip") || { echo "websocket-server-drip: $result" >&2; exit 1; }
[[ $result == 'websocket-server drip ok' ]] || { echo "websocket-server-drip: $result" >&2; exit 1; }
echo "$result"
"$compiler" build tests/cases/websocket-server/framing.ab -o "$out/framing" --no-cache
result=$("$root/tools/run-limited.sh" "$out/framing") || { echo "websocket-server-drip: framing: $result" >&2; exit 1; }
[[ $result == 'websocket-server framing ok' ]] || { echo "websocket-server-drip: framing: $result" >&2; exit 1; }
echo "$result"
