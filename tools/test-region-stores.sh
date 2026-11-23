#!/usr/bin/env bash
# #1139 area 7: a region frees what it allocated when it ends, so no store into something that outlives it may take a
# region-built value. One program per kind of store (tests/cases/region-stores): the `// error: CODE` ones must be
# refused with that diagnostic, the `// ok` ones (locals of the region, scalars into outer containers) must build.
# Before the checks, Map.set, a TVar's setValue and an extension function that keeps its argument in its receiver (a
# ByteBuffer's appendChunk is one) were accepted, and the region's reset freed what the outer map or buffer still named.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/region-stores"
out="$project_root/build/region-stores"
mkdir -p "$out"
fail() { echo "region stores: $*" >&2; exit 1; }

checked=0
for source in "$cases"/*.ab; do
    name=$(basename "$source" .ab)
    expectation=$(sed -n '1s|^// ||p' "$source")
    if "$compiler" build "$source" -o "$out/$name" > "$out/$name.log" 2>&1; then
        [[ $expectation == ok ]] || fail "$name was accepted (expected $expectation)"
    else
        [[ $expectation == error:* ]] || fail "$name was refused: $(grep -m1 'error\[' "$out/$name.log")"
        code=${expectation#error: }
        grep -q -- "$code" "$out/$name.log" || fail "$name: expected $code, got $(grep -m1 'error\[' "$out/$name.log")"
    fi
    checked=$((checked + 1))
done
echo "region stores: $checked kinds of store checked (refused with their reason, or built)"
