#!/usr/bin/env bash
# Float to integer conversions saturate (NaN gives 0) natively, under `#`,
# and in a WebAssembly build, which would otherwise trap.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/float-integer-saturation"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/float-integer-saturation.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "float-integer saturation: identical natively and under #"

(cd "$project_root" && "$compiler" build \
    tests/cases/wasm-float-saturation/build.ab \
    -o "$output_directory/build-driver" --no-cache)
(cd "$project_root" && "$output_directory/build-driver")
node "$project_root/tests/cases/wasm-float-saturation/run.mjs" \
    "$output_directory/conversions.wasm"
echo "float-integer saturation: WebAssembly saturates too"
