#!/usr/bin/env bash
# A large compile-time generation is generated as code generation units by child compilers at once, and its objects
# are loaded into the session (ct_jit.ab, bootstrapCtAddGeneration; #1022: the client's 5,326 functions took 9.5 s on
# one thread). ABLA_CODEGEN_UNITS_MINIMUM=1 makes every generation large enough here: the cases of
# tools/test-compile-eval-jit.sh still give their results (exit 42) from units, a second build takes every unit from the
# code generation cache, and ABLA_COMPILE_EVAL_UNITS=0 keeps the generation one module.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
cases="$project_root/tests/cases/compile-eval-jit"
output_directory="$project_root/build/compile-eval-units"
rm -rf "$output_directory"
mkdir -p "$output_directory"
export ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 ABLA_CODEGEN_UNITS_MINIMUM=1 ABLA_CODEGEN_UNITS_TRACE=1
export ABLA_CACHE_DIR="$output_directory/cache"

fail() { echo "compile-eval-units: $1" >&2; cat "$2" >&2; exit 1; }

build_and_run() { # name tag: builds and runs case `name`, its trace in <tag>.trace
    local name=$1 tag=$2
    "$compiler" build "$cases/$name.ab" -o "$output_directory/$tag" --no-cache 2> "$output_directory/$tag.trace" ||
        fail "$name did not build" "$output_directory/$tag.trace"
    set +e
    "$output_directory/$tag"
    local status=$?
    set -e
    [[ $status -eq 42 ]] || fail "$name exited $status, expected 42" "$output_directory/$tag.trace"
}

for name in scalars globals globals-exchange codec reach delegates; do
    build_and_run "$name" "$name"
    grep -qE '^note\[ct-jit\]: generation [0-9]+ \([0-9]+ instructions\) in [0-9]+ units and [0-9]+ functions in the session: ' \
        "$output_directory/$name.trace" ||
        fail "$name's generation was not made of units" "$output_directory/$name.trace"
    grep -q 'failed: status' "$output_directory/$name.trace" &&
        fail "$name's units did not load" "$output_directory/$name.trace"
done

# The same generation again: every unit comes from the cache.
build_and_run scalars scalars-again
units=$(sed -n 's/^codegen units: [0-9]* units and the data, \([0-9]*\) with code, .*/\1/p' \
    "$output_directory/scalars-again.trace" | head -1)
reused=$(sed -n 's/^codegen units: .*, \([0-9]*\) reused$/\1/p' "$output_directory/scalars-again.trace" | head -1)
[[ -n $units && $units -gt 1 && $reused == "$units" ]] ||
    fail "the second build reused $reused of $units units" "$output_directory/scalars-again.trace"

# Off: one module.
ABLA_COMPILE_EVAL_UNITS=0 build_and_run scalars scalars-off
grep -q ' units: ' "$output_directory/scalars-off.trace" &&
    fail "ABLA_COMPILE_EVAL_UNITS=0 still made units" "$output_directory/scalars-off.trace"
echo "compile-eval-units: generations made of units give the interpreter's results, reuse the cache, and can be turned off"
