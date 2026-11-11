#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
out=build/open-nofollow
rm -rf "$out"
mkdir -p "$out/dir"
printf 'hello' > "$out/file"
ln -s file "$out/file-link"
ln -s dir "$out/dir-link"
"$compiler" build tests/cases/open-nofollow/main.ab -o "$out/check" --fast --no-cache
ABLA_NOFOLLOW_ROOT="$out" "$out/check"
echo 'open-nofollow: file and directory symlinks refused'
