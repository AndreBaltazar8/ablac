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
compiler=${ABLA_COMPILER_PAYLOAD:-"${0}.bin"}
if [[ ! -x $compiler ]]; then
    printf '[abla-limit] compiler payload is not executable: %q\n' \
        "$compiler" >&2
    exit 127
fi
# Large pure-Abla applications can make the self-hosted frontend traverse
# deeply nested typed source graphs. Reserve enough stack and virtual address
# space for those builds while retaining the launcher's hard process bounds.
default_stack_kb=131072
default_memory_mb=4096
if [[ $(uname -s) == Darwin ]]; then
    hard_stack_kb=$(ulimit -H -s)
    if [[ $hard_stack_kb =~ ^[1-9][0-9]*$ &&
          $hard_stack_kb -lt $default_stack_kb ]]; then
        default_stack_kb=$hard_stack_kb
    fi
fi
stack_kb=${ABLA_MAX_STACK_KB:-$default_stack_kb}
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-$default_memory_mb}

# Keep compiler-owned sources independent from the caller's working directory.
# An explicit sysroot still wins for installed or custom toolchains.
export ABLA_SYSROOT=${ABLA_SYSROOT:-$toolchain_root}

run_in_toolchain_shell() {
    invocation=()
    printf -v invoked_path '%q' "$0"
    invocation+=("$invoked_path")
    for argument in "$@"; do
        printf -v escaped_argument '%q' "$argument"
        invocation+=("$escaped_argument")
    done
    shell_command=${invocation[*]}
    exec nix-shell "$toolchain_root/shell.nix" --run "$shell_command"
}

if [[ ! $stack_kb =~ ^[1-9][0-9]*$ ]]; then
    printf '[abla-limit] ABLA_MAX_STACK_KB must be a positive integer, got %q\n' \
        "$stack_kb" >&2
    exit 2
fi
ulimit -S -s "$stack_kb"

# A freshly linked compiler on NixOS may refer to development-shell shared
# libraries which are deliberately absent from the global loader path. Enter
# the pinned shell for every command when that is the case, including cheap
# commands such as --version and the long-lived analysis service.
if [[ $(uname -s) == Linux && -z ${IN_NIX_SHELL:-} ]]; then
    runtime_dependencies=$(ldd "$compiler" 2>/dev/null || true)
    if [[ $runtime_dependencies == *'not found'* ]]; then
        run_in_toolchain_shell "$@"
    fi
fi

# A compiler self-build also needs a longer explicit wall-clock allowance for
# the pure-Abla frontend and LLVM O2 in one process.
if [[ ${1:-} == build && ${2:-} == *src/orc_main.ab &&
      -z ${ABLA_MAX_SECONDS:-} ]]; then
    export ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-240}
fi

# The repository compiler intentionally relies on the pinned LLVM toolchain.
# Emission-only commands need no shell, while build/serve enter it lazily when
# invoked from a plain NixOS terminal. The final compiler calls LLVM in-process
# for object emission but still uses the pinned clang/linker toolchain.
case ${1:-} in
    build|serve|analyze)
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
            run_in_toolchain_shell "$@"
        fi
        ;;
esac

if [[ ! -x $compiler ]]; then
    printf '[abla-limit] guarded compiler payload is missing: %s\n' \
        "$compiler" >&2
    exit 127
fi

exec "$script_directory/run-limited.sh" "$compiler" "$@"
