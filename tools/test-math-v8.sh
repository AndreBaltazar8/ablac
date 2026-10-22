#!/usr/bin/env bash
# abla/math/v8 declares the public interface of abla/math (interface.ab) and
# gives the bits of Node 22's Math on x86-64 (tests/cases/math-v8/run.mjs, by
# digests recorded from that Node): natively at every optimization level, as
# release and development WebAssembly, and under `#` in the evaluator and the
# native tier. MATH_V8_SAMPLES sets the inputs per function for the native and
# WebAssembly checks (250000; expected.json records 1000000 and 4000000 too).
# The harness runs on Node 22.14.0 (V8 12.4.254.21), the release the digests
# were recorded from; MATH_V8_NODE names its executable.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/math-v8"
cases="$project_root/tests/cases/math-v8"
samples=${MATH_V8_SAMPLES:-250000}
mkdir -p "$output_directory/ct"

node=${MATH_V8_NODE:-$HOME/.nvm/versions/node/v22.14.0/bin/node}
expected_v8=12.4.254.21-node.22
if [[ ! -x $node ]]; then
    echo "math-v8: needs Node 22.14.0 at $node (or MATH_V8_NODE)" >&2
    exit 1
fi
node_v8=$("$node" -p process.versions.v8)
if [[ $node_v8 != "$expected_v8" ]]; then
    echo "math-v8: $node has V8 $node_v8, expected $expected_v8" >&2
    exit 1
fi

run_42() {
    local program=$1 status
    set +e
    "$program"
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "math-v8: $program exited $status" >&2; return 1; }
}

# The checks are independent and run side by side; each writes only its own files.
check_semantics() {
    "$compiler" build "$cases/interface.ab" -o "$output_directory/interface" --no-cache
    run_42 "$output_directory/interface"
    "$compiler" build "$cases/semantics.ab" -o "$output_directory/semantics" --no-cache
    run_42 "$output_directory/semantics"
    ABLA_COMPILE_EVAL=jit "$compiler" build "$cases/semantics.ab" \
        -o "$output_directory/semantics-jit" --no-cache
    run_42 "$output_directory/semantics-jit"
}

check_native() { # profile
    local profile=$1 flags=()
    [[ $profile == o2 ]] || flags=("--$profile")
    "$compiler" build "$cases/native.ab" -o "$output_directory/native-$profile" \
        ${flags[@]+"${flags[@]}"} --no-cache
    "$node" "$cases/run.mjs" native "$output_directory/native-$profile" \
        "$output_directory/io-$profile" "$samples"
}

check_wasm() {
    rm -f "$output_directory"/math-v8*.wasm
    (cd "$project_root" && "$compiler" build "$cases/build.ab" \
        -o "$output_directory/build-driver" --no-cache)
    (cd "$project_root" && "$output_directory/build-driver")
    local module
    for module in math-v8 math-v8-fast; do
        "$node" "$cases/run.mjs" wasm "$output_directory/$module.wasm" "$samples"
    done
}

check_compile_time() { # tier
    local tier=$1
    ABLA_COMPILE_EVAL=$tier "$compiler" build "$output_directory/ct/program.ab" \
        -o "$output_directory/ct/program-$tier" --no-cache
    "$output_directory/ct/program-$tier" >"$output_directory/ct/results-$tier.txt"
    "$node" "$cases/run.mjs" ct-check "$output_directory/ct/results-$tier.txt" 2000
}

"$node" "$cases/run.mjs" ct-write "$output_directory/ct/program.ab" 2000
pids=()
(check_semantics) & pids+=("$!")
for profile in fast o1 o2; do
    (check_native "$profile") & pids+=("$!")
done
(check_wasm) & pids+=("$!")
for tier in interp jit; do
    (check_compile_time "$tier") & pids+=("$!")
done
failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
done
rm -rf "$output_directory"/io-*
[[ $failed -eq 0 ]] || exit 1

echo "math-v8: interface alike; native fast/o1/o2, wasm release/fast and # (evaluator and native tier) bit-identical to Node 22.14 (V8 $expected_v8) x86-64 Math"
