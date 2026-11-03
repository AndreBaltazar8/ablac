#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/parse-int-test
"$compiler" build tests/cases/parse-int/main.ab -o build/parse-int-test/main --fast --no-cache
build/parse-int-test/main
echo 'parseInt: strict decimal grammar and signed overflow, native and compile time'
