#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
compiler=${1:-build/ablac}
out=build/regex-named
cases=tests/cases/regex-named
mkdir -p "$out"
for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build "$cases/main.ab" --fast --no-cache -o "$out/$tier"
    [[ $("$out/$tier") == ok ]]
done
"$compiler" build "$cases/main.ab" --no-cache -o "$out/release"
[[ $(ABLA_GC_STRESS=1 "$out/release") == ok ]]
for name in missing-field optional-field; do
    log="$out/$name.log"
    if "$compiler" build "$cases/$name.ab" --fast --no-cache -o "$out/invalid" >"$log" 2>&1; then
        printf 'unexpected success: %s\n' "$name" >&2
        exit 1
    fi
    if [[ $name == missing-field ]]; then
        rg -q 'member:.*\.month' "$log" || { cat "$log"; exit 1; }
    else
        rg -q 'wrong.*string.*string' "$log" || { cat "$log"; exit 1; }
    fi
done
printf 'regex named captures: ok\n'
