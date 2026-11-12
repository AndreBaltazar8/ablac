#!/usr/bin/env bash
# Executing regressions for erased-float lifting. The repro parent records
# known failures; phase (d) requires all cases to pass, with no JIT fallback.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
cd "$root"
out="$root/build/compile-time-erased-floats"
cases="$root/tests/cases/compile-time-erased-floats"
expect=${ERASED_FLOAT_LIFT_EXPECT:-$cases/expected.txt}
options=()
[[ ${ERASED_FLOAT_LIFT_PROFILE:-fast} != fast ]] || options+=(--fast)
mkdir -p "$out"
# The wire client needs the normal compiler graph, not the representation inspector.
# Prepare it before ABLA_STDLIB changes so other API tests share this cold build.
program=$("$root/tools/compiler-api-test-program.sh" "$compiler")
"$root/tools/runtime-fixture.sh" "$cases/inspect.ab" "$out" >/dev/null
export ABLA_STDLIB="$out/stdlib"
# Inspecting representations is runtime-only: the staged code does not call
# the raw runtime inspectors or depend on the unfinished float formatter.
sites=$(grep -c '= #' "$cases/values.ab")
for mode in interp jit; do
    prefix="$out/$mode"
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 \
        "$compiler" build "$cases/main.ab" -o "$prefix" ${options[@]+"${options[@]}"} --no-cache \
        > "$prefix.build.log" 2>&1 || { cat "$prefix.build.log" >&2; exit 1; }
    if [[ $mode == jit ]]; then
        actual=$(grep 'note\[ct-jit\]: native at ' "$prefix.build.log" | sort -u | wc -l)
        [[ $actual -eq $sites ]] || {
            echo "erased float lift: JIT ran $actual of $sites sites" >&2
            cat "$prefix.build.log" >&2
            exit 1
        }
    fi
    "$prefix" > "$prefix.stdout"
    awk -v mode="$mode" '$1 == mode {print $2 ":" $3}' "$expect" > "$prefix.expected"
    diff -u "$prefix.expected" "$prefix.stdout"
    echo "erased float lift: $mode, all cases executed; expected outcomes match"
done
ABLA_COMPILER_API_CASE=lift-wire "$program"
echo "erased float lift: wire versions, exact kinds, static fallback and cycles"
cat > "$out/wasm-driver.ab" <<'WASM'
import "abla/wasm/build"
val release = #wasmBuildModule("ct-erased-floats", "tests/cases/compile-time-erased-floats/wasm.ab", "build/compile-time-erased-floats/release.wasm", false, false)
val fast = #buildProgram("ct-erased-floats-fast", "tests/cases/compile-time-erased-floats/wasm.ab", "build/compile-time-erased-floats/fast.wasm", "wasm32-module", "module", true, false)
fun main: int = if (release && fast) 0 else 1
WASM
"$compiler" build "$out/wasm-driver.ab" -o "$out/wasm-driver" --fast --no-cache
"$out/wasm-driver"
node tests/cases/erased-float-phase-a/run-wasm.mjs "$out/release.wasm"
node tests/cases/erased-float-phase-a/run-wasm.mjs "$out/fast.wasm"
echo "erased float lift: native and hostless Wasm agree"
