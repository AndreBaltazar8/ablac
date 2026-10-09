#!/usr/bin/env bash
set -euo pipefail
# This test reads the module's LLVM text, which a development build keeps only when asked.
export ABLA_KEEP_LLVM_TEXT=1

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/wasm-gc"
module="$output_directory/wasm-gc.wasm"
mkdir -p "$output_directory"

(cd "$project_root" && "$compiler" build tests/cases/wasm-gc/build.ab \
    -o "$output_directory/build-driver" --no-cache)
"$output_directory/build-driver"

llvm-readobj --file-headers "$module" | grep -q 'Arch: wasm32'
# Globals are published as collector roots by the lazy export initializer.
grep -q 'abla.wasm.global.gc.frame' "$module.ll"
# The collecting export roots its own locals.
grep -q 'gc.frame' "$module.ll"
if llvm-readobj --sections "$module" | grep -q 'Type: IMPORT'; then
    echo "WASM GC proof unexpectedly requires runtime imports" >&2
    exit 1
fi
node --disable-wasm-trap-handler \
    "$project_root/tests/cases/wasm-gc/run.mjs" "$module" 300
