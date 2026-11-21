#!/usr/bin/env bash
# TcpConnection.read, readResult and UdpSocket.receiveFrom: the string returned holds the bytes received, not the buffer the limit sized (tests/cases/read-socket-memory), fast and
# release.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/read-socket-memory-test"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/read-socket-memory/main.ab -o "$out/program" $mode --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    status=0
    "$root/tools/run-limited.sh" "$out/program" > "$out/run.log" 2>&1 || status=$?
    [[ $status -eq 42 ]] || { cat "$out/run.log" >&2; echo "read socket memory: status $status (mode '$mode')" >&2; exit 1; }
done
echo 'read socket memory: socket reads under a big limit hold the bytes received'
