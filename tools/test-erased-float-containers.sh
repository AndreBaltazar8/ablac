#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
cd "$root"
out="$root/build/erased-float-containers"
mkdir -p "$out"
fixture=$("$root/tools/runtime-fixture.sh" "$root/tests/cases/erased-float-phase-b/containers.ab" "$out")
export ABLA_STDLIB="$out/stdlib"
for profile in fast release; do
    options=()
    [[ $profile != fast ]] || options+=(--fast)
    "$compiler" build "$fixture" -o "$out/$profile" ${options[@]+"${options[@]}"} --no-cache
    "$out/$profile"
done
ABLA_GC_STRESS=1 "$out/fast"
ABLA_CODEGEN_UNITS=4 ABLA_CODEGEN_UNITS_MINIMUM=0 "$compiler" build "$fixture" \
    -o "$out/units" --fast --no-cache
"$out/units"
cat > "$out/build-wasm.ab" <<WASM
import "abla/wasm/build"
val a = #wasmBuildModule("float-containers", "build/erased-float-containers/containers.ab", "build/erased-float-containers/release.wasm", false, false)
val b = #buildProgram("float-containers-fast", "build/erased-float-containers/containers.ab", "build/erased-float-containers/fast.wasm", "wasm32-module", "module", true, false)
fun main: int = if (a && b) 0 else 1
WASM
"$compiler" build "$out/build-wasm.ab" -o "$out/build-wasm" --fast --no-cache
"$out/build-wasm"
node tests/cases/erased-float-phase-a/run-wasm.mjs "$out/release.wasm"
node tests/cases/erased-float-phase-a/run-wasm.mjs "$out/fast.wasm"
unset ABLA_STDLIB
for case in field-only nullable-field-only nominal-field-only generic-field-only generic-array-field-only array-only; do
    isolated=$("$root/tools/runtime-fixture.sh" "$root/tests/cases/erased-float-phase-b/$case.ab" "$out/$case")
    ABLA_STDLIB="$out/$case/stdlib" "$compiler" build "$isolated" -o "$out/$case/program" --no-cache
    "$out/$case/program"
done
echo 'erased float containers preserve kind in native and hostless Wasm'
