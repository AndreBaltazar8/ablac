#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
if [[ $compiler != /* ]]; then
    compiler="$project_root/$compiler"
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

printf '%s\n' \
    'compact value ABI: 8-byte tag/auxiliary + 16-byte payload = 24 bytes'
