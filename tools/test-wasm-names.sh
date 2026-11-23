#!/usr/bin/env bash
# `build --wasm-names` (and ABLA_WASM_NAMES=1) keeps a WebAssembly module's name section so a profiler or a stack names its functions; the module's other
# sections, the code section among them, are the same bytes as a release build's, and a build without the flag has no name section (so the default is
# unchanged). Two builds with the flag give the same bytes.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# (Under the project: a build program reads and writes only there.)
out=build/wasm-names
rm -rf "$out"
mkdir -p "$out"
build() { # <mode> <output> [flag]
    cat > "$out/$1.build.ab" <<DRIVER
import "abla/wasm/build"
val built = #wasmBuildModule("crash", "$root/tests/cases/wasm-backtrace/crash.ab", "$root/$2", false, false)
fun main: int = if (built) 0 else 1
DRIVER
    "$compiler" build "$out/$1.build.ab" -o "$out/$1.driver" --no-cache ${3:-} > "$out/$1.log" 2>&1 ||
        { cat "$out/$1.log" >&2; echo "wasm names: the $1 build failed" >&2; exit 1; }
}
build plain "$out/plain.wasm"
build names "$out/names.wasm" --wasm-names
node tests/cases/wasm-names/check.mjs "$out/plain.wasm" "$out/names.wasm"
cp "$out/names.wasm" "$out/names-first.wasm"
build again "$out/names.wasm" --wasm-names
cmp -s "$out/names-first.wasm" "$out/names.wasm" || { echo "wasm names: two builds differ" >&2; exit 1; }
# (The module is named after its file: the same path.)
rm -f "$out/names.wasm"
ABLA_WASM_NAMES=1 build environment "$out/names.wasm"
cmp -s "$out/names-first.wasm" "$out/names.wasm" || { echo "wasm names: ABLA_WASM_NAMES=1 differs from --wasm-names" >&2; exit 1; }
echo 'wasm names: the name section only with --wasm-names, the other sections unchanged'
