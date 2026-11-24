#!/usr/bin/env bash
# BigModulus and BigNumber (abla/crypto/bignum, the big-number type that takes no address) against JavaScript's BigInt (tests/cases/bignum-checked/vectors.txt, made by
# generate.mjs), the refusals, and the two stops: numbers of two moduli in one operation, and a number forged over too small a buffer. Release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/bignum-checked
rm -rf "${out:?}"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/bignum-checked/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode" tests/cases/bignum-checked) || { echo "bignum-checked ($mode): $result" >&2; exit 1; }
    [[ $result == 'bignum-checked ok' ]] || { echo "bignum-checked ($mode): $result" >&2; exit 1; }
done
stops() { # program text: the program must fail and say the text
    "$compiler" build "tests/cases/bignum-checked/$1.ab" -o "$out/$1" --no-cache --fast
    if "$out/$1" > "$out/$1.out" 2>&1; then echo "bignum-checked: $1 returned" >&2; exit 1; fi
    grep -F "$2" "$out/$1.out" > /dev/null || { echo "bignum-checked: $1 did not say '$2'" >&2; cat "$out/$1.out" >&2; exit 1; }
}
stops mismatch "different moduli"
stops forged "does not fit its width"
echo "ok   BigModulus and BigNumber: BigInt vectors at 4, 8, 32, 64 and 512 bytes, refusals, a mismatched modulus and a forged number stop, release and --fast"
