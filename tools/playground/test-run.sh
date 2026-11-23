#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
out=build/playground-run
mkdir -p "$out"
for case in hello files loop memory; do
    "$compiler" build "tests/cases/playground-run/$case.ab" --target wasm32-wasi \
        --fast --no-debug --no-cache -o "$out/$case.wasm"
done
node tools/playground/test-run.mjs "$out"
