#!/usr/bin/env bash
# CVE-2026-121481's class on a 32-bit target (OpenSSL's EVP_EncodeBlock computed the size in an int, so a huge input wrapped it and the
# buffer was too small): the runtime's allocator, a native byte buffer and the hex encoder's `size * 2 + 1` take 64-bit sizes, and a
# WebAssembly module (32-bit addresses) must refuse a size that wraps 32 bits or exceeds its memory (a trap), not serve a small block.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/wasm-alloc-limit"
output_directory="$project_root/build/wasm-alloc-limit"
rm -rf "$output_directory"
mkdir -p "$output_directory"
(cd "$project_root" && "$compiler" build "$cases/build.ab" -o "$output_directory/build-driver")
(cd "$project_root" && "$output_directory/build-driver")
node "$cases/run.mjs" "$output_directory/alloc-limit.wasm"
