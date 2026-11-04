#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/octal-literals
mkdir -p "$out"
for profile in fast o1 release; do
    flags=()
    [[ $profile == release ]] || flags=(--"$profile")
    "$compiler" build tests/cases/octal-literals/main.ab -o "$out/$profile" ${flags[@]+"${flags[@]}"} --no-cache
    status=0
    "$out/$profile" || status=$?
    [[ $status == 42 ]] || exit 1
done
for literal in 0o8 0o9 0o78 0o7_9 0O9 0o 0o___; do
    printf 'fun main: int = %s\n' "$literal" > "$out/invalid-$literal.ab"
    if "$compiler" build "$out/invalid-$literal.ab" -o "$out/invalid" --fast --no-cache > "$out/invalid-$literal.log" 2>&1; then
        echo "$literal unexpectedly accepted" >&2; exit 1
    fi
    grep -Fq 'error[E_PARSE_INVALID_OCTAL]' "$out/invalid-$literal.log" || { cat "$out/invalid-$literal.log" >&2; exit 1; }
done
echo 'octal literals: value/default/CT parity, separators, decimal/hex/float unchanged, malformed digits rejected'
