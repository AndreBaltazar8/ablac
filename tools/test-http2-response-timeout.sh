#!/usr/bin/env bash
# The HTTP/2 server ends a connection whose response the peer's flow-control windows hold back for H2Server.responseTimeout ms (#1139 area 4;
# tests/cases/http2/response-timeout.ab). Usage: tools/test-http2-response-timeout.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http2-response-timeout
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/http2/response-timeout.ab -o "$out/main" --no-cache
result=$("$root/tools/run-limited.sh" "$out/main") || { echo "http2-response-timeout: $result" >&2; exit 1; }
[[ $result == 'http2 response timeout ok' ]] || { echo "http2-response-timeout: $result" >&2; exit 1; }
echo "$result"
