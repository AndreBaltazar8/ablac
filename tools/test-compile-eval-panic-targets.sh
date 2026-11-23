#!/usr/bin/env bash
# Compare staged panic handling by target and evaluation tier.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler=$root/$compiler
cd "$root"
export ABLA_DEBUG=0 ABLA_COMPILE_EVAL_TRACE=1 ABLA_COMPILE_EVAL_TRIAL_STEPS=0
out=build/compile-eval-panic-targets
mkdir -p "$out"
input=tests/cases/compile-eval-panic-targets/main.ab
for target in native wasm; do
    flags=()
    runner=()
    if [[ $target == wasm ]]; then flags=(--target wasm32-wasi); runner=(wasmtime); fi
    for mode in interp jit auto; do
        log="$out/$target-$mode.log"
        ABLA_COMPILE_EVAL=$mode "$compiler" build "$input" --fast --no-cache \
            "${flags[@]}" -o "$out/$target" > "$log" 2>&1
        if [[ $mode == interp ]]; then
            cp "$out/$target" "$out/$target-interp.bin"
        else
            cmp "$out/$target-interp.bin" "$out/$target"
            if ! grep -Eq '^note\[ct-jit\]: native at .*compile-eval-panic-targets/main[.]ab:' "$log"; then
                cat "$log" >&2
                echo "compile-eval-panic-targets: $target $mode must run the catalog site natively" >&2
                exit 1
            fi
        fi
        status=0
        "${runner[@]}" "$out/$target" || status=$?
        [[ $status == 42 ]]
    done
done

# Recover the message from an actual stop, including an empty message or one
# larger than the generic runtime panic catcher's buffer.
printf -v long '%02048d' 0
for message in 'catalog is empty' '' "$long" 'abla.ct.exit:ordinary panic text'; do
    printf 'import "abla/process/exit"\ncompile fun stopped(): int = panic("%s")\nval STOPPED = #stopped()\nfun main: int = STOPPED\n' \
        "$message" > "$out/stopped.ab"
    for target in native wasm; do
        # The host's existing runtime catcher has a bounded message buffer.
        if [[ $target == native && $message != 'catalog is empty' ]]; then continue; fi
        flags=()
        if [[ $target == wasm ]]; then flags=(--target wasm32-wasi); fi
        for mode in interp jit; do
            log="$out/stopped-$target-$mode.log"
            status=0
            ABLA_COMPILE_EVAL=$mode "$compiler" build "$out/stopped.ab" --fast --no-cache \
                "${flags[@]}" -o "$out/stopped-$target" > "$log" 2>&1 || status=$?
            [[ $status == 1 ]]
            grep -Fxq "error[E_CT_PANIC]: $message" "$log"
            if [[ $mode == jit && $target == wasm ]]; then
                grep -q 'note\[ct-jit\]: no rerun at .*stopped.ab:' "$log"
            fi
        done
    done
done

# Initializers may run before a native entry's bridge frame is active.
cat > "$out/eager.ab" <<'ABLA'
import "abla/process/exit"
fun valueOrPanic(stopped: bool): int {
    if (stopped) panic("initializer stopped")
    42
}
val EAGER = valueOrPanic(false)
val RESULT = #(EAGER + 0)
fun main: int = RESULT
ABLA
ABLA_COMPILE_EVAL=jit "$compiler" build "$out/eager.ab" --target wasm32-wasi --fast --no-cache \
    -o "$out/eager" > "$out/eager.log" 2>&1
grep -q 'interpreted at .*cross-target site replays global .*EAGER initializer reaching panic' "$out/eager.log"
echo 'compile-eval-panic-targets: portable success, matching artifacts and matching panic diagnostics passed'
