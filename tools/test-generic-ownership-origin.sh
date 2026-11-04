#!/usr/bin/env bash
# Put a deliberately invalid generic in an isolated stdlib copy: regression
# coverage for diagnostics must not require shipping a broken public helper.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
python3 "$root/tools/test-generic-ownership-origin.py" "$compiler" "$root"
