#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
program="$project_root/build/direct-syscall-test"
buffer_program="$project_root/build/native-byte-buffer-test"
copy_program="$project_root/build/unsafe-copy-memory-test"

"$compiler" build \
    "$project_root/tests/cases/bootstrap/direct-syscall.ab" -o "$program"

set +e
output=$(ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$program")
status=$?
set -e
[[ $status -eq 42 ]]
[[ $output == direct-syscall ]]

"$compiler" build \
    "$project_root/tests/cases/bootstrap/native-byte-buffer.ab" \
    -o "$buffer_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$buffer_program"
buffer_status=$?
set -e
[[ $buffer_status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/bootstrap/unsafe-copy-memory.ab" \
    -o "$copy_program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$copy_program"
copy_status=$?
set -e
[[ $copy_status -eq 42 ]]

printf '%s\n' \
    'direct Linux syscalls: open/read/write/close/getpid + native byte buffer + intrinsic memory copy'
