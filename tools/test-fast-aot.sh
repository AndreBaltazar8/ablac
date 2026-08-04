#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

compiler=$1
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/fast-aot-test"
fast_compiler="$output_directory/ablac-fast"
fast_payload="$fast_compiler.bin"
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$project_root/src/main.ab" \
    > "$output_directory/reference.ll"

begin=$(date +%s%N)
"$compiler" build "$project_root/src/main.ab" \
    -o "$fast_payload" --fast --no-cache
end=$(date +%s%N)
elapsed_ms=$(((end - begin) / 1000000))

ln -sfn ../../tools/run-limited-compiler.sh "$fast_compiler"
ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=120 \
    "$fast_compiler" --emit-llvm \
    "$project_root/src/main.ab" \
    > "$output_directory/fixed.ll"
cmp "$output_directory/reference.ll" "$output_directory/fixed.ll"

printf 'fast AOT self-build: %s ms, byte-identical compiler IR\n' "$elapsed_ms"
