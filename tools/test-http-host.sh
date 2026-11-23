#!/usr/bin/env bash
# The Host header in HTTP/1 request framing: more than one Host line, or a Host value with a space, a comma or a control byte, is refused
# (RFC 9112 3.2); a missing, empty or bracketed Host is accepted (tests/cases/http-host/main.ab). Usage: tools/test-http-host.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http-host
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/http-host/main.ab -o "$out/main" --no-cache
result=$("$root/tools/run-limited.sh" "$out/main") || { echo "http-host: $result" >&2; exit 1; }
[[ $result == 'http-host ok' ]] || { echo "http-host: $result" >&2; exit 1; }
echo "$result"
