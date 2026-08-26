#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/tests"
llvm_ir="$output_directory/native-cstring-lifetime.ll"
program="$output_directory/native-cstring-lifetime"
escaping_ir="$output_directory/native-cstring-escaping.ll"
borrowed_ir="$output_directory/native-string-address.ll"
borrowed_program="$output_directory/native-string-address"
mkdir -p "$output_directory"

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/native-c-string.ab" > "$llvm_ir"
rg -q 'call ptr @abla_as_cstring' "$llvm_ir"
rg -q 'call void @abla_platform_free\(ptr %native.cstring\)' "$llvm_ir"
opt --threads=1 -passes=verify -disable-output "$llvm_ir"

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/native-c-string-escaping.ab" \
    > "$escaping_ir"
rg -q 'call ptr @abla_as_cstring' "$escaping_ir"
if rg -q 'call void @abla_platform_free\(ptr %native.cstring\)' \
    "$escaping_ir"; then
    echo "escaping native C string was released after its call" >&2
    exit 1
fi
opt --threads=1 -passes=verify -disable-output "$escaping_ir"

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/native-string-address.ab" \
    > "$borrowed_ir"
rg -q 'call ptr @abla_string_data' "$borrowed_ir"
opt --threads=1 -passes=verify -disable-output "$borrowed_ir"

"$compiler" build \
    "$project_root/tests/cases/modules/native-c-string.ab" -o "$program"
set +e
"$program"
status=$?
set -e
[[ $status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/native-string-address.ab" \
    -o "$borrowed_program"
set +e
"$borrowed_program"
status=$?
set -e
[[ $status -eq 42 ]]

echo "native C-string lifetime and borrowed string data contracts hold"
