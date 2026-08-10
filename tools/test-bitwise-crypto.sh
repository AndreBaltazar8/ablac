#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/bitwise-crypto"
mkdir -p "$output_directory"

if [[ -x ${ABLA_C_BACKEND_DRIVER:-} ]]; then
    "$ABLA_C_BACKEND_DRIVER" \
        "$project_root/tests/cases/c-backend/bitwise.ab" \
        >"$output_directory/program.c"
else
    ABLA_MAX_MEMORY_MB=4096 "$compiler" build \
        "$project_root/tests/cases/modules/bitwise-c-backend.ab" \
        -o "$output_directory/c-generator" --no-cache
    ABLA_MAX_MEMORY_MB=4096 "$project_root/tools/run-limited.sh" \
        "$output_directory/c-generator" \
        >"$output_directory/program.c"
fi
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -I"$project_root/runtime" \
    "$output_directory/program.c" \
    "$project_root/runtime/abla_runtime.c" \
    "$project_root/runtime/abla_runtime_host.c" \
    -o "$output_directory/c-program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/c-program"
c_status=$?
set -e
if [[ $c_status -ne 42 ]]; then
    printf 'bitwise C backend expected 42, got %s\n' "$c_status" >&2
    exit 1
fi

set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-bitwise-type.ab" \
    -o "$output_directory/invalid" --no-cache \
    >"$output_directory/invalid-output.txt" \
    2>"$output_directory/invalid-errors.txt"
invalid_status=$?
set -e
if [[ $invalid_status -ne 1 ]] ||
   ! grep -Fq 'bitwise.type' "$output_directory/invalid-errors.txt"; then
    printf '%s\n' 'invalid bitwise operands were not rejected correctly' >&2
    sed -n '1,80p' "$output_directory/invalid-errors.txt" >&2
    exit 1
fi

printf '%s\n' 'bitwise operators: staged/native/C semantics and type diagnostics passed'
