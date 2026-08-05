#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
if [[ $compiler != /* ]]; then
    compiler="$project_root/$compiler"
fi

if ! command -v clang >/dev/null 2>&1 || ! command -v opt >/dev/null 2>&1; then
    if [[ -n ${IN_NIX_SHELL:-} ]]; then
        printf '%s\n' 'LLVM tools are missing from the active nix-shell' >&2
        exit 127
    fi
    printf -v invocation '%q %q' "$project_root/tools/test-self-hosted.sh" "$compiler"
    exec nix-shell "$project_root/shell.nix" --run "$invocation"
fi

cd "$project_root"
export ABLA_MAX_MEMORY_MB=${ABLA_TEST_MEMORY_MB:-4096}
export ABLA_MAX_SECONDS=${ABLA_TEST_SECONDS:-120}
export ABLA_MAX_CPU_SECONDS=$ABLA_MAX_SECONDS

# One compiler exercises the frontend, both backends, native runtime boundary,
# package/toolchain lookup, and the public command surface.
tools/test-run-limited.sh
tools/test-return-control.sh "$compiler"
tools/test-concurrency.sh "$compiler"
tools/test-package-build.sh "$compiler"
tools/test-toolchain-root.sh "$compiler"
tools/test-contract-imports.sh "$compiler"
tools/test-delegated-bindings.sh "$compiler"
tools/test-reactive-dependency-reflection.sh "$compiler"
tools/test-inprocess-aot.sh "${compiler}.bin"
tools/test-final-native-conformance.sh "$compiler"

printf '%s\n' 'self-hosted compiler test suite passed'
