#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/unsafe-static-memory
source_file=$project_root/tests/cases/modules/unsafe-static-memory.ab
bytes_source=$project_root/tests/cases/modules/native-static-bytes.ab
linked_source=$project_root/tests/cases/native/internal-linked-static.ab
section_tls_source=$project_root/tests/cases/native/section-linked-thread-local.ab
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
grep -Eq '@abla\.static\.allocation(\.[0-9]+)? = internal global \[32 x i8\] zeroinitializer' \
    "$output_directory/program.ll"
if grep -Fq '@__ablaRuntimeAllocateLayout' "$output_directory/program.ll"; then
    echo 'static storage unexpectedly calls the runtime allocator' >&2
    exit 1
fi

"$compiler" --emit-llvm "$linked_source" \
    > "$output_directory/internal-linked.ll"
grep -Eq \
    '^@abla_test_internal_storage = internal global \[8 x i8\] zeroinitializer' \
    "$output_directory/internal-linked.ll"
grep -Eq \
    '^@llvm\.used = .*@abla_test_internal_storage' \
    "$output_directory/internal-linked.ll"

"$compiler" --emit-llvm "$section_tls_source" \
    > "$output_directory/section-linked-thread-local.ll"
grep -Eq \
    '^@abla_test_internal_section_bytes = internal constant \[4 x i8\] c"ABCD", section "\.rodata\.abla_test", align 4$' \
    "$output_directory/section-linked-thread-local.ll"
grep -Eq \
    '^@abla_test_section_tls = thread_local global \[4 x i8\] zeroinitializer, section "\.tdata\.abla_test", align 4$' \
    "$output_directory/section-linked-thread-local.ll"
grep -Eq \
    '^@abla_test_internal_section_tls = internal thread_local global \[4 x i8\] zeroinitializer, section "\.tbss\.abla_test", align 4$' \
    "$output_directory/section-linked-thread-local.ll"
grep -Eq \
    '^@llvm\.used = .*@abla_test_internal_section_bytes.*@abla_test_internal_section_tls' \
    "$output_directory/section-linked-thread-local.ll"

"$compiler" build "$section_tls_source" --emit object \
    -o "$output_directory/section-linked-thread-local.o" --no-cache
llvm-readelf -SW "$output_directory/section-linked-thread-local.o" \
    > "$output_directory/section-linked-thread-local.sections"
grep -Eq \
    '\.rodata\.abla_test[[:space:]]+PROGBITS.*[[:space:]]AR[[:space:]]' \
    "$output_directory/section-linked-thread-local.sections"
grep -Eq \
    '\.tbss\.abla_test[[:space:]]+NOBITS.*[[:space:]]WATR[[:space:]]' \
    "$output_directory/section-linked-thread-local.sections"

"$compiler" --emit-llvm "$bytes_source" \
    > "$output_directory/native-static-bytes.ll"
grep -Eq \
    '^@.*\.native\.bytes = private unnamed_addr constant .* align 8$' \
    "$output_directory/native-static-bytes.ll"

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
