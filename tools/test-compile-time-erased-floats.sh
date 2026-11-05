#!/usr/bin/env bash
# Executing regressions for erased-float lifting. Known failures are asserted,
# never skipped; phase (d) changes their expectation to pass with the fix.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
cd "$root"
out="$root/build/compile-time-erased-floats"
cases="$root/tests/cases/compile-time-erased-floats"
expect=${ERASED_FLOAT_LIFT_EXPECT:-$cases/expected.txt}
mkdir -p "$out"
"$root/tools/runtime-fixture.sh" "$cases/inspect.ab" "$out" >/dev/null
export ABLA_STDLIB="$out/stdlib"
# Inspecting representations is runtime-only: the staged code does not call
# the raw runtime inspectors or depend on the unfinished float formatter.
sites=$(grep -c '= #' "$cases/main.ab")
for mode in interp jit; do
    prefix="$out/$mode"
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 \
        "$compiler" build "$cases/main.ab" -o "$prefix" --fast --no-cache \
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
    echo "erased float lift: $mode, all cases executed; known failures match"
done
