#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}
entry="$project_root/src/orc_main.ab"
output="$project_root/build/ablac-pure-self"
reference_ir="$project_root/build/ablac-pure-self.reference.ll"
self_ir="$project_root/build/ablac-pure-self.fixed.ll"
probe="$project_root/build/ablac-pure-self-probe"
final_emit_memory_mb=${ABLA_FINAL_SELFHOST_EMIT_MEMORY_MB:-4096}
compiler_ir="${compiler}.ll"
if [[ $compiler == *.bin ]]; then compiler_ir="${compiler%.bin}.ll"; fi

# Build through the same LLVM-native path used for every Abla program.
ABLA_FINAL_SELFHOST_EMIT_MEMORY_MB=$final_emit_memory_mb \
    "$project_root/tools/build-self-hosted-release.sh" \
    "$compiler" "$output" "$entry" || exit 1

[[ -s $output ]] || exit 1
[[ -s $output.ll ]] || exit 1
# Runtime code is emitted from Abla source into the compiler module itself.
# `defines <file> <symbol>`: the file defines the text symbol (with or without
# Mach-O's leading underscore; ELF lists a hidden one as local).
defines() {
    nm "$1" | awk -v name="$2" '
        ($2 == "T" || $2 == "t") && ($3 == name || $3 == "_" name) { found = 1 }
        END { exit !found }'
}
if [[ $(uname -s) == Darwin ]]; then
    # Mach-O links one host object beside the program: the Darwin syscall
    # adapter, compiled from C. It must carry no runtime code. The runtime's
    # symbols are hidden, so the executable's symbol table drops them; the
    # program object still defines them.
    [[ -s $output.host.o ]] || exit 1
    defines "$output.host.o" abla_darwin_linux_syscall || exit 1
    if nm "$output.host.o" | awk '
        $2 ~ /^[A-Za-z]$/ && $2 != "U" && $3 ~ /^_?abla_runtime_/ { found = 1 }
        END { exit !found }'; then
        exit 1
    fi
    defines "$output.o" abla_runtime_set_arguments || exit 1
else
    [[ ! -e $output.host.o ]] || exit 1
    defines "$output" abla_runtime_set_arguments || exit 1
fi

# The input compiler's production module is generation one; the module emitted
# while it builds `output` is generation two. Compare those existing artifacts
# directly instead of redundantly emitting the complete compiler graph twice.
# Installed/bootstrap compilers may not retain their module, so keep one
# bounded generation-one emission as a fallback.
if [[ -s $compiler_ir ]]; then
    cp -- "$compiler_ir" "$reference_ir" || exit 1
else
    ABLA_MAX_MEMORY_MB=$final_emit_memory_mb ABLA_MAX_SECONDS=300 \
        "$project_root/tools/run-limited.sh" \
        "$compiler" --emit-llvm "$entry" > "$reference_ir" || exit 1
fi
cp -- "$output.ll" "$self_ir" || exit 1
cmp "$reference_ir" "$self_ir" || exit 1

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
    export PATH="$llvm_prefix/bin:$lld_prefix/bin:$PATH"
    ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
        "$project_root/tools/run-limited.sh" \
        "$output" build "$project_root/tests/cases/bootstrap/block.ab" \
        -o "$probe" --fast --no-cache || exit 1
else
    printf -v probe_build \
        '%q build %q -o %q --fast --no-cache' \
        "$output" "$project_root/tests/cases/bootstrap/block.ab" "$probe"
    ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
        "$project_root/tools/run-limited.sh" \
        nix-shell "$project_root/shell.nix" --run "$probe_build" || exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=20 \
    "$project_root/tools/run-limited.sh" "$probe"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

printf '%s\n' \
    'pure Abla O2 self-rebuild: content-addressed release graph -> direct LLVM C API compiler -> byte-identical IR -> native child'
