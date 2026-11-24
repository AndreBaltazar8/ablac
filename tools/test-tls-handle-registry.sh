#!/usr/bin/env bash
# The hosted TLS handle calls (abla/tls/hosted: tlsControlInt, tlsControlPointer, tlsCloseHandle) check a handle against the table of those the layer made and has not
# closed: an unknown one is refused without a read. Needs OpenSSL to run (the program links it); the live-handle paths are tools/test-tls-unix.sh's. Release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/tls-handle-registry
rm -rf "${out:?}"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/tls-handle-registry/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode") || { echo "tls-handle-registry ($mode): $result" >&2; exit 1; }
    [[ $result == 'tls-handle-registry ok' ]] || { echo "tls-handle-registry ($mode): $result" >&2; exit 1; }
done
echo "ok   hosted TLS handle calls refuse a handle the layer did not make, release and --fast"
