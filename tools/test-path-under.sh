#!/usr/bin/env bash
# The helper behind every "is this path under the project root" test of the compiler (src/module_paths.ab, bootstrapPathUnder): the file system
# root, a directory, a Windows drive and share root, and the near misses ("/workshop" is not under "/work").
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/path-under"
rm -rf "$out"
mkdir -p "$out"
(cd "$root" && "$compiler" build tests/cases/path-under/main.ab -o "$out/path-under" --no-cache)
[[ $("$out/path-under") == "path under: ok" ]] || { "$out/path-under" >&2 || true; echo "path under: failed" >&2; exit 1; }
echo "path under: the file system root, directories, Windows drive and share roots, and near misses"
