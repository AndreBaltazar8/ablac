#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/array-remove-last-test
mkdir -p "$out"
"$compiler" build tests/cases/array-remove-last/main.ab -o "$out/main" --fast --no-cache
"$out/main"
"$compiler" build tests/cases/array-remove-last/empty.ab -o "$out/empty" --fast --no-cache
status=0
"$out/empty" > "$out/empty.log" 2>&1 || status=$?
[[ $status == 101 ]] && grep -Fq 'out of bounds' "$out/empty.log" || { cat "$out/empty.log" >&2; exit 1; }
if "$compiler" build tests/cases/array-remove-last/resource.ab -o "$out/resource" --fast --no-cache > "$out/resource.log" 2>&1; then
    echo 'removeLast unexpectedly accepted a resource element' >&2; exit 1
fi
grep -Fq 'ownership.affine-drop:truncate' "$out/resource.log" || { cat "$out/resource.log" >&2; exit 1; }
echo 'array.removeLast: non-affine values, empty panic and resource rejection'
