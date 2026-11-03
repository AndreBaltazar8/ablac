#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/any-text-panic"
mkdir -p "$out"
cd "$root"
"$compiler" build tests/cases/any-text-panic/main.ab -o "$out/main" --fast
status=0
"$out/main" >"$out/native.out" 2>"$out/native.err" || status=$?
[[ $status -eq 101 ]]
grep -qx 'panic: unsupported value (runtime tag 8)' "$out/native.err"
"$compiler" build tests/cases/any-text-panic/build.ab -o "$out/build" --fast
"$out/build"
node tests/cases/any-text-panic/run.mjs "$out/main.wasm"
echo 'native unsupported any interpolation reports a readable panic'
