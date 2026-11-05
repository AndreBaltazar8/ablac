#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
cd "$root"
out="$root/build/erased-float-format"
mkdir -p "$out"
for case in main imported user-symbol; do
    for profile in fast release; do
        options=()
        [[ $profile != fast ]] || options+=(--fast)
        "$compiler" build "$root/tests/cases/erased-float-format/$case.ab" -o "$out/$case-$profile" ${options[@]+"${options[@]}"} --no-cache
        "$out/$case-$profile"
    done
    ABLA_GC_STRESS=1 "$out/$case-fast"
done
for case in dynamic-fields extension-only; do
    fixture=$("$root/tools/runtime-fixture.sh" "$root/tests/cases/erased-float-format/$case.ab" "$out/$case")
    ABLA_STDLIB="$out/$case/stdlib" "$compiler" build "$fixture" -o "$out/$case/program" --fast --no-cache
    "$out/$case/program"
done
"$compiler" build "$root/tests/cases/erased-float-format/staged.ab" -o "$out/staged" --fast --no-cache
"$out/staged"
cat > "$out/build-wasm.ab" <<WASM
import "abla/wasm/build"
val a = #wasmBuildModule("erased-float", "tests/cases/erased-float-format/main.ab", "build/erased-float-format/release.wasm", false, false)
val b = #buildProgram("erased-float-fast", "tests/cases/erased-float-format/main.ab", "build/erased-float-format/fast.wasm", "wasm32-module", "module", true, false)
fun main: int = if (a && b) 0 else 1
WASM
"$compiler" build "$out/build-wasm.ab" -o "$out/build-wasm" --fast --no-cache
"$out/build-wasm"
node tests/cases/erased-float-phase-a/run-wasm.mjs "$out/release.wasm"
node tests/cases/erased-float-phase-a/run-wasm.mjs "$out/fast.wasm"
echo 'erased float interpolation matches typed formatting in native and hostless Wasm'
