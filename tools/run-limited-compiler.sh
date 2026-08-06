#!/usr/bin/env bash
set -euo pipefail

launcher=${BASH_SOURCE[0]}
while [[ -L $launcher ]]; do
    launcher_directory=$(cd -- "$(dirname -- "$launcher")" && pwd)
    launcher_target=$(readlink "$launcher")
    if [[ $launcher_target == /* ]]; then
        launcher=$launcher_target
    else
        launcher=$launcher_directory/$launcher_target
    fi
done
script_directory=$(cd -- "$(dirname -- "$launcher")" && pwd)
toolchain_root=$(cd -- "$script_directory/.." && pwd)
compiler="${0}.bin"
default_stack_kb=65536
if [[ $(uname -s) == Darwin ]]; then
    hard_stack_kb=$(ulimit -H -s)
    if [[ $hard_stack_kb =~ ^[1-9][0-9]*$ &&
          $hard_stack_kb -lt $default_stack_kb ]]; then
        default_stack_kb=$hard_stack_kb
    fi
fi
stack_kb=${ABLA_MAX_STACK_KB:-$default_stack_kb}

# Keep compiler-owned sources independent from the caller's working directory.
# An explicit sysroot still wins for installed or custom toolchains.
export ABLA_SYSROOT=${ABLA_SYSROOT:-$toolchain_root}

if [[ ! $stack_kb =~ ^[1-9][0-9]*$ ]]; then
    printf '[abla-limit] ABLA_MAX_STACK_KB must be a positive integer, got %q\n' \
        "$stack_kb" >&2
    exit 2
fi
ulimit -S -s "$stack_kb"

# A full compiler graph legitimately needs room for the pure-Abla frontend and
# LLVM O2 in one process. Keep the ordinary ceiling small, but make the public
# self-build command work without secret environment tuning.
if [[ ${1:-} == build && ${2:-} == *src/orc_main.ab &&
      -z ${ABLA_MAX_MEMORY_MB:-} ]]; then
    export ABLA_MAX_MEMORY_MB=4096
    export ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-240}
fi

# The repository compiler intentionally relies on the pinned LLVM toolchain.
# Emission-only commands need no shell, while build/serve enter it lazily when
# invoked from a plain NixOS terminal. The final compiler calls LLVM in-process
# for object emission but still uses the pinned clang/linker toolchain.
case ${1:-} in
    build|serve)
        if ! command -v opt >/dev/null 2>&1; then
            if [[ $(uname -s) == Darwin ]]; then
                if [[ -x /opt/homebrew/bin/brew ]]; then
                    brew_command=/opt/homebrew/bin/brew
                elif [[ -x /usr/local/bin/brew ]]; then
                    brew_command=/usr/local/bin/brew
                else
                    brew_command=
                fi
                if [[ -n $brew_command ]]; then
                    llvm_prefix=$($brew_command --prefix llvm@21 \
                        2>/dev/null || $brew_command --prefix llvm)
                    lld_prefix=$($brew_command --prefix lld@21 \
                        2>/dev/null || $brew_command --prefix lld)
                    export PATH="$llvm_prefix/bin:$lld_prefix/bin:$PATH"
                fi
            fi
        fi
        if ! command -v opt >/dev/null 2>&1; then
            if [[ -n ${IN_NIX_SHELL:-} ]]; then
                printf '%s\n' \
                    '[abla-limit] LLVM tools are missing from the active nix-shell' >&2
                exit 127
            fi
            invocation=()
            printf -v invoked_path '%q' "$0"
            invocation+=("$invoked_path")
            for argument in "$@"; do
                printf -v escaped_argument '%q' "$argument"
                invocation+=("$escaped_argument")
            done
            shell_command=${invocation[*]}
            exec nix-shell "$toolchain_root/shell.nix" --run "$shell_command"
        fi
        ;;
esac

if [[ ! -x $compiler ]]; then
    printf '[abla-limit] guarded compiler payload is missing: %s\n' \
        "$compiler" >&2
    exit 127
fi

exec "$script_directory/run-limited.sh" "$compiler" "$@"
