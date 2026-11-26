#!/usr/bin/env bash
# f64Parse at the edge of its 800-digit window (#1139 area 4, round 4, tests/cases/f64-boundary): for midpoints between neighbouring doubles written with the
# deciding digit at significant digit 767 to 810, as a tie, just above and just below, in plain and scientific form, the bits f64Parse answers equal
# those of an independent exact computation (tools/fuzz/f64-boundary.mjs, itself checked against JavaScript's Number). `tools/test-f64-boundary.sh COMPILER [SEED [DOUBLES]]`.
set -euo pipefail
compiler=${1:-build/ablac}
seed=${2:-1}
count=${3:-60}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
command -v node > /dev/null || { echo 'f64 boundary: no node' >&2; exit 1; }
out=build/f64-boundary
rm -rf "$out"
mkdir -p "$out"
node tools/fuzz/f64-boundary.mjs self "$seed" "$count" > "$out/self.txt" || { cat "$out/self.txt" >&2; echo 'f64 boundary: the oracle disagrees with Number' >&2; exit 1; }
node tools/fuzz/f64-boundary.mjs bits "$seed" "$count" > "$out/cases.tsv"
cut -f1 "$out/cases.tsv" > "$out/texts.txt"
node -e 'for (const line of require("fs").readFileSync(process.argv[1], "utf8").split("\n")) if (line) console.log(BigInt.asIntN(64, BigInt(line.split("\t")[1])).toString())' "$out/cases.tsv" > "$out/expected.txt"
"$compiler" build tests/cases/f64-boundary/main.ab -o "$out/abla" --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; echo 'f64 boundary: did not build' >&2; exit 1; }
timeout 600 "$out/abla" < "$out/texts.txt" > "$out/got.txt"
total=$(wc -l < "$out/expected.txt")
paste -d'\t' "$out/texts.txt" "$out/expected.txt" "$out/got.txt" | awk -F'\t' '$2 != $3 { print substr($1, 1, 70) "... want " $2 " got " $3 }' > "$out/differences.txt"
if [[ -s $out/differences.txt ]]; then
    head -8 "$out/differences.txt" >&2
    echo "f64 boundary: $total cases, $(wc -l < "$out/differences.txt") differ from the exactly rounded value" >&2
    exit 1
fi
echo "f64 boundary: $total cases (seed $seed, $count doubles, deciding digit 767 to 810), all exactly rounded; $(cat "$out/self.txt")"
