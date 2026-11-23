#!/usr/bin/env bash
# A request sent a few bytes at a time costs the HTTP event servers time in proportion to its size, not its square (#1139 area 4):
# the plain server (tests/cases/http-event/drip.ab) and the HTTPS server, here without TLS (drip-https.ab).
# Usage: tools/test-http-event-drip.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http-event-drip
rm -rf "$out"
mkdir -p "$out"
for case in "drip:http-event drip ok" "drip-https:http-event-tls drip ok"; do
    name=${case%%:*} expected=${case#*:}
    "$compiler" build "tests/cases/http-event/$name.ab" -o "$out/$name" --no-cache
    result=$("$root/tools/run-limited.sh" "$out/$name") || { echo "http-event-drip: $name: $result" >&2; exit 1; }
    [[ $result == "$expected" ]] || { echo "http-event-drip: $name: $result" >&2; exit 1; }
    echo "$result"
done
