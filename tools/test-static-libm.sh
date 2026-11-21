#!/usr/bin/env bash
# #1045: the static C library's expm1, log1p, log2, log10, asin, acos, sinh, cosh, tanh, erf and erfc (src/static_libc/crmath.ab) are
# correctly rounded: compares them with MPFR on random arguments over each function's domain (and random bit patterns), count per range
# from the second argument. Needs mpfr and gmp with headers (nix-shell -p mpfr.dev gmp.dev is used when `gcc -lmpfr` fails).
# Usage: tools/test-static-libm.sh [compiler] [count per range, default 300]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
count=${2:-300}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/static-libm"
rm -rf "$out"
mkdir -p "$out"
if ! gcc -O2 -o "$out/oracle" tools/libm-oracle.c -lmpfr -lgmp 2> "$out/oracle.log"; then
    nix-shell -p mpfr.dev gmp.dev --run "gcc -O2 -o '$out/oracle' tools/libm-oracle.c -lmpfr -lgmp" ||
        { echo 'static libm: cannot build the MPFR oracle' >&2; exit 1; }
fi
# function, Abla name, ranges (lo hi pairs)
specs=(
    "expm1 Expm1 -1.0 1.0 -30.0 30.0 -1.0e-3 1.0e-3 0.0 700.0 -1.0e-15 1.0e-15"
    "log1p Log1p -0.99 0.5 -0.3 0.42 0.0 1.0e3 -1.0e-9 1.0e-9 -0.999999 -0.99 0.0 1.0e300"
    "log2 Log2 0.0 4.0 0.5 2.0 0.999 1.001 0.0 1.0e300 1.0e-300 1.0e-290"
    "log10 Log10 0.0 4.0 0.5 2.0 0.999 1.001 0.0 1.0e300 1.0e-300 1.0e-290 9.9 10.1"
    "asin Asin -1.0 1.0 0.0 1.0e-3 0.99 1.0 0.9999999 1.0 -1.0e-10 1.0e-10"
    "acos Acos -1.0 1.0 0.0 1.0e-3 0.99 1.0 0.9999999 1.0 -1.0 -0.9999999"
    "sinh Sinh -1.0 1.0 -30.0 30.0 -1.0e-3 1.0e-3 0.0 710.0 -1.0e-15 1.0e-15"
    "cosh Cosh -1.0 1.0 -30.0 30.0 -1.0e-3 1.0e-3 0.0 710.0"
    "tanh Tanh -1.0 1.0 -22.0 22.0 -1.0e-3 1.0e-3 0.0 20.0 -1.0e-15 1.0e-15"
    "erf Erf -6.0 6.0 -1.0 1.0 -1.0e-3 1.0e-3 0.0 6.0 -1.0e-15 1.0e-15"
    "erfc Erfc -6.0 6.0 -1.0 1.0 0.0 28.0 5.0 27.3 1.0e-10 1.0e-3"
)
status=0
for spec in "${specs[@]}"; do
    read -r name cap ranges <<< "$spec"
    list=$(echo "$ranges" | sed 's/ /, /g; s/\([^,]*, [^,]*\), /\1,\n/g' | tr -d '\n')
    cat > "$out/$name.ab" <<ABLA
import "abla/io"
import "abla/float"
import "$root/src/static_libc/crmath.ab"

var state = 88172645463325252
fun next(): int {
    state = state ^ (state << 13)
    state = state ^ (state >>> 7)
    state = state ^ (state << 17)
    state
}
fun uniform(lo: f64, hi: f64): f64 = lo + (hi - lo) * (f64FromInt(next() >>> 11) / 9007199254740992.0)

fun main: int {
    val ranges: array<f64> = [${ranges// /, }]
    for (r in 0 until ranges.size / 2) {
        for (i in 0 until $count) {
            val x = uniform(ranges[2 * r], ranges[2 * r + 1])
            println("\${f64ToBits(x)} \${f64ToBits(libcCr$cap(x))}")
        }
    }
    for (i in 0 until $count) {
        val x = f64FromBits(next())
        if (x == x && x - x == 0.0) println("\${f64ToBits(x)} \${f64ToBits(libcCr$cap(x))}")
    }
    0
}
ABLA
    "$compiler" build "$out/$name.ab" -o "$out/$name" --fast --no-cache > "$out/$name.build.log" 2>&1 ||
        { echo "static libm: $name did not build" >&2; tail -20 "$out/$name.build.log" >&2; exit 1; }
    "$out/$name" | "$out/oracle" "$name" > "$out/$name.out" || { echo "static libm: $name differs from MPFR" >&2; cat "$out/$name.out" >&2; status=1; continue; }
    echo "static libm: $name $(tail -1 "$out/$name.out")"
done
exit $status
