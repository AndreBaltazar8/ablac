#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
if [[ $compiler != /* ]]; then
    compiler="$project_root/$compiler"
fi

if [[ $(uname -s) == Darwin ]]; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
        brew_command=/opt/homebrew/bin/brew
    else
        brew_command=/usr/local/bin/brew
    fi
    llvm_prefix=$($brew_command --prefix llvm@21 2>/dev/null ||
        $brew_command --prefix llvm)
    lld_prefix=$($brew_command --prefix lld@21 2>/dev/null ||
        $brew_command --prefix lld)
    macos_tool_directory="$project_root/build/.abla-macos-tools"
    mkdir -p "$macos_tool_directory"
    ln -sfn "$project_root/tools/macos-clang.sh" \
        "$macos_tool_directory/clang"
    export PATH="$macos_tool_directory:$llvm_prefix/bin:$lld_prefix/bin:$PATH"
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
default_test_seconds=120
if [[ $(uname -s) == Darwin ]]; then
    # Intel Macs in particular need more time for large in-process LLVM
    # optimization while still retaining a finite watchdog.
    default_test_seconds=300
fi
export ABLA_MAX_SECONDS=${ABLA_TEST_SECONDS:-$default_test_seconds}
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
