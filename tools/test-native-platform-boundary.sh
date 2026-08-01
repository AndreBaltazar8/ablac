#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/native-platform-boundary-test"
mkdir -p "$output_directory"

pure_output="$output_directory/pure-collections"
panic_output="$output_directory/pure-panic"
linux_filesystem_output="$output_directory/linux-filesystem"
"$compiler" build \
    "$project_root/tests/cases/modules/collections.ab" \
    -o "$pure_output"
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/collections.ab" \
    > "$output_directory/pure-collections.ll"

if rg -q '^declare .*@abla_platform_|@abla_host_set_arguments' \
    "$output_directory/pure-collections.ll"; then
    echo "pure program retained the C host/platform boundary" >&2
    exit 1
fi
rg -q '^define internal ptr @abla_runtime_alloc' \
    "$output_directory/pure-collections.ll"
rg -q '^define internal void @abla_runtime_panic' \
    "$output_directory/pure-collections.ll"
if [[ -e $pure_output.host.o ]]; then
    echo "pure native build compiled an unused C host adapter" >&2
    exit 1
fi
if nm --defined-only "$pure_output" | awk '{print $3}' |
    rg -q '^ablaHost|^abla_host_|^abla_platform_'; then
    echo "pure executable linked a project C platform symbol" >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$pure_output"
pure_status=$?
set -e
[[ $pure_status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/bootstrap/emitted-runtime-panic.ab" \
    -o "$panic_output"
set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$panic_output" \
    2> "$output_directory/pure-panic-errors.txt"
panic_status=$?
set -e
[[ $panic_status -eq 134 ]]
rg -q '^abla panic: array index out of bounds$' \
    "$output_directory/pure-panic-errors.txt"

"$compiler" build \
    "$project_root/tests/cases/modules/linux-filesystem.ab" \
    -o "$linux_filesystem_output"
if [[ -e $linux_filesystem_output.host.o ]]; then
    echo "raw Linux filesystem compiled an unused C host adapter" >&2
    exit 1
fi
if nm --defined-only "$linux_filesystem_output" | awk '{print $3}' |
    rg -q '^ablaHost|^abla_host_|^abla_platform_'; then
    echo "raw Linux filesystem linked a project C platform symbol" >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$linux_filesystem_output"
linux_filesystem_status=$?
set -e
[[ $linux_filesystem_status -eq 42 ]]

fixtures=(filesystem process-capture)
for fixture in "${fixtures[@]}"; do
    output="$output_directory/$fixture"
    rm -f "$output.runtime.o"
    "$compiler" build \
        "$project_root/tests/cases/modules/$fixture.ab" \
        -o "$output"
    if [[ -e $output.runtime.o ]]; then
        echo "$fixture: native build recreated the legacy runtime object" >&2
        exit 1
    fi
    if [[ -e $output.host.o ]]; then
        echo "$fixture: portable target-backed module compiled a host adapter" >&2
        exit 1
    fi
    if nm --defined-only "$output" |
        rg -q ' [TW] abla_(void|i64|bool|string_static|string_data|array_)'; then
        echo "$fixture: executable exports legacy C value-runtime symbols" >&2
        exit 1
    fi
    set +e
    ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
        "$project_root/tools/run-limited.sh" "$output"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        echo "$fixture: expected 42, got $status" >&2
        exit 1
    fi
done

host_output="$output_directory/host-runtime"
"$compiler" build \
    "$project_root/tests/cases/modules/host-runtime.ab" \
    -o "$host_output"
[[ -s $host_output.host.o ]]
if nm -u "$host_output.host.o" | awk '{print $2}' | rg -q '^abla_'; then
    echo 'explicit host adapter imports the legacy Abla value ABI' >&2
    exit 1
fi

echo "native platform boundary: host adapter omitted for pure/portable-raw programs; private bridge only when explicitly selected"
