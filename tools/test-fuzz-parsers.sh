#!/usr/bin/env bash
# The parser harnesses of #1139 area 4 (tools/fuzz/parsers): each runs a short campaign and must report no finding, crash or hang.
# The long campaigns (100k inputs per parser) are run by hand with tools/fuzz/parsers/run <name> --seeds A-B --inputs N.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
for parser in http1; do
    tools/fuzz/parsers/run "$parser" --compiler "$compiler" --seeds 1-20 --inputs 100 || { echo "fuzz-parsers: $parser reported a finding" >&2; exit 1; }
done
echo "fuzz-parsers: http1 20 seeds x 100 inputs, no finding"
