#!/usr/bin/env bash
# Generators nest and are lazy (the body runs as far as the consumer asks; breaking,
# returning or dropping closes one, running defers and dropping what it owns), and
# `yield` takes a whole expression; an affine element of an array iterated in place is borrowed,
# so awaiting or moving it is rejected, while iterating `move(array)` owns the elements.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/generators-tasks"
mkdir -p "$output_directory"

check() {
    "$compiler" build "$project_root/tests/cases/modules/$1.ab" \
        -o "$output_directory/$1" --no-cache
    set +e
    output=$("$output_directory/$1")
    status=$?
    set -e
    [[ $status -eq 0 && $output == "$2" ]] || { echo "$1: status $status, output '$output'"; exit 1; }
}

# The same program through `ablac run` (the in-process JIT).
check_run() {
    set +e
    output=$("$compiler" run "$project_root/tests/cases/modules/$1.ab" 2>&1)
    status=$?
    set -e
    [[ $status -eq 0 && $output == "$2" ]] || { echo "$1 (run): status $status, output '$output'"; exit 1; }
}

reject() {
    set +e
    diagnostics=$("$compiler" build "$project_root/tests/cases/modules/$1.ab" \
        -o "$output_directory/$1" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 && $diagnostics == *"$2"* ]] || { echo "$1: expected $2"; echo "$diagnostics"; exit 1; }
}

check generator-nested 114
check generator-lazy $'produce 0\ngot 0\nproduce 1\ngot 1\nproduce 2\ngot 2\ntotal 5050\nstart\nv 1\nclosed\n--\nstart\nv 1\nafter 1\nv 2\nafter 2\nclosed\n--\ndropping\na\nbb\nb!\nb!\nc\nu0\nu1\nu2\nc1\nc2\nzero\none\none!\nmany\no 10\nclose a\nclose r\nfirst 1\nlevel 0\nlevel 2\nlevel 4\nlevel 5\nend'
check generator-affine $'got 7\ngot 8\ndrop 8\ndrop 7\n--\ngot 7\ngot 8\ngot 3\ndrop 8\ndrop 7\n--\ngot 1\ndefer sees 9\ndrop 9\ngot 2\n--\ngot 0\ngot 5\ndrop 5\n--\nend\ndrop 7'
check task-array-move 6
check generator-task-capture $'1\n4\nfinished 4'
check_run generator-task-capture $'1\n4\nfinished 4'
check_run generator-lazy $'produce 0\ngot 0\nproduce 1\ngot 1\nproduce 2\ngot 2\ntotal 5050\nstart\nv 1\nclosed\n--\nstart\nv 1\nafter 1\nv 2\nafter 2\nclosed\n--\ndropping\na\nbb\nb!\nb!\nc\nu0\nu1\nu2\nc1\nc2\nzero\none\none!\nmany\no 10\nclose a\nclose r\nfirst 1\nlevel 0\nlevel 2\nlevel 4\nlevel 5\nend'
# Generators in a WebAssembly module (no stack switching, no host runtime).
if command -v node >/dev/null 2>&1; then wasm_runner=node; else wasm_runner=bun; fi
(cd "$project_root" && "$compiler" build tests/cases/generator-wasm/build.ab \
    -o "$output_directory/generator-wasm-driver" --no-cache)
"$output_directory/generator-wasm-driver"
wasm_output=$("$wasm_runner" "$project_root/tests/cases/generator-wasm/run.mjs" \
    "$output_directory/generator-wasm.wasm" 20)
[[ $wasm_output == 2481402 ]] || { echo "generator-wasm: output '$wasm_output'"; exit 1; }

reject invalid-generator-yield-position "generator.yield-position"
reject task-array-borrow "ownership.await-borrow:each"
reject task-array-borrow-move "move.local"
echo "generators and tasks: laziness, closing, nesting, WebAssembly, yield precedence, borrowed task elements"
