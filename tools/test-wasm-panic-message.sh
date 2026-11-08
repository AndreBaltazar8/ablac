#!/usr/bin/env bash
# A Wasm panic says why on standard error ("panic: <message>") through
# abla_host.write only when the module imports it for other reasons: hostless,
# clock-only, exit-only, empty-write and folded-write modules keep their import
# sets, fast and release (src/wasm_panic.ab).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/wasm-panic-message"
rm -rf "$out"
mkdir -p "$out"
cd "$root"
cases=tests/cases/wasm-panic-message
tools/wasm-imports.sh "$compiler" "$out" "$cases"/*.ab >"$out/imports.txt"
for source in "$cases"/*.ab; do
    name=$(basename "$source" .ab)
    for mode in fast release; do
        node "$cases/run.mjs" "$out" "$name" "$mode"
    done
done
echo 'wasm panic message: written only where the module already imports write'
