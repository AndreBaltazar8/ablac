#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/uuid"
mkdir -p "$out"
cd "$root"
# Test the exact private packing helpers without adding public injection APIs.
sed -e 's/^private fun uuidV4From/fun uuidV4From/' \
    -e 's/^private fun uuidV7From/fun uuidV7From/' \
    "$root/stdlib/abla/uuid/entry.ab" > "$out/uuid-copy.ab"
cp "$root/tests/cases/uuid/vectors.ab" "$out/vectors.ab"
for mode in --fast release; do
    options=()
    [[ $mode == release ]] || options+=(--fast)
    "$compiler" build "$out/vectors.ab" -o "$out/vectors" --no-cache "${options[@]}"
    status=0
    "$out/vectors" || status=$?
    [[ $status -eq 42 ]]
    "$compiler" build "$root/tests/cases/uuid/main.ab" -o "$out/main" --no-cache "${options[@]}"
    status=0
    "$out/main" || status=$?
    [[ $status -eq 42 ]]
done
"$compiler" build "$root/tests/cases/uuid/build-wasm.ab" -o "$out/wasm-driver" --no-cache
"$out/wasm-driver"
"$compiler" build "$root/tests/cases/uuid/build-wasm-parse.ab" -o "$out/wasm-parse-driver" --no-cache
"$out/wasm-parse-driver"
node "$root/tests/cases/uuid/run.mjs" "$out/uuid.wasm" "$out/uuid-parse.wasm"
echo 'UUID: v4/v7, parsing, equality and Wasm RNG failure passed'
