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
opt --threads=1 -passes=verify -disable-output "$llvm_ir"

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

"$compiler" build "$source_file" -o "$program" --no-cache
set +e
"$program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'native-width integer fixture returned %d, expected 42\n' \
        "$status" >&2
    exit 1
fi

printf '%s\n' 'native-width integer arithmetic and direct scalar exports passed'
