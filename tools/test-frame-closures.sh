#!/usr/bin/env bash
# Closures that do not escape the frame that makes them keep their captures there,
# and cells that do not escape it are in it (src/backend/llvm/escape.ab). The
# analysis keeps exactly the closures and cells it should (ABLA_CLOSURE_TRACE), and
# every closure, kept in the frame or not, computes what it should natively, when
# every safe point collects, and in a WebAssembly module (closures kept across a
# generator's yields included).
# Editing a callee so that it keeps the closure, then rebuilding with the build
# cache, gives a heap closure that outlives its frame.
set -euo pipefail
compiler=${1:-build/ablac}
# The WebAssembly driver and the incremental case build from other directories:
# keep a relative compiler path pointing where it did.
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cases=$project_root/tests/cases/frame-closures
output_directory=$project_root/build/frame-closures
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

trace=$(ABLA_CLOSURE_TRACE=1 "$compiler" build "$cases/main.ab" \
    -o "$output_directory/closures" --no-cache 2>&1 | grep -E '^(closures|cells):' || true)
[[ $trace == $'closures: 6 of 12 with captures keep them in the frame\ncells: 5 of 14 in the frame' ]] ||
    { echo "frame closures: the analysis kept the wrong closures: $trace" >&2; exit 1; }
for stress in 0 1; do
    output=$(run "$output_directory/closures" ABLA_GC_STRESS=$stress)
    [[ $output == $'frame closures: 0 failed\nstatus 42' ]] ||
        { echo "frame closures (ABLA_GC_STRESS=$stress): $output" >&2; exit 1; }
done

if command -v node >/dev/null 2>&1; then wasm_runner=node; else wasm_runner=bun; fi
(cd "$project_root" && "$compiler" build tests/cases/frame-closures/build.ab \
    -o "$output_directory/wasm-driver" --no-cache > "$output_directory/wasm-driver.log" 2>&1) ||
    { cat "$output_directory/wasm-driver.log" >&2; exit 1; }
(cd "$project_root" && "$output_directory/wasm-driver")
wasm_output=$("$wasm_runner" "$cases/run.mjs" "$output_directory/frame-closures.wasm")
[[ $wasm_output == 0 ]] || { echo "frame closures (WebAssembly): $wasm_output failed" >&2; exit 1; }

# The incremental case, built with the build cache before and after the edit.
work=$output_directory/incremental
rm -rf "$work"
mkdir -p "$work"
cp "$cases/incremental/main.ab" "$cases/incremental/callee.ab" "$work/"
incremental() { # expected trace, expected output
    local trace output
    trace=$(cd "$work" && ABLA_CLOSURE_TRACE=1 "$compiler" build main.ab -o program 2>&1 |
        grep -E '^(closures|cells):' || true)
    [[ $trace == "$1" ]] ||
        { echo "frame closures, incremental: expected '$1', got '$trace'" >&2; exit 1; }
    output=$(run "$work/program" ABLA_GC_STRESS=1)
    [[ $output == "$2"$'\nstatus 0' ]] ||
        { echo "frame closures, incremental: $output" >&2; exit 1; }
}
incremental $'closures: 1 of 1 with captures keep them in the frame\ncells: 1 of 2 in the frame' \
    'total 21790 later 0'
cp "$cases/incremental/callee-keeps.ab" "$work/callee.ab"
incremental $'closures: 0 of 1 with captures keep them in the frame\ncells: 0 of 2 in the frame' \
    'total 21790 later 41690'

echo "frame closures: closures and cells that stay in their frame are kept there (native, stressed, WebAssembly), the rest on the heap; a callee edited to keep the closure rebuilds it and its cell on the heap"
