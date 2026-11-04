#!/usr/bin/env bash
# Fixed-width secret arithmetic against Python's arbitrary-precision integer oracle.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
out=build/bignum-secret-tests
mkdir -p "$out"
for mode in --fast ''; do
    label=${mode:---release}
    "$compiler" build tests/cases/crypto-bignum-secret/run.ab -o "$out/oracle" --no-cache $mode
    python3 -I tests/cases/crypto-bignum-secret/oracle.py "$PWD/$out/oracle" "$PWD/$out"
    echo "ok   bignum secret $label"
done
