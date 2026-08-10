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

if rg -q '^define .*@abla_(platform_|runtime_set_arguments)' \
    "$output_directory/pure-collections.ll"; then
    echo "generated module duplicated the portable platform runtime" >&2
    exit 1
fi
rg -q '^declare .*@abla_array_create' \
    "$output_directory/pure-collections.ll"
rg -q '^declare .*@abla_runtime_set_arguments' \
    "$output_directory/pure-collections.ll"
[[ -s $pure_output.o ]]
[[ ! -e $pure_output.value-runtime.o ]]
[[ ! -e $pure_output.host.o ]]
if nm -u "$pure_output.o" | awk '{print $2}' | rg '^abla_' >/dev/null; then
    echo 'packaging object retained unresolved Abla runtime symbols' >&2
    exit 1
fi
if nm -u "$pure_output.o" | awk '{print $2}' | rg '^__longjmp_chk$' >/dev/null; then
    echo 'packaging object retained a glibc-only fortified symbol' >&2
    exit 1
fi
clang -fuse-ld=lld -Wl,--gc-sections \
    "$pure_output.o" -o "$pure_output.relinked"
set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$pure_output.relinked"
relinked_status=$?
set -e
[[ $relinked_status -eq 42 ]]
nm --defined-only "$pure_output" | awk '{print $3}' |
    rg '^abla_platform_alloc$' >/dev/null
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
[[ -s $linux_filesystem_output.o ]]
[[ ! -e $linux_filesystem_output.value-runtime.o ]]
[[ ! -e $linux_filesystem_output.host.o ]]
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$linux_filesystem_output"
linux_filesystem_status=$?
set -e
[[ $linux_filesystem_status -eq 42 ]]

fixtures=(filesystem process-capture)
for fixture in "${fixtures[@]}"; do
    output="$output_directory/$fixture"
    "$compiler" build \
        "$project_root/tests/cases/modules/$fixture.ab" \
        -o "$output"
    [[ -s $output.o ]]
    [[ ! -e $output.value-runtime.o ]]
    [[ ! -e $output.host.o ]]
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
[[ -s $host_output.o ]]
[[ ! -e $host_output.host.o ]]
[[ ! -e $host_output.value-runtime.o ]]

echo "native platform boundary: generated modules use one linked portable value/platform runtime"
