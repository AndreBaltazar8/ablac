#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac.bin}
output_directory=$project_root/build/unbounded-exports
mkdir -p "$output_directory"

# Export requests are persisted as dynamically numbered files. Exercise more
# than the former 128-entry ceiling so large native/freestanding ABI surfaces
# cannot regress to an arbitrary fixed limit.
source_file=$output_directory/many-exports.ab
root_file=$output_directory/many-exports-root.ab
{
    for index in $(seq 0 128); do
        printf '@export("abla_many_%03d")\nfun many%03d(): int = %d\n\n' \
            "$index" "$index" "$index"
    done
} >"$source_file"
cat >"$root_file" <<'EOF'
import "abla/compiler"

val scheduled = #compilerBuildProgram(
    "many-exports",
    "build/unbounded-exports/many-exports.ab",
    "build/unbounded-exports/libmany_exports.so",
    "x86_64-linux",
    "shared-library",
    true,
    false
)

fun main: int = if (scheduled) 0 else 1
EOF

"$compiler" build "$root_file" \
    -o "$output_directory/many-exports-root" --fast --no-cache
"$output_directory/many-exports-root"
count=$(llvm-nm -D --defined-only \
    "$output_directory/libmany_exports.so" | grep -c ' abla_many_')
[[ $count -eq 129 ]]

echo 'unbounded staged exports: 129 unique ABI definitions passed'
