#!/usr/bin/env bash
# A Wasm module entered only through its exports roots its reference globals
# even when every initializer is constant, so no initialization code has to run.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/wasm-export-roots"
rm -rf "$output_directory"
mkdir -p "$output_directory"
cd "$project_root"

"$compiler" build tests/cases/wasm-export-roots/build.ab \
    -o "$output_directory/build-driver" --no-cache
"$output_directory/build-driver"
node --disable-wasm-trap-handler tests/cases/wasm-export-roots/run.mjs \
    "$output_directory/roots.wasm"
