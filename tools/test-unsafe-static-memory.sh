#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/unsafe-static-memory
source_file=$project_root/tests/cases/modules/unsafe-static-memory.ab
bytes_source=$project_root/tests/cases/modules/native-static-bytes.ab
linked_source=$project_root/tests/cases/native/internal-linked-static.ab
section_tls_source=$project_root/tests/cases/native/section-linked-thread-local.ab
linker_symbol_source=$project_root/tests/cases/native/linker-symbol-module-value.ab
u32s_source=$project_root/tests/cases/native/static-u32s-module-value.ab
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
grep -Eq '@abla_static_.* = internal global \[32 x i8\] zeroinitializer' \
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
    '^@abla_global_.* = internal constant i64 ptrtoint \(ptr @abla_test_internal_storage to i64\), align 8$' \
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
    '^@abla_test_internal_section_words = internal constant \[2 x i32\] \[i32 ptrtoint \(ptr @.*_direct to i32\), i32 65538\], section "\.abla_registry\.123", align 4$' \
    "$output_directory/section-linked-thread-local.ll"
grep -Eq \
    '^define internal i64 @.*_direct\(i64 .+\).*section "\.text\.abla_test_callback" \{$' \
    "$output_directory/section-linked-thread-local.ll"
grep -Eq \
    '^@abla_global_.* = internal constant i64 ptrtoint \(ptr @abla_test_internal_section_bytes to i64\), align 8$' \
    "$output_directory/section-linked-thread-local.ll"
grep -Eq \
    '^@abla_test_section_tls = thread_local global \[4 x i8\] zeroinitializer, section "\.tdata\.abla_test", align 4$' \
    "$output_directory/section-linked-thread-local.ll"
grep -Eq \
    '^@abla_test_internal_section_tls = internal thread_local global \[4 x i8\] zeroinitializer, section "\.tbss\.abla_test", align 4$' \
    "$output_directory/section-linked-thread-local.ll"
grep -Eq \
    '^@llvm\.used = .*@abla_test_internal_section_bytes.*@abla_test_internal_section_words.*@abla_test_internal_section_tls' \
    "$output_directory/section-linked-thread-local.ll"

"$compiler" build "$section_tls_source" --emit object \
    -o "$output_directory/section-linked-thread-local.o" --no-cache
llvm-readelf -SW "$output_directory/section-linked-thread-local.o" \
    > "$output_directory/section-linked-thread-local.sections"
grep -Eq \
    '\.rodata\.abla_test[[:space:]]+PROGBITS.*[[:space:]]AR[[:space:]]' \
    "$output_directory/section-linked-thread-local.sections"
grep -Eq \
    '\.abla_registry\.123[[:space:]]+PROGBITS.*[[:space:]]W?AR[[:space:]]' \
    "$output_directory/section-linked-thread-local.sections"
grep -Eq \
    '\.tbss\.abla_test[[:space:]]+NOBITS.*[[:space:]]WATR[[:space:]]' \
    "$output_directory/section-linked-thread-local.sections"

"$compiler" --emit-llvm "$bytes_source" \
    > "$output_directory/native-static-bytes.ll"
grep -Eq \
    '^@.*\.native\.bytes = private unnamed_addr constant .* align 8$' \
    "$output_directory/native-static-bytes.ll"
grep -Eq \
    '^@abla_global_.* = internal constant i64 ptrtoint \(ptr @.*\.native\.bytes to i64\), align 8$' \
    "$output_directory/native-static-bytes.ll"

"$compiler" --emit-llvm "$source_file" \
    > "$output_directory/unsafe-static-memory.ll"
grep -Eq \
    '^@abla_global_.* = internal constant i64 ptrtoint \(ptr @abla_static_.* to i64\), align 8$' \
    "$output_directory/unsafe-static-memory.ll"

"$compiler" --emit-llvm "$linker_symbol_source" \
    > "$output_directory/linker-symbol-module-value.ll"
grep -Eq \
    '^@abla_global_.* = internal constant i64 ptrtoint \(ptr @abla_test_linker_boundary to i64\), align 8$' \
    "$output_directory/linker-symbol-module-value.ll"
grep -Eq \
    '^@abla_global_.* = internal constant i32 ptrtoint \(ptr @abla_test_linker_boundary_32 to i32\), align 4$' \
    "$output_directory/linker-symbol-module-value.ll"

"$compiler" --emit-llvm "$u32s_source" \
    > "$output_directory/static-u32s-module-value.ll"
grep -Eq \
    '^@.*\.native\.u32s = private unnamed_addr constant \[5 x i32\] \[' \
    "$output_directory/static-u32s-module-value.ll"
grep -Eq \
    'i32 ptrtoint \(ptr @.*\.native\.bytes to i32\)' \
    "$output_directory/static-u32s-module-value.ll"
grep -Eq \
    'i32 ptrtoint \(ptr @.*_native_adapter to i32\)' \
    "$output_directory/static-u32s-module-value.ll"
grep -Eq \
    '^@abla_global_.* = internal constant i64 ptrtoint \(ptr @.*\.native\.u32s to i64\), align 8$' \
    "$output_directory/static-u32s-module-value.ll"
grep -Eq \
    '^@.*\.native\.mutable\.u32s = private global \[4 x i32\] \[' \
    "$output_directory/static-u32s-module-value.ll"
grep -Eq \
    '^@abla_global_.* = internal constant i64 ptrtoint \(ptr @.*\.native\.mutable\.u32s to i64\), align 8$' \
    "$output_directory/static-u32s-module-value.ll"
grep -Eq \
    '^@.*\.native\.mutable\.bytes = private global \[4 x i8\] c"wxyz", align 8$' \
    "$output_directory/static-u32s-module-value.ll"
grep -Eq \
    '^@abla_global_.* = internal constant i64 ptrtoint \(ptr @.*\.native\.mutable\.bytes to i64\), align 8$' \
    "$output_directory/static-u32s-module-value.ll"

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
