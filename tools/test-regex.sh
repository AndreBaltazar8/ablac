#!/usr/bin/env bash
# abla/regex: unit and pathological-pattern cases in fast and release builds,
# the release build again under GC stress, and a short differential run
# against Python's re (tools/fuzz-regex).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/regex"
mkdir -p "$out"
cd "$root"
for mode in --fast release; do
    options=()
    [[ $mode == release ]] || options+=(--fast)
    "$compiler" build "$root/tests/cases/regex/main.ab" -o "$out/main-$mode" --no-cache "${options[@]}"
    # The pathological patterns must finish quickly: that is linear time.
    timeout 60 "$out/main-$mode" | grep -qx ok
done
ABLA_GC_STRESS=1 timeout 300 "$out/main-release" | grep -qx ok
python3 tools/fuzz-regex --compiler "$compiler" --seeds 1 --cases 120
echo "regex: ok"
