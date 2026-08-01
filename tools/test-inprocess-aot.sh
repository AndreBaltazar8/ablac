#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac.bin}
shim_directory=$(mktemp -d)
output="$project_root/build/inprocess-aot-test"

cleanup() {
    rm -rf -- "$shim_directory"
}
trap cleanup EXIT

# A successful build with failing opt/llc shims proves that the final compiler
# uses LLVM's library API for optimization and object emission.
ln -s "$(command -v false)" "$shim_directory/opt"
ln -s "$(command -v false)" "$shim_directory/llc"

PATH="$shim_directory:$PATH" \
ABLA_MAX_MEMORY_MB=1024 \
ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" \
    "$compiler" build \
    "$project_root/tests/cases/bootstrap/block.ab" \
    -o "$output"

set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$output"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' 'in-process LLVM AOT test passed'
