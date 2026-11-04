#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
cd "$root"
out="$root/build/erased-float-boundaries"
mkdir -p "$out"
fixture=$("$root/tools/runtime-fixture.sh" "$root/tests/cases/erased-float-phase-a/representation.ab" "$out")
export ABLA_STDLIB="$out/stdlib"
for profile in fast release; do
    options=()
    [[ $profile != fast ]] || options+=(--fast)
    "$compiler" build "$fixture" -o "$out/$profile" ${options[@]+"${options[@]}"} --no-cache
    "$out/$profile"
done
cat > "$out/build-wasm.ab" <<WASM
import "abla/wasm/build"
val a = #wasmBuildModule("float-boundaries", "build/erased-float-boundaries/representation.ab", "build/erased-float-boundaries/release.wasm", false, false)
val b = #buildProgram("float-boundaries-fast", "build/erased-float-boundaries/representation.ab", "build/erased-float-boundaries/fast.wasm", "wasm32-module", "module", true, false)
fun main: int = if (a && b) 0 else 1
WASM
"$compiler" build "$out/build-wasm.ab" -o "$out/build-wasm" --fast --no-cache
"$out/build-wasm"
node tests/cases/erased-float-phase-a/run-wasm.mjs "$out/release.wasm"
node tests/cases/erased-float-phase-a/run-wasm.mjs "$out/fast.wasm"
echo 'erased float scalar boundaries preserve kind in native and hostless Wasm'
