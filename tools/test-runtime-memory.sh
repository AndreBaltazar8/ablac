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
global_container_program="$directory/global-container-program"
plain_ir="$directory/plain.ll"
collector_ir="$directory/collector.ll"
mkdir -p "$directory"
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/runtime-memory-no-collector.ab" \
    > "$plain_ir"
if rg -q '^define .*@abla_(runtime|platform)_memory_(checkpoint|reset|live_bytes|limit|set_limit|collect)' "$plain_ir"; then
    echo 'generated module duplicated the portable memory runtime' >&2
    exit 1
fi
rg -q '^define (hidden|internal) void @abla_runtime_roots_push\(' "$plain_ir"
rg -q '^define (hidden|internal) void @abla_runtime_roots_pop\(' "$plain_ir"
rg -q '^define (hidden|internal) void @abla_runtime_memory_pressure\(\)' "$plain_ir"
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-global-container.ab" \
    -o "$global_container_program" --no-cache
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$global_container_program"
global_container_status=$?
set -e
[[ $global_container_status -eq 42 ]] || exit 1
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/runtime-memory-collect.ab" \
    > "$collector_ir"
if rg -q '^declare .*@ablaRuntimeMemoryCollect' "$collector_ir"; then
    echo 'collector retained the retired external runtime boundary' >&2
    exit 1
fi
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/runtime-memory-pressure.ab" \
    > "$directory/pressure.ll"
rg -q '^define (hidden|internal) void @abla_runtime_memory_pressure\(\)' \
    "$directory/pressure.ll"
rg -Fq 'call void @abla_runtime_memory_pressure()' \
    "$directory/pressure.ll"
loop_roots_program="$directory/loop-roots-program"
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-loop-roots.ab" \
    -o "$loop_roots_program" --no-cache
set +e
ABLA_MAX_MEMORY_MB=256 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" "$loop_roots_program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
"$compiler" build "$project_root/tests/cases/modules/runtime-memory.ab" \
    -o "$program"
[[ -s $program.o ]] || exit 1
[[ ! -e $program.value-runtime.o ]] || exit 1
[[ ! -e $program.host.o ]] || exit 1
if nm -u "$program.o" | awk '{print $2}' | rg '^abla_' >/dev/null; then
    echo 'packaging object retained unresolved Abla runtime symbols' >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-limit.ab" \
    -o "$limited_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$limited_program" \
    > "$directory/limited.out" 2> "$directory/limited.err"
limited_status=$?
set -e
[[ $limited_status -eq 134 ]] || exit 1
rg -q 'memory limit exceeded' "$directory/limited.err"
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-collect.ab" \
    -o "$collector_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$collector_program"
collector_status=$?
set -e
[[ $collector_status -eq 42 ]] || exit 1
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-pressure.ab" \
    -o "$pressure_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$pressure_program"
pressure_status=$?
set -e
[[ $pressure_status -eq 42 ]] || exit 1
"$compiler" build \
    "$project_root/tests/cases/modules/runtime-memory-collect-host.ab" \
    --no-cache -o "$host_collector_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$host_collector_program"
host_collector_status=$?
set -e
[[ $host_collector_status -eq 42 ]] || exit 1
printf '%s\n' \
    'portable memory runtime: direct declarations + pressure safe points + limits + pure/host collection + bootstrapped global containers passed'
