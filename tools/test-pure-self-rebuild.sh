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

# Keep frontend emission and LLVM object generation in separate bounded
# processes. This canonical release path avoids making both heap peaks coexist
# during a complete compiler rebuild.
ABLA_FINAL_SELFHOST_EMIT_MEMORY_MB=$final_emit_memory_mb \
    "$project_root/tools/build-self-hosted-release.sh" \
    "$compiler" "$output" "$entry"

[[ -s $output ]]
[[ -s $output.ll ]]
[[ ! -e $output.host.o ]]
# The generated compiler module is produced entirely through LLVM's C API.
# Its portable value/platform runtime is linked as an ordinary implementation
# dependency; there is no alternate code-generation backend in that runtime.
nm "$output" | awk '{print $3}' | rg -q '^abla_runtime_set_arguments$'

ABLA_MAX_MEMORY_MB=$final_emit_memory_mb ABLA_MAX_SECONDS=300 \
    "$project_root/tools/run-limited.sh" \
    "$compiler" --emit-llvm "$entry" > "$reference_ir"
# The canonical self-rebuild is the production O2 compiler. Fast AOT remains a
# separate small-program gate; using a complete unoptimized compiler here adds
# a large code mapping without strengthening the fixed-point proof.
ABLA_MAX_MEMORY_MB=$final_emit_memory_mb ABLA_MAX_SECONDS=300 \
    "$project_root/tools/run-limited.sh" \
    "$output" --emit-llvm "$entry" > "$self_ir"
cmp "$reference_ir" "$self_ir"

printf -v probe_build \
    '%q build %q -o %q --fast --no-cache' \
    "$output" "$project_root/tests/cases/bootstrap/block.ab" "$probe"
ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" \
    nix-shell "$project_root/shell.nix" --run "$probe_build"
set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=20 \
    "$project_root/tools/run-limited.sh" "$probe"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' \
    'pure Abla O2 self-rebuild: uncached full graph -> direct LLVM C API compiler -> byte-identical IR -> native child'
