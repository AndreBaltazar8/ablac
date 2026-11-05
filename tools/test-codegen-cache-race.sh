#!/usr/bin/env bash
# Includes a real concurrent sweeper and the 4x8 zero-limit reproducer.
set -euo pipefail
compiler=${1:-build/ablac.bin}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 "$root/tools/test-codegen-cache-race.py" "$compiler"
