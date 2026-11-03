#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/native-width-integers
source_file=$project_root/tests/cases/modules/native-width-integers.ab
llvm_ir=$output_directory/program.ll
program=$output_directory/program

mkdir -p "$output_directory"
"$compiler" --emit-llvm "$source_file" >"$llvm_ir"
opt -passes=verify -disable-output "$llvm_ir"

grep -Eq 'add i8 .*' "$llvm_ir"
grep -Eq 'add i16 .*' "$llvm_ir"
grep -Eq 'add i32 .*' "$llvm_ir"
grep -Eq 'udiv i32 .*' "$llvm_ir"
grep -Eq 'lshr i32 .*' "$llvm_ir"
grep -Eq 'icmp ugt i32 .*' "$llvm_ir"
if grep -Eq 'export\.arguments|call void @abla_(add|divide|equal)' \
    "$llvm_ir"; then
    printf 'native-width fixture retained a boxed scalar path\n' >&2
    exit 1
fi

"$compiler" build "$source_file" -o "$program"
set +e
"$program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'native-width integer fixture returned %d, expected 42\n' \
        "$status" >&2
    exit 1
fi

# Narrow and unsigned array reads must retain width/sign, including through
# generic functions, iteration, mutation and reboxing. The checked word getter
# must still panic for both negative and past-the-end indices.
for mode in "" --o1 --fast; do
    "$compiler" build "$project_root/tests/cases/modules/narrow-array-getters.ab" \
        -o "$output_directory/arrays" $mode
    "$compiler" build "$project_root/tests/cases/modules/narrow-array-trap.ab" \
        -o "$output_directory/array-trap" $mode
    set +e
    "$output_directory/arrays"
    array_status=$?
    "$output_directory/array-trap" 2>"$output_directory/array-past.err"
    past_status=$?
    "$output_directory/array-trap" negative 2>"$output_directory/array-negative.err"
    negative_status=$?
    set -e
    [[ $array_status -eq 42 && $past_status -eq 101 && $negative_status -eq 101 ]]
    grep -qx 'panic: index 2 out of bounds for array of size 2' "$output_directory/array-past.err"
    grep -qx 'panic: index -1 out of bounds for array of size 2' "$output_directory/array-negative.err"
done

printf '%s\n' 'native-width integer arithmetic, scalar exports and checked integer arrays passed'
