#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/named-borrow-result-test
mkdir -p "$out"
"$compiler" build tests/cases/named-borrow-result/main.ab -o "$out/main" --fast --no-cache
"$out/main"
for case in conflict generic-conflict evaluation-conflict method-conflict; do
    if "$compiler" build "tests/cases/named-borrow-result/$case.ab" -o "$out/$case" --fast --no-cache >"$out/$case.log" 2>&1; then
        echo "$case unexpectedly compiled" >&2; exit 1
    fi
    grep -Eq 'E_BORROW_CONFLICT|ownership.borrow-exclusive' "$out/$case.log" || { cat "$out/$case.log" >&2; exit 1; }
done
echo 'named borrowed results retain the caller argument as their source'
