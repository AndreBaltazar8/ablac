#!/usr/bin/env bash
# linuxReadFile / LinuxFileDescriptor.read: the string returned holds the bytes read, not the buffer the limit sized (tests/cases/read-file-memory), fast and
# release; its content is exact for sizes around the copy's word size and half the limit.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/read-file-memory-test"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/read-file-memory/main.ab -o "$out/program" $mode --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    status=0
    "$root/tools/run-limited.sh" "$out/program" > "$out/run.log" 2>&1 || status=$?
    [[ $status -eq 42 ]] || { cat "$out/run.log" >&2; echo "read file memory: status $status (mode '$mode')" >&2; exit 1; }
done
echo 'read file memory: a small file read under a big limit holds its own size; contents exact'
