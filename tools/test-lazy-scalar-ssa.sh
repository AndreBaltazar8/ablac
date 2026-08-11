#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
if [[ $compiler != /* ]]; then
    compiler="$project_root/$compiler"
fi

output_directory="$project_root/build/lazy-scalar-ssa"
mkdir -p "$output_directory"
source_file="$project_root/tests/cases/modules/scalar-direct-abi.ab"
llvm_ir="$output_directory/program.ll"
executable="$output_directory/program"
typed_source="$project_root/tests/cases/modules/typed-collection-ops.ab"
typed_ir="$output_directory/typed-collection-ops.ll"
typed_executable="$output_directory/typed-collection-ops"

"$compiler" --emit-llvm "$source_file" > "$llvm_ir"
opt --threads=1 -passes=verify -disable-output "$llvm_ir"

# Proven scalar arithmetic and mutable locals stay native in the generated
# function body. The same fixture also passes a function through Fn(int)->int,
# which keeps the ordinary boxed indirect-call boundary exercised.
rg -q ' = add i64 ' "$llvm_ir"
rg -q 'scalar\.local' "$llvm_ir"
rg -q '@abla_llvm_call_indirect' "$llvm_ir"
rg -q 'call void @abla_i64' "$llvm_ir"

"$compiler" --emit-llvm "$typed_source" > "$typed_ir"
opt --threads=1 -passes=verify -disable-output "$typed_ir"
rg -q 'call void @abla_string_length' "$typed_ir"
rg -q 'call void @abla_string_get' "$typed_ir"
rg -q 'call void @abla_array_length' "$typed_ir"
rg -q 'call void @abla_array_get' "$typed_ir"
if rg -q 'call void @abla_(length|index_get)' "$typed_ir"; then
    printf '%s\n' 'typed collection fixture retained generic dispatch' >&2
    exit 1
fi

"$compiler" build "$source_file" -o "$executable" --no-cache
set +e
"$executable"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'lazy scalar SSA fixture returned %d, expected 42\n' "$status" >&2
    exit 1
fi

"$compiler" build "$typed_source" -o "$typed_executable" --no-cache
set +e
"$typed_executable"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'typed collection fixture returned %d, expected 42\n' "$status" >&2
    exit 1
fi
