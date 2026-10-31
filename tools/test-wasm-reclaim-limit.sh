#!/usr/bin/env bash
# The Wasm runtime's reclaim thresholds follow a memory limit: garbage of many
# sizes under a limit below the default thresholds gets its parked memory merged,
# and the program finishes with its live bytes within the limit.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/wasm-reclaim-limit"
rm -rf "$output_directory"
mkdir -p "$output_directory"
cd "$project_root"

"$compiler" build tests/cases/wasm-reclaim-limit/build.ab \
    -o "$output_directory/build-driver" --no-cache
"$output_directory/build-driver"
node --disable-wasm-trap-handler tests/cases/wasm-reclaim-limit/run.mjs \
    "$output_directory/limit.wasm"
