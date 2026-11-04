#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/unix-stream"
mkdir -p "$out"
"$compiler" build "$root/tests/cases/unix-stream/main.ab" -o "$out/main" --fast --no-cache
status=0
timeout 30 "$out/main" || status=$?
[[ $status -eq 42 ]]
echo 'Unix streams: echo, abstract names, validation, HTTP and cleanup passed'
