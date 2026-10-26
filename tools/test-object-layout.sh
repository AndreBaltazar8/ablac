#!/usr/bin/env bash
# Instances store their declared fields by kind (stdlib/abla/runtime/self/
# entry.ab): every kind reads and writes typed and by name and survives
# collections, natively (also when every safe point collects,
# ABLA_GC_STRESS=1) and in a WebAssembly module; instances cost what their
# fields' kinds do; and the compile-time lift carries every kind.
set -euo pipefail
compiler=${1:-build/ablac}
# The lift case builds from inside its case directory: keep a relative compiler
# path pointing where it did.
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/object-layout"
mkdir -p "$output_directory"

run() { # program [environment...]
    local program=$1 status
    shift
    set +e
    env "$@" ABLA_MAX_SECONDS=120 "$project_root/tools/run-limited.sh" "$program" 2>&1
    status=$?
    set -e
    echo "status $status"
}

"$compiler" build "$project_root/tests/cases/object-layout/main.ab" \
    -o "$output_directory/layout" --no-cache > "$output_directory/layout.log" 2>&1 ||
    { cat "$output_directory/layout.log" >&2; exit 1; }
for stress in 0 1; do
    output=$(run "$output_directory/layout" ABLA_GC_STRESS=$stress)
    [[ $output == $'object layout: 0 failed\nobject sizes: 0 failed\nstatus 42' ]] ||
        { echo "object layout (ABLA_GC_STRESS=$stress): $output" >&2; exit 1; }
done

# Built at compile time (natively: the interpreter doesn't run the runtime's raw
# memory) and lifted into the program.
(cd "$project_root/tests/cases/object-layout/lift" && ABLA_COMPILE_EVAL=jit "$compiler" build \
    main.ab -o "$output_directory/lift" --no-cache > "$output_directory/lift.log" 2>&1) ||
    { cat "$output_directory/lift.log" >&2; exit 1; }
for stress in 0 1; do
    output=$(run "$output_directory/lift" ABLA_GC_STRESS=$stress)
    [[ $output == $'lifted object layout: 0 failed\nstatus 42' ]] ||
        { echo "object layout, lifted (ABLA_GC_STRESS=$stress): $output" >&2; exit 1; }
done

if command -v node >/dev/null 2>&1; then wasm_runner=node; else wasm_runner=bun; fi
(cd "$project_root" && "$compiler" build tests/cases/object-layout/build.ab \
    -o "$output_directory/wasm-driver" --no-cache > "$output_directory/wasm-driver.log" 2>&1) ||
    { cat "$output_directory/wasm-driver.log" >&2; exit 1; }
(cd "$project_root" && "$output_directory/wasm-driver")
wasm_output=$("$wasm_runner" "$project_root/tests/cases/object-layout/run.mjs" \
    "$output_directory/object-layout.wasm")
[[ $wasm_output == 0 ]] || { echo "object layout (WebAssembly): $wasm_output failed" >&2; exit 1; }
echo "object layout: every field kind typed, by name, collected (native, stressed, WebAssembly) and lifted; instances cost their fields' kinds"
