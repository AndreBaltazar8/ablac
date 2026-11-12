#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/inferred-affine-return
mkdir -p "$out"
"$compiler" build tests/cases/inferred-affine-return/main.ab -o "$out/main" --fast --no-cache
"$out/main"
for case in function method lambda return; do
    if "$compiler" build "tests/cases/inferred-affine-return/$case.ab" -o "$out/$case" --fast --no-cache >"$out/$case.log" 2>&1; then
        echo "$case unexpectedly compiled" >&2; exit 1
    fi
    grep -q 'ownership.borrow-escape:' "$out/$case.log" || { cat "$out/$case.log" >&2; exit 1; }
done
echo 'inferred affine returns reject borrowed parameters'
