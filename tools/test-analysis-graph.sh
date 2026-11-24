#!/usr/bin/env bash
set -euo pipefail
# The editor service answers a request that outruns ABLA_ANALYSIS_BUDGET_MS (60 s by default) with an incomplete result. These analyse the compiler's own source and run
# beside other tests, so they give it the longest budget: a loaded run would otherwise compare an incomplete answer with a complete one (#1206).
export ABLA_ANALYSIS_BUDGET_MS=${ABLA_ANALYSIS_BUDGET_MS:-600000}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
cd "$root"
ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit node tests/analysis-graph/session.mjs "$compiler"
