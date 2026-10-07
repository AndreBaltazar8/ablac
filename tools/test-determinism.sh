#!/usr/bin/env bash
# One fixed-step simulation (tests/cases/determinism) built native at every
# optimization level and to WebAssembly (release and development) must reach
# the same state hash, and that hash is recorded: a server running the native
# build and a client predicting with the WebAssembly build stay in lockstep.
# Update `expected` only for an intended change to the simulation or to the
# standard library's math.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/determinism"
cases="$project_root/tests/cases/determinism"
expected=138107219
mkdir -p "$output_directory" || exit 1

if command -v node >/dev/null 2>&1; then
    wasm_runner=node
elif command -v bun >/dev/null 2>&1; then
    wasm_runner=bun
else
    echo 'determinism: needs node or bun to run WebAssembly' >&2
    exit 1
fi

check() {
    local label=$1 value=$2
    if [[ $value != "$expected" ]]; then
        printf 'determinism: %s hashed %s, expected %s\n' \
            "$label" "$value" "$expected" >&2
        return 1
    fi
}

for profile in fast o1 o2; do
    flags=()
    [[ $profile == o2 ]] || flags=("--$profile")
    "$compiler" build "$cases/native.ab" \
        -o "$output_directory/native-$profile" ${flags[@]+"${flags[@]}"} \
        --no-cache || exit 1
    hash=$("$output_directory/native-$profile") || exit 1
    check "native --$profile" "$hash" || exit 1
done

rm -f "$output_directory"/determinism*.wasm || exit 1
(cd "$project_root" && "$compiler" build "$cases/build.ab" \
    -o "$output_directory/build-driver" --no-cache) || exit 1
"$output_directory/build-driver" || exit 1
for module in determinism determinism-fast; do
    hash=$("$wasm_runner" "$cases/run.mjs" \
        "$output_directory/$module.wasm" 600) || exit 1
    check "$module.wasm" "$hash" || exit 1
done

echo "determinism: native fast/o1/o2 and wasm release/fast all hash $expected"
