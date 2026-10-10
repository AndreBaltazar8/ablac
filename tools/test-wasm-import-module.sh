#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/wasm-import-module"
module="$output_directory/wasm-import-module.wasm"
mkdir -p "$output_directory"

(cd "$project_root" && "$compiler" build \
    tests/cases/wasm-import-module/build.ab \
    -o "$output_directory/build-driver" --no-cache)
"$output_directory/build-driver"
node "$project_root/tests/cases/wasm-import-module/run.mjs" "$module"

set +e
(cd "$project_root" && "$compiler" build \
    tests/cases/wasm-import-module/invalid.ab \
    -o "$output_directory/invalid" --fast --no-cache) \
    >"$output_directory/invalid.out" 2>"$output_directory/invalid.err"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]] || exit 1
grep -q 'wasmImport.arguments:tooMany' \
    "$output_directory/invalid.out" "$output_directory/invalid.err"
grep -q 'wasmImport.extern:notExtern' \
    "$output_directory/invalid.out" "$output_directory/invalid.err"
