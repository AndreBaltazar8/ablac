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
host_os=$(uname -s)

cd "$project_root"
export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}
mkdir -p -- "$(dirname -- "$output")"

# A compiler holds libLLVM in process and reads opt's bitcode back, so it runs
# with the tools of the LLVM it links. One linked against another LLVM than the
# one on PATH (the pinned bootstrap release links llvm@21) builds with its own
# LLVM's tools and links the result against PATH's libLLVM, so the result runs
# with PATH's tools. ABLA_BOOTSTRAP_LLVM names the builder's LLVM prefix.
if [[ $host_os == Darwin ]]; then
    builder_llvm=$(otool -L "$compiler" |
        sed -n 's/.*libLLVM.*current version \([0-9][0-9]*\)\..*/\1/p' | sed -n 1p)
    target_llvm=$(llvm-config --version 2>/dev/null | cut -d. -f1)
    if [[ -n $builder_llvm && -n $target_llvm && $builder_llvm != "$target_llvm" ]]; then
        builder_prefix=${ABLA_BOOTSTRAP_LLVM:-$(brew --prefix "llvm@$builder_llvm")}
        if [[ ! -x $builder_prefix/bin/opt ]]; then
            printf '%s links LLVM %s: install llvm@%s or set ABLA_BOOTSTRAP_LLVM\n' \
                "$compiler" "$builder_llvm" "$builder_llvm" >&2
            exit 1
        fi
        export ABLA_MACOS_LLVM_LIB=${ABLA_MACOS_LLVM_LIB:-$(llvm-config --libdir)}
        export PATH="$builder_prefix/bin:$PATH"
    fi
fi

printf -v build_command \
    '%q build %q -o %q --no-cache' \
    "$compiler" "$entry" "$output"

# A self-hosted compiler is built through the same LLVM-native path as every
# other Abla executable. The Abla runtime sources are part of that LLVM module;
# Mach-O additionally links only the narrow Darwin syscall adapter.
if [[ $host_os == Darwin ]]; then
    ABLA_MAX_MEMORY_MB=$build_memory_mb ABLA_MAX_SECONDS=$build_seconds \
        "$project_root/tools/run-limited.sh" /bin/bash -c "$build_command"
else
    ABLA_MAX_MEMORY_MB=$build_memory_mb ABLA_MAX_SECONDS=$build_seconds \
        "$project_root/tools/run-limited.sh" \
        nix-shell "$project_root/shell.nix" --run "$build_command"
fi

[[ -x $output && -s $output.ll ]] || exit 1
