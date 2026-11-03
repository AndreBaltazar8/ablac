#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
output_directory="$project_root/build/function-identities"
mkdir -p "$output_directory"
for source in collision compile; do
    for mode in default fast; do
        flags=()
        [[ $mode != fast ]] || flags+=(--fast)
        "$compiler" build "$project_root/tests/cases/function-identities/$source.ab" \
            -o "$output_directory/$source-$mode" --no-cache "${flags[@]}"
        status=0
        "$output_directory/$source-$mode" || status=$?
        [[ $status == 42 ]] || { echo "$source $mode: expected 42, got $status" >&2; exit 1; }
    done
done
"$compiler" build tests/cases/function-identities/build.ab -o "$output_directory/build-driver" --no-cache
"$output_directory/build-driver"
node tests/cases/function-identities/run.mjs "$output_directory/collision.wasm"
echo 'function identities: native callbacks and compile-time closure ids remain distinct'
