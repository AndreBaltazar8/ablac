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

# On Linux the build runs in the pinned shell, whose LLVM is the one the
# result links.
if [[ $host_os != Darwin && -z ${IN_NIX_SHELL:-} ]]; then
    printf -v self_command '%q ' "$project_root/tools/build-self-hosted-release.sh" "$@"
    exec nix-shell "$project_root/shell.nix" --run "$self_command"
fi

cd "$project_root"
export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}
mkdir -p -- "$(dirname -- "$output")"

# A compiler holds libLLVM in process and reads opt's bitcode back, so it runs
# with the tools of the LLVM it links. One linked against another LLVM than the
# one on PATH (the pinned bootstrap release links LLVM 21) builds with its own
# LLVM's tools and links the result against PATH's libLLVM, so the result runs
# with PATH's tools. ABLA_BOOTSTRAP_LLVM names the builder's LLVM prefix (the
# Linux shell sets it).
if [[ $host_os == Darwin ]]; then
    builder_llvm=$(otool -L "$compiler" |
        sed -n 's/.*libLLVM.*current version \([0-9][0-9]*\)\..*/\1/p' | sed -n 1p)
else
    builder_llvm=$(readelf -d "$compiler" |
        sed -n 's/.*NEEDED.*\[libLLVM[.-]so\.\([0-9][0-9]*\).*/\1/p
                s/.*NEEDED.*\[libLLVM-\([0-9][0-9]*\)\.so.*/\1/p' | sed -n 1p)
fi
target_llvm=$(llvm-config --version 2>/dev/null | cut -d. -f1)
if [[ -n $builder_llvm && -n $target_llvm && $builder_llvm != "$target_llvm" ]]; then
    if [[ $host_os == Darwin ]]; then
        builder_prefix=${ABLA_BOOTSTRAP_LLVM:-$(brew --prefix "llvm@$builder_llvm")}
    else
        builder_prefix=${ABLA_BOOTSTRAP_LLVM:-}
    fi
    if [[ ! -x $builder_prefix/bin/opt ||
          $("$builder_prefix/bin/opt" --version |
            sed -n 's/.*LLVM version \([0-9][0-9]*\)\..*/\1/p') != "$builder_llvm" ]]; then
        printf '%s links LLVM %s: set ABLA_BOOTSTRAP_LLVM to that LLVM'"'"'s prefix\n' \
            "$compiler" "$builder_llvm" >&2
        exit 1
    fi
    if [[ $host_os == Darwin ]]; then
        export ABLA_MACOS_LLVM_LIB=${ABLA_MACOS_LLVM_LIB:-$(llvm-config --libdir)}
        export PATH="$builder_prefix/bin:$PATH"
    else
        # Only the target's llvm-config (which names the libLLVM to link)
        # stays ahead of the builder's tools.
        target_config=$(command -v llvm-config)
        link_directory=$(mktemp -d)
        trap 'rm -rf -- "$link_directory"' EXIT
        ln -s "$target_config" "$link_directory/llvm-config"
        export PATH="$link_directory:$builder_prefix/bin:$PATH"
    fi
fi

printf -v build_command \
    '%q build %q -o %q --no-cache' \
    "$compiler" "$entry" "$output"

# A self-hosted compiler is built through the same LLVM-native path as every
# other Abla executable. The Abla runtime sources are part of that LLVM module;
# Mach-O additionally links only the narrow Darwin syscall adapter.
ABLA_MAX_MEMORY_MB=$build_memory_mb ABLA_MAX_SECONDS=$build_seconds \
    "$project_root/tools/run-limited.sh" "$BASH" -c "$build_command"

[[ -x $output && -s $output.ll ]] || exit 1
