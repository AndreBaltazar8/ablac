#!/usr/bin/env bash
# `--backtrace` on a WebAssembly module keeps its name section, with each function's readable name, so a host's
# stack trace names them; a release module without it is unchanged (no name section). Two builds give the same bytes.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# (Under the project: a build program reads and writes only there.)
out=build/wasm-backtrace
rm -rf "$out"
mkdir -p "$out"
cases=tests/cases/wasm-backtrace
build() { # <mode> <output> [flag]
    cat > "$out/$1.build.ab" <<DRIVER
import "abla/wasm/build"
val built = #wasmBuildModule("crash", "$root/$cases/crash.ab", "$root/$2", false, false)
fun main: int = if (built) 0 else 1
DRIVER
    "$compiler" build "$out/$1.build.ab" -o "$out/$1.driver" --no-cache ${3:-} > "$out/$1.log" 2>&1 ||
        { cat "$out/$1.log" >&2; echo "wasm backtrace: the $1 build failed" >&2; exit 1; }
}
build plain "$out/crash-plain.wasm"
build backtrace "$out/crash.wasm" --backtrace
node "$cases/run.mjs" "$out/crash-plain.wasm" plain
node "$cases/run.mjs" "$out/crash.wasm" backtrace
cp "$out/crash.wasm" "$out/crash-first.wasm"
build again "$out/crash.wasm" --backtrace
cmp -s "$out/crash-first.wasm" "$out/crash.wasm" || { echo "wasm backtrace: two builds differ" >&2; exit 1; }
echo 'wasm backtrace: the name section only with --backtrace, and the trap names its functions'
