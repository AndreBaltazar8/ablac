#!/usr/bin/env bash
# SHA-384 and SHA-512 (abla/crypto) at every size from 0 to 520 bytes (the padding boundaries) and larger ones against Node's crypto (tests/cases/sha512-boundaries); release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/sha512-boundaries
rm -rf "$out"
mkdir -p "$out"
command -v node > /dev/null || { echo "sha512-boundaries: needs node (the oracle)" >&2; exit 1; }
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/sha512-boundaries/main.ab -o "$out/test-$mode" "${flags[@]}" > "$out/build-$mode.log" 2>&1 || { cat "$out/build-$mode.log" >&2; exit 1; }
    "$root/tools/run-limited.sh" "$out/test-$mode" > "$out/digests-$mode.txt" || { echo "sha512-boundaries ($mode): the program failed" >&2; exit 1; }
    result=$(node tests/cases/sha512-boundaries/check.mjs "$out/digests-$mode.txt") || { echo "sha512-boundaries ($mode): $result" >&2; exit 1; }
    echo "ok   $mode: $result"
done
echo "sha512-boundaries ok"
