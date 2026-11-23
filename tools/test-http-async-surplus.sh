#!/usr/bin/env bash
# The async HTTP client does not reuse a connection whose peer sent bytes after the end of a response (#1139 area 4;
# tests/cases/http-async/surplus.ab). Usage: tools/test-http-async-surplus.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http-async-surplus
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/http-async/surplus.ab -o "$out/surplus" --no-cache
result=$("$root/tools/run-limited.sh" "$out/surplus") || { echo "http-async-surplus: $result" >&2; exit 1; }
[[ $result == 'http-async surplus ok' ]] || { echo "http-async-surplus: $result" >&2; exit 1; }
echo "$result"
