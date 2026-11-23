#!/usr/bin/env bash
# The parser harnesses of #1139 area 4 (tools/fuzz/parsers): each runs a short campaign and must report no finding, crash or hang.
# The long campaigns (100k inputs per parser) are run by hand with tools/fuzz/parsers/run <name> --seeds A-B --inputs N.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# name seeds inputs: h2 builds a connection per input, so it gets fewer.
for entry in "http1 1-20 100" "h2 1-10 50" "websocket 1-20 100" "yaml 1-10 50" "json 1-10 100"; do
    read -r parser seeds inputs <<< "$entry"
    tools/fuzz/parsers/run "$parser" --compiler "$compiler" --seeds "$seeds" --inputs "$inputs" || { echo "fuzz-parsers: $parser reported a finding" >&2; exit 1; }
done
echo "fuzz-parsers: http1 (20 seeds x 100 inputs), h2 (10 x 50) and websocket (20 x 100), yaml (10 x 50) and json (10 x 100), no finding"
