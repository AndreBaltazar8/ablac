#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
directory="$project_root/build/runtime-memory-test"
program="$directory/program"
limited_program="$directory/limited-program"
collector_program="$directory/collector-program"
host_collector_program="$directory/host-collector-program"
pressure_program="$directory/pressure-program"
plain_ir="$directory/plain.ll"
collector_ir="$directory/collector.ll"
mkdir -p "$directory"
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/runtime-memory-no-collector.ab" \
    > "$plain_ir"
if rg -q 'define internal i1 @abla_runtime_mark_pointer' "$plain_ir"; then
    echo 'unreachable collector runtime was emitted' >&2
    exit 1
fi
rg -Fq '@abla_runtime_alloc_internal(i64 %size, i1 false)' "$plain_ir"
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/runtime-memory-collect.ab" \
    > "$collector_ir"
rg -q 'define internal i1 @abla_runtime_mark_pointer' "$collector_ir"
rg -q 'define internal i1 @abla_runtime_mark_value' "$collector_ir"
rg -q 'define internal i1 @abla_runtime_mark_allocation' "$collector_ir"
rg -q 'call void @llvm.memset.*%payload' "$collector_ir"
rg -Fq '@abla_runtime_alloc_internal(i64 %size, i1 true)' "$collector_ir"
rg -Fq '%allocation_scan_size_slot = getelementptr i8, ptr %allocation, i64 32' \
    "$collector_ir"
rg -Fq 'call void @abla_runtime_memory_set_scan(ptr %values' "$collector_ir"
rg -Fq 'call void @abla_runtime_memory_set_scan(ptr %fields' "$collector_ir"
rg -Fq 'call void @abla_runtime_memory_set_scan(ptr %unsafe_allocation_' \
    "$collector_ir"
rg -Fq 'call void @abla_runtime_memory_set_layout(ptr %array, i64 4)' \
    "$collector_ir"
rg -Fq 'call void @abla_runtime_memory_set_layout(ptr %cell, i64 8)' \
    "$collector_ir"
rg -Fq 'call void @abla_runtime_memory_set_layout(ptr %object, i64 5)' \
    "$collector_ir"
rg -Fq 'call void @abla_runtime_memory_set_layout(ptr %rope, i64 6)' \
    "$collector_ir"
rg -q 'call void @abla_runtime_memory_set_layout\(ptr %unsafe_allocation_.*i64 10\)' \
    "$collector_ir"
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/runtime-memory-pressure.ab" \
    > "$directory/pressure.ll"
rg -Fq 'define internal void @abla_runtime_memory_pressure()' \
    "$directory/pressure.ll"
rg -Fq 'call void @abla_runtime_memory_pressure()' \
    "$directory/pressure.ll"
"$compiler" build "$project_root/tests/cases/modules/runtime-memory.ab" \
    -o "$program"
if nm --defined-only "$program" | awk '{print $3}' |
    rg -q '^ablaHost|^abla_host_|^abla_platform_'; then
    echo 'emitted memory tracker linked a project C platform symbol' >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]]
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-limit.ab" \
    -o "$limited_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$limited_program" \
    > "$directory/limited.out" 2> "$directory/limited.err"
limited_status=$?
set -e
[[ $limited_status -eq 134 ]]
rg -q 'abla panic: memory limit exceeded' "$directory/limited.err"
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-collect.ab" \
    -o "$collector_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$collector_program"
collector_status=$?
set -e
[[ $collector_status -eq 42 ]]
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-pressure.ab" \
    -o "$pressure_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$pressure_program"
pressure_status=$?
set -e
[[ $pressure_status -eq 42 ]]
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-collect-host.ab" \
    --no-cache -o "$host_collector_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$host_collector_program"
host_collector_status=$?
set -e
[[ $host_collector_status -eq 42 ]]
printf '%s\n' \
    'emitted memory: stripping + scan bounds + pressure safe points + pure/host collection passed'
