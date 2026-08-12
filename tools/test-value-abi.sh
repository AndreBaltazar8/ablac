#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
if [[ $compiler != /* ]]; then
    compiler="$project_root/$compiler"
fi
if ! command -v clang >/dev/null 2>&1; then
    printf -v invocation '%q %q' "$project_root/tools/test-value-abi.sh" "$compiler"
    exec nix-shell "$project_root/shell.nix" --run "$invocation"
fi
temporary_directory=$(mktemp -d)
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

"$compiler" --emit-llvm "$project_root/tools/value-abi-probe.ab" \
    > "$temporary_directory/probe.ll"
grep -Fq '%AblaValue = type { i32, i32, %AblaPayload }' \
    "$temporary_directory/probe.ll"
grep -Fq '%AblaPayload = type { i64, i64 }' \
    "$temporary_directory/probe.ll"

clang -std=c11 -fsyntax-only -Wno-unused-command-line-argument \
    -I"$project_root/runtime" "$project_root/runtime/abla_runtime.c"
native_clang=$(clang -print-prog-name=clang)
"$native_clang" --target=wasm32-unknown-unknown -std=c11 -fsyntax-only \
    -DABLA_WASM32=1 -I"$project_root/runtime" \
    "$project_root/runtime/abla_runtime.c"

printf '%s\n' \
    'compact value ABI: 8-byte tag/auxiliary + 16-byte payload = 24 bytes'
