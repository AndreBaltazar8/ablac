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
default_test_seconds=300
export ABLA_MAX_SECONDS=${ABLA_TEST_SECONDS:-$default_test_seconds}
export ABLA_MAX_CPU_SECONDS=$ABLA_MAX_SECONDS

# The small shell boundary only activates the host LLVM toolchain. Test
# scheduling, timeouts, status checks, logs, and parallelism live in Abla.
# Prepare initializes the vendor submodule and writes lock markers so the
# offline github() import never fetches.
"$project_root/tools/prepare-abla-test-driver.sh"
runner_project="$project_root/tools/abla-test-driver"
"$compiler" build --project "$runner_project" --offline --fast --no-cache
runner_arguments=(
    --root "$project_root"
    --file tests/abla-tests.json
    --set "compiler=$compiler"
    --set "memory=$ABLA_MAX_MEMORY_MB"
    --set "seconds=$ABLA_MAX_SECONDS"
)
if [[ -n ${ABLA_TEST_JOBS:-} ]]; then
    runner_arguments+=(--jobs "$ABLA_TEST_JOBS")
fi
exec "$runner_project/build/ablac-test-driver" "${runner_arguments[@]}"
