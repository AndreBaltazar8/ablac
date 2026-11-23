#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/any-text-panic"
mkdir -p "$out"
cd "$root"
"$compiler" build tests/cases/any-text-panic/main.ab -o "$out/main" --fast
status=0
"$out/main" >"$out/native.out" 2>"$out/native.err" || status=$?
[[ $status -eq 101 ]]
grep -qx 'panic: unsupported value (runtime tag 8)' "$out/native.err"
"$compiler" build tests/cases/any-text-panic/build.ab -o "$out/build" --fast
"$out/build"
node tests/cases/any-text-panic/run.mjs "$out/main.wasm"
# At compile time the same interpolation is an error with the same text, in the evaluator and in the native tier.
for tier in interp jit; do
    if ABLA_COMPILE_EVAL=$tier "$compiler" build tests/cases/any-text-panic/compile-time.ab -o "$out/compile-time-$tier" --fast --no-cache \
        >"$out/compile-time-$tier.out" 2>&1; then
        echo "any text panic: the $tier tier built a program whose \`#\` site interpolates an object" >&2
        exit 1
    fi
    grep -q 'unsupported value (runtime tag 8)' "$out/compile-time-$tier.out" || {
        echo "any text panic: the $tier tier's error lacks the panic text:" >&2
        head -5 "$out/compile-time-$tier.out" >&2
        exit 1
    }
done
echo 'unsupported any interpolation reports a readable panic, natively and at compile time'
