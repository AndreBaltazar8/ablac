#!/usr/bin/env bash
# `subject ?? return`, `?? break`, `?? continue` and `?? panic(…)` on string?,
# class?, array?, int? and f64? subjects hand on a value of the subject's type
# (tests/cases/null-default-leave/shapes.ab), equal to the same code written
# with explicit null checks: natively, under `#` in the evaluator and in the
# native tier, and as release and development WebAssembly.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/null-default-leave"
output_directory="$project_root/build/null-default-leave"
rm -rf "$output_directory"
mkdir -p "$output_directory"

for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build "$cases/native.ab" \
        -o "$output_directory/native-$tier" --no-cache
    status=0
    "$output_directory/native-$tier" || status=$?
    [[ $status == 42 ]] ||
        { echo "null default leave: native ($tier at compile time) exited $status, not 42" >&2; exit 1; }
done
(cd "$project_root" && "$compiler" build "$cases/build.ab" \
    -o "$output_directory/build-driver" --no-cache)
(cd "$project_root" && "$output_directory/build-driver")
for module in shapes shapes-dev; do
    node "$cases/run.mjs" "$output_directory/$module.wasm"
done
echo "null default leave: ?? return/break/continue/panic on string?, class?, array?, int? and f64? agree with explicit null checks natively, under # (evaluator, native tier) and as wasm (release, development)"
