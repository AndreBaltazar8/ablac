#!/usr/bin/env bash
# The event servers set TCP_NODELAY on every connection they accept (tests/cases/http-event/nodelay.ab). Usage: tools/test-http-nodelay.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http-nodelay
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/http-event/nodelay.ab -o "$out/nodelay" --no-cache
result=$("$root/tools/run-limited.sh" "$out/nodelay") || { echo "http-nodelay: $result" >&2; exit 1; }
[[ $result == 'http-event nodelay ok' ]] || { echo "http-nodelay: $result" >&2; exit 1; }
echo "$result"
