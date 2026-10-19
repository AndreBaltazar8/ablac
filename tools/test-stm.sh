#!/usr/bin/env bash
# The runtime's transactions (stdlib/abla/runtime/self/entry.ab, no language
# surface yet): one thread running them directly and logged, with collections
# inside them (natively, with ABLA_GC_STRESS=1, and in a WebAssembly module);
# eight threads moving money among sixteen TVars while two audit the total; a
# one-slot channel whose ends wake each other through retry; a retry no thread
# could wake; and a panic contained by a checked export rolling a transaction
# back. tests/cases/stm/bench.ab measures their cost (not run here).
set -euo pipefail
compiler=${1:-build/ablac}
# The WebAssembly driver builds from the project root: keep a relative compiler
# path pointing where it did.
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cases=$project_root/tests/cases/stm
output_directory=$project_root/build/stm
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

build() { # case output
    "$compiler" build "$cases/$1" -o "$output_directory/$2" --no-cache \
        > "$output_directory/$2.log" 2>&1 || { cat "$output_directory/$2.log" >&2; exit 1; }
}

build basic.ab single
for stress in 0 1; do
    output=$(run "$output_directory/single" ABLA_GC_STRESS=$stress)
    [[ $output == $'single thread: 0 failed, commits 201 abandoned 0\nstatus 42' ]] ||
        { echo "stm, one thread (ABLA_GC_STRESS=$stress): $output" >&2; exit 1; }
done

build bank.ab bank
output=$(run "$output_directory/bank")
[[ $output == *$'wrong audits 0, total 1600, conflicts true\nstatus 42' ]] ||
    { echo "stm, bank: $output" >&2; exit 1; }

build retry.ab retry
output=$(run "$output_directory/retry")
[[ $output == $'produced 5000, sum 12502500\nstatus 42' ]] ||
    { echo "stm, retry: $output" >&2; exit 1; }

build retry-alone.ab retry-alone
output=$(run "$output_directory/retry-alone")
[[ $output == *'panic: retry can never wake'*$'\nstatus 101' ]] ||
    { echo "stm, retry with no other thread: $output" >&2; exit 1; }

library=$output_directory/libstmrollback.so
if [[ $(uname -s) == Darwin ]]; then library=$output_directory/libstmrollback.dylib; fi
"$compiler" build "$cases/rollback/library.ab" --emit shared-library -o "$library" \
    --no-cache > "$output_directory/rollback.log" 2>&1 ||
    { cat "$output_directory/rollback.log" >&2; exit 1; }
clang "$cases/rollback/caller.c" -L"$output_directory" -lstmrollback \
    -Wl,-rpath,"$output_directory" -o "$output_directory/rollback"
output=$(run "$output_directory/rollback")
[[ $output == 'status 42' ]] || { echo "stm, rollback: $output" >&2; exit 1; }

if command -v node >/dev/null 2>&1; then wasm_runner=node; else wasm_runner=bun; fi
(cd "$project_root" && "$compiler" build tests/cases/stm/build.ab \
    -o "$output_directory/wasm-driver" --no-cache > "$output_directory/wasm-driver.log" 2>&1) ||
    { cat "$output_directory/wasm-driver.log" >&2; exit 1; }
(cd "$project_root" && "$output_directory/wasm-driver")
wasm_output=$("$wasm_runner" "$cases/run.mjs" "$output_directory/stm.wasm")
[[ $wasm_output == 0 ]] || { echo "stm (WebAssembly): $wasm_output failed" >&2; exit 1; }

echo "stm: transactions direct and logged keep what they wrote through collections (native, stressed, WebAssembly); eight threads keep a total under conflicts; retry wakes on a change and panics when nothing could change; a contained panic rolls a transaction back"
