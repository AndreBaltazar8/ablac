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
# The cases the fuzzer found stay as programs: every mode must print the same, and
# a compile-time answer that differs from the run-time one prints MISMATCH.
for program in tests/cases/fuzz-differential/*.ab; do
    python3 tools/fuzz-differential --compiler "$compiler" --program "$program"
    if python3 tools/fuzz-differential --compiler "$compiler" --program "$program" --show | grep -q MISMATCH; then
        echo "fuzz differential: $program: compile time disagrees with run time" >&2
        exit 1
    fi
done
echo "fuzz differential: seeded programs and the recorded cases agree in every mode"
