#!/usr/bin/env bash
# The four hex digits of a JSON \uXXXX escape: every byte value at every digit position decodes
# or is refused exactly as the digit rules say (tests/cases/json-hex-quad), fast and release,
# with and without GC stress.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/json-hex-quad"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/json-hex-quad/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" || status=$?
        [[ $status -eq 42 ]] || { echo "json hex quad: status $status (mode '$mode', stress $stress)" >&2; exit 1; }
    done
done
echo 'JSON hex quad: every byte at every digit position decodes or is refused as the digit rules say'
