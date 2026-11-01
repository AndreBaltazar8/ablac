#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "$0")/.." && pwd)
output_directory="$project_root/build/generated-virtual-module"
source_file="$project_root/tests/cases/modules/generated-virtual-module.ab"
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/first.ll"
"$compiler" --emit-llvm "$source_file" > "$output_directory/second.ll"
cmp "$output_directory/first.ll" "$output_directory/second.ll"
opt -passes=verify -disable-output "$output_directory/first.ll"
"$compiler" build "$source_file" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-generated-virtual-module.ab" \
    > "$output_directory/invalid.ll" 2> "$output_directory/invalid.err"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]] || exit 1
grep -Eq 'type|identifier|function.argument' "$output_directory/invalid.err"

# A module past the old 64 KiB, as a program's @server grows to, and one past the limit.
generated_with_padding() {
    printf 'import "abla/compiler"\n#compilerGenerateModule("example.large", "fun generatedAnswer(value: int): int = value + 2\\nval generatedBase: int = 40\\n//'
    head -c "$1" /dev/zero | tr '\0' x
    printf '\\n")\nfun main: int = generatedAnswer(generatedBase)\n'
}
generated_with_padding 200000 > "$output_directory/large.ab"
"$compiler" build "$output_directory/large.ab" -o "$output_directory/large"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/large"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
generated_with_padding 1100000 > "$output_directory/too-large.ab"
set +e
"$compiler" --emit-llvm "$output_directory/too-large.ab" > "$output_directory/too-large.ll" 2> "$output_directory/too-large.err"
too_large_status=$?
set -e
[[ $too_large_status -ne 0 ]] || exit 1
grep -q 'E_EXT_GENERATED_MODULE_REQUEST' "$output_directory/too-large.err"

printf '%s\n' 'generated virtual module: bounded deterministic transaction + rollback diagnostic passed'
