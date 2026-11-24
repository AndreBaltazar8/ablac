#!/usr/bin/env bash
# linuxTcpConnectStart, linuxSocketPendingError, linuxFileSync and linuxReadAtDescriptor (abla/sys/linux/net and fs; tests/cases/net-apis): fast and release builds.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/net-apis-test
mkdir -p "$out"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/net-apis/main.ab -o "$out/program" $mode --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    status=0
    "$root/tools/run-limited.sh" "$out/program" > "$out/run.log" 2>&1 || status=$?
    [[ $status -eq 42 ]] && grep -q 'net-apis: ok' "$out/run.log" || { cat "$out/run.log" >&2; echo "net apis: status $status (mode '$mode')" >&2; exit 1; }
done
echo 'net apis: a started connect, its pending error, fsync and a read at an offset do what they say, and refuse what is not an IPv4 address or a bounded read'
