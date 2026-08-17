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
    "$compiler" "$output" "$entry"

[[ -s $output ]]
[[ -s $output.ll ]]
[[ ! -e $output.host.o ]]
# Runtime code is emitted from Abla source into the compiler module itself.
nm "$output" | awk '{print $3}' |
    rg '^_?abla_runtime_set_arguments$' >/dev/null

# The input compiler's production module is generation one; the module emitted
# while it builds `output` is generation two. Compare those existing artifacts
# directly instead of redundantly emitting the complete compiler graph twice.
# Installed/bootstrap compilers may not retain their module, so keep one
# bounded generation-one emission as a fallback.
if [[ -s $compiler_ir ]]; then
    cp -- "$compiler_ir" "$reference_ir"
else
    ABLA_MAX_MEMORY_MB=$final_emit_memory_mb ABLA_MAX_SECONDS=300 \
        "$project_root/tools/run-limited.sh" \
        "$compiler" --emit-llvm "$entry" > "$reference_ir"
fi
cp -- "$output.ll" "$self_ir"
cmp "$reference_ir" "$self_ir"

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
        -o "$probe" --fast --no-cache
else
    printf -v probe_build \
        '%q build %q -o %q --fast --no-cache' \
        "$output" "$project_root/tests/cases/bootstrap/block.ab" "$probe"
    ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
        "$project_root/tools/run-limited.sh" \
        nix-shell "$project_root/shell.nix" --run "$probe_build"
fi
set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=20 \
    "$project_root/tools/run-limited.sh" "$probe"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' \
    'pure Abla O2 self-rebuild: content-addressed release graph -> direct LLVM C API compiler -> byte-identical IR -> native child'
