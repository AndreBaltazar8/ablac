#!/usr/bin/env bash
# A short seeded run of the differential fuzzer (tools/fuzz-differential): random
# well-typed programs must print the same and exit the same under native --fast,
# native release, the compile-time evaluator (interpreter and native code) and
# hostless WebAssembly (release and development modules). The seeds are fixed, so
# a failure reproduces; the self-test checks that a difference is reported.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
python3 tools/fuzz-differential --selftest
python3 tools/fuzz-differential --compiler "$compiler" --seeds 1-2 --checks 16
