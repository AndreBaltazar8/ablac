#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'usage: %s <compiler> <output> [entry]\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
output=$2
entry=${3:-src/orc_main.ab}
build_memory_mb=${ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB:-4096}
build_seconds=${ABLA_RELEASE_SELFHOST_BUILD_SECONDS:-600}

# On Linux the build runs in the pinned shell, whose LLVM is the one the
# result links.
if [[ $(uname -s) != Darwin && -z ${IN_NIX_SHELL:-} ]]; then
    printf -v self_command '%q ' "$project_root/tools/build-self-hosted-release.sh" "$@"
    exec nix-shell "$project_root/shell.nix" --run "$self_command"
fi

cd "$project_root"
export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}
mkdir -p -- "$(dirname -- "$output")"

# A self-hosted compiler is built through the same LLVM-native path as every
# other Abla executable. The Abla runtime sources are part of that LLVM module;
# Mach-O additionally links only the narrow Darwin syscall adapter. The
# repository launcher runs the compiler with the tools of the LLVM it links
# (on a Mac, ahead of any other LLVM on PATH), so the result links that LLVM.
ABLA_COMPILER_PAYLOAD=$compiler \
    ABLA_MAX_MEMORY_MB=$build_memory_mb ABLA_MAX_SECONDS=$build_seconds \
    "$project_root/tools/run-limited-compiler.sh" build "$entry" -o "$output" --no-cache

[[ -x $output && -s $output.ll ]] || exit 1
