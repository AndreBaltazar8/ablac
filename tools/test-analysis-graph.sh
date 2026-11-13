#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
cd "$root"
ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit node tests/analysis-graph/session.mjs "$compiler"
