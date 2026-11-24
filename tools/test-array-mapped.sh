#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/array-mapped
mkdir -p "$out"
cases=tests/cases/array-mapped

"$compiler" build "$cases/main.ab" --fast --strict-imports --no-cache -o "$out/test"
"$out/test" > "$out/actual"
printf '4 10 6 3\n3 2 5 3 0\na! bc! a 9\n' > "$out/expected"
cmp "$out/expected" "$out/actual"

for fixture in resource-input resource-output; do
    if "$compiler" build "$cases/$fixture.ab" --fast --strict-imports --no-cache \
        -o "$out/$fixture" > "$out/$fixture.log" 2>&1; then
        echo "array.mapped accepted $fixture" >&2
        exit 1
    fi
    grep -F 'error[E_CT_PANIC]: array.mapped requires copyable input and output elements' \
        "$out/$fixture.log" >/dev/null
done

echo 'array.mapped preserves order, infers result types and rejects resource elements'
