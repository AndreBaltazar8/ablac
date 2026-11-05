#!/usr/bin/env bash
# Native closures carry positional raw captures until the lowering probe can
# type them. The developer codec check must preserve their bindings and aliases.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
cd "$root"
out="$root/build/lift-codec-closures"
mkdir -p "$out"
for name in closures more positional-codec; do
    for mode in interp jit; do
        for check in 0 1; do
            stem="$out/$name-$mode-$check"
            ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 ABLA_LIFT_CODEC_CHECK=$check \
                "$compiler" --emit-llvm "tests/cases/compile-time-lift/$name.ab" \
                > "$stem.ir" 2> "$stem.emit.log" || { cat "$stem.emit.log" >&2; exit 1; }
            if [[ $mode == jit ]]; then
                expected=$(grep -c '= #' "tests/cases/compile-time-lift/$name.ab")
                actual=$(grep 'note\[ct-jit\]: native at ' "$stem.emit.log" | sort -u | wc -l)
                [[ $actual -eq $expected ]] || {
                    echo "closure codec: $name ran $actual of $expected JIT sites" >&2
                    exit 1
                }
            fi
            ABLA_COMPILE_EVAL=$mode ABLA_LIFT_CODEC_CHECK=$check \
                "$compiler" build "tests/cases/compile-time-lift/$name.ab" -o "$stem" --fast --no-cache \
                > "$stem.build.log" 2>&1 || { cat "$stem.build.log" >&2; exit 1; }
            status=0
            "$stem" || status=$?
            [[ $status -eq 42 ]] || { echo "closure codec: $name/$mode/$check exited $status" >&2; exit 1; }
            status=0
            ABLA_GC_STRESS=1 "$stem" || status=$?
            [[ $status -eq 42 ]] || { echo "closure codec: $name/$mode/$check failed GC stress" >&2; exit 1; }
        done
        cmp "$out/$name-$mode-0.ir" "$out/$name-$mode-1.ir"
    done
    echo "closure codec: $name preserves named/positional bindings, typed captures and sharing"
done
