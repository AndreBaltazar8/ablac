#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <seed-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
output_directory="$project_root/build/seed-intrinsics-test"
mkdir -p "$output_directory"

build_seed_program() {
    local source=$1
    local name=$2
    "$compiler" emit-c "$source" > "$output_directory/$name.c"
    cc -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
        -I"$project_root/runtime" \
        "$output_directory/$name.c" \
        "$project_root/runtime/abla_runtime.c" \
        "$project_root/runtime/abla_runtime_host.c" \
        -o "$output_directory/$name"
}

build_seed_program \
    "$project_root/tests/cases/bootstrap/direct-syscall.ab" direct-syscall
set +e
direct_output=$(ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/direct-syscall")
direct_status=$?
set -e
[[ $direct_status -eq 42 ]]
[[ $direct_output == direct-syscall ]]

build_seed_program \
    "$project_root/tests/cases/modules/linux-filesystem.ab" linux-filesystem
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/linux-filesystem"
filesystem_status=$?
set -e
[[ $filesystem_status -eq 42 ]]

build_seed_program \
    "$project_root/tests/cases/modules/linux-io.ab" linux-io
set +e
printf 'alpha\r\n\nbeta' | \
    ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/linux-io" \
    > "$output_directory/linux-io.stdout" \
    2> "$output_directory/linux-io.stderr"
io_status=$?
set -e
[[ $io_status -eq 42 ]]
[[ $(<"$output_directory/linux-io.stdout") == 'alpha||beta' ]]
[[ $(<"$output_directory/linux-io.stderr") == 'linux-io-stderr' ]]

build_seed_program \
    "$project_root/tests/cases/modules/linux-arguments.ab" linux-arguments
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" \
    "$output_directory/linux-arguments" first second
argument_status=$?
set -e
[[ $argument_status -eq 42 ]]

build_seed_program \
    "$project_root/tests/cases/modules/linux-process.ab" linux-process
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$output_directory/linux-process"
process_status=$?
set -e
[[ $process_status -eq 42 ]]

printf '%s\n' \
    'seed C intrinsics: memory, syscalls, strings, argv/envp, raw processes'
