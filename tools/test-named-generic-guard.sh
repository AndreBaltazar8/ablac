#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/named-generic-guard-test
mkdir -p "$out"
for case in invalid collision; do
    if "$compiler" build "tests/cases/named-generic-guard/$case.ab" -o "$out/$case" --fast --no-cache >"$out/$case.log" 2>&1; then
        echo "unbound generic default $case unexpectedly compiled" >&2; exit 1
    fi
    grep -Fq 'generic.cannot-infer:f:T' "$out/$case.log" || { cat "$out/$case.log" >&2; exit 1; }
done
"$compiler" build tests/cases/named-generic-guard/valid.ab -o "$out/valid" --fast --no-cache
status=0
"$out/valid" || status=$?
[[ $status == 42 ]]
echo 'unbound default type cannot fabricate a generic instance'
