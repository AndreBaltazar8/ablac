#!/usr/bin/env bash
# abla/crypto/x509 and abla/crypto/p384: the committed chains (good, expired, wrong name, wrong usage, missing intermediate,
# name constraints, path length, self-signed, tampered: tools/gen-x509-fixtures.sh), host name rules, damaged
# certificates, the system CA bundle, P-384 against Wycheproof's ECDSA vectors, and the x509-limbo and BetterTLS cases of
# tests/cases/x509/limbo (tools/gen-x509-limbo.sh), whose differences from their expectations are all listed with a reason.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/x509
rm -rf "$out"
mkdir -p "$out"
cd "$root"
pids=()
for program in main limbo; do
    "$compiler" build "tests/cases/x509/$program.ab" -o "$out/$program" --fast --no-cache > "$out/$program.build.log" 2>&1 &
    pids+=("$!")
done
"$compiler" build tests/cases/p384/main.ab -o "$out/p384" --fast --no-cache > "$out/p384.build.log" 2>&1 &
pids+=("$!")
names=(main limbo p384)
for index in "${!names[@]}"; do
    wait "${pids[$index]}" || { cat "$out/${names[$index]}.build.log"; exit 2; }
done
"$out/main" tests/cases/x509/chains
echo "ok   X.509 chains, host names, damaged certificates"
"$out/p384" tests/cases/p384/vectors
echo "ok   P-384 ECDSA against Wycheproof"
for cases in limbo-core limbo-bettertls-nc; do
    "$out/limbo" "tests/cases/x509/limbo/$cases.json" tests/cases/x509/limbo/known.tsv
done
echo "ok   x509-limbo and BetterTLS cases"
