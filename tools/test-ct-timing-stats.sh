#!/usr/bin/env bash
# The timing experiment's statistics, sampler reader, source binding and host check (tools/ct-timing/test-stats.ab).
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/ct-timing-stats
mkdir -p "$out"
"$compiler" build tools/ct-timing/test-stats.ab -o "$out/test-stats" --fast --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; exit 1; }
"$out/test-stats"
