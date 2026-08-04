#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
if [[ $compiler != /* ]]; then
    compiler="$(cd -- "$(dirname -- "$compiler")" && pwd)/$(basename -- "$compiler")"
fi

temporary_directory=$(mktemp -d)
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

cd "$temporary_directory"

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/stdlib.ab" \
    > "$temporary_directory/stdlib.ll"
test -s "$temporary_directory/stdlib.ll"

"$compiler" build \
    "$project_root/tests/cases/modules/host-runtime.ab" \
    -o "$temporary_directory/host-runtime" --no-cache
test -x "$temporary_directory/host-runtime"

"$compiler" build \
    "$project_root/tests/cases/bootstrap/block.ab" \
    -o "$temporary_directory/raw-runtime" --no-cache \
    --target x86_64-linux-raw
test -x "$temporary_directory/raw-runtime"

printf '%s\n' \
    'toolchain root: stdlib and runtime resources are independent from cwd'
