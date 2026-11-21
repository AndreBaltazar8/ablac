#!/usr/bin/env bash
# Manual opt-in benchmark. Call inside the build slot/toolchain shell.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/json-stream
git rev-parse HEAD
"$compiler" --version
echo 'release --no-cache; 1 warm pair + 9 alternating pairs; 1024 documents/sample'
echo 'run under taskset on one idle CPU for timing; input setup excluded'
"$compiler" build tests/benchmarks/json-stream/main.ab -o build/json-stream/bench --no-cache
build/json-stream/bench | tee build/json-stream/bench.log
awk '
/^samples$/ { samples=1; next }
samples && $2 == "manual" { manual[$1] += $3; n[$1]++ }
samples && $2 == "jsonw" { written[$1] += $3 }
END { for (kind in manual) printf "%s: %d pairs, manual/jsonw %.4fx (summed CPU-pinned wall times)\n", kind, n[kind], manual[kind]/written[kind] }
' build/json-stream/bench.log
