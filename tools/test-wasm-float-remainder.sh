#!/usr/bin/env bash
# A float `%` on WebAssembly is the platform's exact fmod, not an import of the
# C library's (which no browser provides): release and development modules
# import nothing, and give the same bits as the native build's fmod and fmodf
# on every pair of edge values (zeros, subnormals, extremes, infinities, NaNs)
# and on 100000 pseudo-random pairs.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/wasm-float-remainder"
output_directory="$project_root/build/wasm-float-remainder"
rm -rf "$output_directory"
mkdir -p "$output_directory"

"$compiler" build "$cases/native.ab" -o "$output_directory/native" --no-cache
"$output_directory/native" > "$output_directory/native.txt"

(cd "$project_root" && "$compiler" build "$cases/build.ab" \
    -o "$output_directory/build-driver" --no-cache)
(cd "$project_root" && "$output_directory/build-driver")
for module in remainder remainder-dev; do
    node "$cases/run.mjs" "$output_directory/$module.wasm" > "$output_directory/$module.txt"
    if ! cmp -s "$output_directory/native.txt" "$output_directory/$module.txt"; then
        echo "wasm float remainder: $module differs from the native fmod" >&2
        diff "$output_directory/native.txt" "$output_directory/$module.txt" | head -20 >&2
        exit 1
    fi
done
echo "wasm float remainder: release and development modules import nothing and match the native fmod and fmodf on $(wc -l < "$output_directory/native.txt" | tr -d ' ') cases"
