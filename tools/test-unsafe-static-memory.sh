#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/unsafe-static-memory
source_file=$project_root/tests/cases/modules/unsafe-static-memory.ab
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
grep -Eq '@abla\.static\.allocation(\.[0-9]+)? = internal global \[32 x i8\] zeroinitializer' \
    "$output_directory/program.ll"
if grep -Fq '@__ablaRuntimeAllocateLayout' "$output_directory/program.ll"; then
    echo 'static storage unexpectedly calls the runtime allocator' >&2
    exit 1
fi

"$compiler" build "$source_file" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'static memory fixture returned %d, expected 42\n' "$status" >&2
    exit 1
fi

echo 'unsafe static memory BSS lowering passed'
