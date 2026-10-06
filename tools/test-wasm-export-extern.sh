#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/wasm-export-extern"
module="$output_directory/wasm-export-extern.wasm"
mkdir -p "$output_directory"

(cd "$project_root" && "$compiler" build \
    tests/cases/wasm-export-extern/build.ab \
    -o "$output_directory/build-driver" --no-cache)
"$output_directory/build-driver"
node "$project_root/tests/cases/wasm-export-extern/run.mjs" "$module"
