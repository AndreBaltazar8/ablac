#!/usr/bin/env bash
# linuxTcpReceiveDescriptor (abla/sys/linux/net): the count/EOF/errno status, the capacity bounds and the descriptor left
# open (tests/cases/receive-descriptor). webSocketServerReceive and the postgres client read through it.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/receive-descriptor-test"
mkdir -p "$out"
cd "$root"
"$compiler" build tests/cases/receive-descriptor/main.ab -o "$out/program" --fast --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
status=0
timeout 20 "$root/tools/run-limited.sh" "$out/program" > "$out/run.log" 2>&1 || status=$?
[[ $status -ne 124 ]] || { cat "$out/run.log" >&2; echo "receive descriptor: FAIL, a read hung for 20 s (a refused capacity must return, not wait)" >&2; exit 1; }
{ [[ $status -eq 0 ]] && grep -q 'receive-descriptor: ok' "$out/run.log"; } || { cat "$out/run.log" >&2; echo "receive descriptor: status $status" >&2; exit 1; }
echo 'receive descriptor: a descriptor read reports bytes, EOF or errno, refuses capacities outside 1..1048576 and keeps the descriptor open'
