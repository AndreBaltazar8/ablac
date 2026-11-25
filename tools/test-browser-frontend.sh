#!/usr/bin/env bash
# The compiler's front end builds as a wasm32 module with no LLVM and no native compile-time tier (#1138): src/browser_main.ab, built
# by the compiler under test as a development module, is valid, imports only the page host's functions, stays under a size cap, and under
# Node (tools/playground) lowers programs, reports errors, and runs programs with its evaluator.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/wasm-browser-frontend"
output_directory="$project_root/build/wasm-browser-frontend"
rm -rf "$output_directory"
mkdir -p "$output_directory"

(cd "$project_root" && "$compiler" build "$cases/build.ab" -o "$output_directory/build-driver" --no-cache)
(cd "$project_root" && "$output_directory/build-driver")
node "$cases/check.mjs" "$output_directory/browser-frontend.wasm" 20
if command -v wasmtime >/dev/null; then
    for program in compiled-hello compiled-loop; do
        (cd "$project_root" && "$compiler" build "$cases/$program.ab" --target wasm32-wasi \
            --fast --no-cache -o "$output_directory/$program.wasm")
    done
fi
node "$project_root/tools/playground/frontend-check.mjs" \
    "$output_directory/browser-frontend.wasm" "$project_root" "$output_directory"
