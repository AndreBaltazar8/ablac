#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
entry="$project_root/bootstrap/compiler/orc_main.ab"
output="$project_root/build/ablac-pure-self"
reference_ir="$project_root/build/ablac-pure-self.reference.ll"
self_ir="$project_root/build/ablac-pure-self.fixed.ll"
probe="$project_root/build/ablac-pure-self-probe"
final_emit_memory_mb=${ABLA_FINAL_SELFHOST_EMIT_MEMORY_MB:-2048}

# This deliberately bypasses the native object cache and exercises the public
# compiler command itself. The four-GiB guard remains below machine-wide
# exhaustion while allowing Abla and LLVM's O2 pipeline to coexist.
ABLA_MAX_MEMORY_MB=${ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB:-4096} \
    ABLA_MAX_SECONDS=240 "$project_root/tools/run-limited.sh" \
    "$compiler" build "$entry" -o "$output" --no-cache

[[ -s $output ]]
[[ -s $output.ll ]]
[[ ! -e $output.host.o ]]
if nm "$output" | awk '{print $3}' | \
    rg -q '^(ablaHost|abla_host_|abla_platform_)'; then
    printf '%s\n' 'pure self-rebuilt compiler linked project C symbols' >&2
    exit 1
fi

ABLA_MAX_MEMORY_MB=$final_emit_memory_mb ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" \
    "$compiler" --emit-llvm "$entry" > "$reference_ir"
# The canonical self-rebuild is the production O2 compiler. Fast AOT remains a
# separate small-program gate; using a complete unoptimized compiler here adds
# a large code mapping without strengthening the fixed-point proof.
ABLA_MAX_MEMORY_MB=$final_emit_memory_mb ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" \
    "$output" --emit-llvm "$entry" > "$self_ir"
cmp "$reference_ir" "$self_ir"

ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" \
    "$output" build "$project_root/tests/cases/bootstrap/block.ab" \
    -o "$probe" --fast --no-cache
set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=20 \
    "$project_root/tools/run-limited.sh" "$probe"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' \
    'pure Abla O2 self-rebuild: uncached full graph -> host-free compiler -> byte-identical IR -> native child'
