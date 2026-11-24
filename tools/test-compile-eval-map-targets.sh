#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler=$root/$compiler
cd "$root"
export ABLA_DEBUG=0 ABLA_COMPILE_EVAL_TRACE=1 ABLA_COMPILE_EVAL_TRIAL_STEPS=0
out=build/compile-eval-map-targets
cases=tests/cases/compile-eval-map-targets
mkdir -p "$out"
map_site=$(( $(grep -boaF 'val MAP = #' "$cases/main.ab" | cut -d: -f1) + 10 ))
for target in native wasm; do
    flags=()
    runner=()
    if [[ $target == wasm ]]; then flags=(--target wasm32-wasi); runner=(wasmtime); fi
    for mode in interp jit auto; do
        log="$out/$target-$mode.log"
        program="$out/$target"
        ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/main.ab" --fast --no-cache \
            "${flags[@]}" -o "$program" >"$log" 2>&1
        if [[ $mode == interp ]]; then
            cp "$program" "$program-reference"
        else
            cmp "$program-reference" "$program"
            if ! grep -E "^note\[ct-jit\]: native at .*compile-eval-map-targets/main[.]ab:$map_site$" "$log" >/dev/null; then
                cat "$log" >&2
                echo "compile-eval-map-targets: $target $mode did not run the Map site natively" >&2
                exit 1
            fi
            if [[ $target == wasm ]]; then
                grep -E 'interpreted at .*expression float' "$log" >/dev/null
            fi
        fi
        status=0
        "${runner[@]}" "$program" || status=$?
        [[ $status == 42 ]]

        fail_log="$out/fail-$target-$mode.log"
        status=0
        ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/fail.ab" --fast --no-cache \
            "${flags[@]}" -o "$out/fail-$target" >"$fail_log" 2>&1 || status=$?
        [[ $status == 1 ]]
        grep -Fx 'error[E_CT_PANIC]: catalog key missing' "$fail_log" >/dev/null
        if [[ $mode != interp ]]; then
            grep -E 'no rerun at .*compile-eval-map-targets/fail[.]ab:' "$fail_log" >/dev/null
        fi
    done
done
echo 'compile-eval-map-targets: ordered maps and missing-key diagnostics agree'
