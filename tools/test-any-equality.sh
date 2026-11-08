#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
cd "$root"
out="$root/build/any-equality"
mkdir -p "$out"
for case in functions; do
    "$compiler" build "$root/tests/cases/any-equality/$case.ab" -o "$out/$case-fast" --fast --no-cache
    "$out/$case-fast"
    "$compiler" build "$root/tests/cases/any-equality/$case.ab" -o "$out/$case-release" --no-cache
    "$out/$case-release"
done
echo 'equality through any compares what each kind of value is'
