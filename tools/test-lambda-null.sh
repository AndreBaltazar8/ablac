#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/lambda-null"
mkdir -p "$out"
for case in main result-types compile-time generic; do
    "$compiler" build "tests/cases/lambda-null/$case.ab" -o "$out/$case" --fast --no-cache
    "$out/$case"
done
if "$compiler" build tests/cases/lambda-null/invalid.ab -o "$out/invalid" --fast --no-cache > "$out/invalid.log" 2>&1; then
    echo 'lambda with a non-nullable, incompatible result compiled' >&2; exit 1
fi
grep -Fq 'function.argument:w' "$out/invalid.log" || { cat "$out/invalid.log" >&2; exit 1; }
echo 'unconditional-null lambdas take their expected nullable result type'
