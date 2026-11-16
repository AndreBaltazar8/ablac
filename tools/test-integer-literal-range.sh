#!/usr/bin/env bash
# Integer literals: the largest u64 and below keep their bits in every base, anything larger is E_PARSE_INTEGER_RANGE
# (it used to wrap around silently), and `0x` with no digit is E_PARSE_INVALID_HEX (it used to be the integer 0).
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/integer-literal-range
rm -rf "$out"
mkdir -p "$out"
expected=$'18446744073709551615 18446744073709551615 18446744073709551615\n9223372036854775808 9223372036854775807 -9223372036854775808\n18446744073709551615 9223372036854775807 9223372036854775807\ntrue 255'
for profile in fast release; do
    flags=()
    [[ $profile == release ]] || flags=(--"$profile")
    "$compiler" build tests/cases/integer-literal-range/main.ab -o "$out/$profile" ${flags[@]+"${flags[@]}"} --no-cache
    got=$("$out/$profile")
    [[ $got == "$expected" ]] || { echo "integer literal range ($profile) printed:" >&2; echo "$got" >&2; exit 1; }
done
reject() { # $1 = literal, $2 = diagnostic code
    printf 'fun main: int {\n    val v = %s\n    0\n}\n' "$1" > "$out/case.ab"
    if "$compiler" build "$out/case.ab" -o "$out/case" --fast --no-cache > "$out/case.log" 2>&1; then
        echo "integer literal range: $1 was accepted" >&2; exit 1
    fi
    grep -Fq "error[$2]" "$out/case.log" || { echo "integer literal range: $1 lacks $2:" >&2; cat "$out/case.log" >&2; exit 1; }
}
for literal in 18446744073709551616 99999999999999999999 18_446_744_073_709_551_616 1_000_000_000_000_000_000_000 \
    0x10000000000000000 0x1FFFFFFFFFFFFFFFF 0X1_0000_0000_0000_0000 0o2000000000000000000000 0o7777777777777777777777; do
    reject "$literal" E_PARSE_INTEGER_RANGE
done
for literal in 0x 0X 0x_ 0x__; do
    reject "$literal" E_PARSE_INVALID_HEX
done
echo "integer literal range: up to the largest u64 kept in every base, larger and empty hex literals rejected"
