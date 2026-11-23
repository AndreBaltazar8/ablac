#!/usr/bin/env bash
# A request body sent a few bytes at a time costs the HTTP event server time in proportion to its size, not its square
# (#1139 area 4; tests/cases/http-event/drip.ab). Usage: tools/test-http-event-drip.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http-event-drip
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/http-event/drip.ab -o "$out/drip" --no-cache
result=$("$root/tools/run-limited.sh" "$out/drip") || { echo "http-event-drip: $result" >&2; exit 1; }
[[ $result == 'http-event drip ok' ]] || { echo "http-event-drip: $result" >&2; exit 1; }
echo "$result"
