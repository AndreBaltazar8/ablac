#!/usr/bin/env bash
# Fluent borrowed results must not repeatedly infer the same receiver tree.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
output="$root/build/borrow-chain-scaling-test"
mkdir -p "$output"

build_chain() {
    local links=$1 i status=0
    {
        printf 'class Item(val n: int) { fun step(): borrow(this) Item = this }\n'
        printf 'fun main: int = Item(42)'
        for ((i=0; i<links; i++)); do printf '.step()'; done
        printf '.n\n'
    } > "$output/$links.ab"
    "${ABLA_TIME:-$(type -P time)}" -p timeout 30 "$compiler" build "$output/$links.ab" \
        -o "$output/$links" --fast --no-cache >"$output/$links.out" 2>"$output/$links.err" || status=$?
    if [[ $status -ne 0 ]]; then cat "$output/$links.err" >&2; return "$status"; fi
    status=0
    "$output/$links" || status=$?
    [[ $status -eq 42 ]]
    awk '/^(user|sys) / { total += $2 } END { printf "%d\n", total * 100 }' "$output/$links.err"
}

small=$(build_chain 20)
large=$(build_chain 40)
# Allow fixed startup and timer granularity; exponential work fails by timeout.
if ((large > 3 * small + 50)); then
    echo "borrow chain scaling: 20 calls ${small}cs, 40 calls ${large}cs" >&2
    exit 1
fi
echo "borrow chain scaling: 20 calls ${small}cs, 40 calls ${large}cs"
program=$("$root/tools/compiler-api-test-program.sh" "$compiler")
status=0
ABLA_COMPILER_API_CASE=borrow-refinement "$program" || status=$?
[[ $status -eq 42 ]]
echo 'type cache respects narrowing and restored scope for the same expression'
