#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/path-syntax-test
mkdir -p "$out"
"$compiler" build tests/cases/path-syntax/main.ab -o "$out/main" --fast --no-cache
"$out/main"
echo 'path-syntax: POSIX and Windows lexical path syntax (root, parent, name, extension, join, normalize, components, canonical form)'
