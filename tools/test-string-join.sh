#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/string-join-test
"$compiler" build tests/cases/string-join/main.ab -o build/string-join-test/main --fast --no-cache
build/string-join-test/main
echo 'array<string>.join: empty, separators and UTF-8, native and compile time'
