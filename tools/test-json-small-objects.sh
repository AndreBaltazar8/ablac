#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/json-small-objects"
source="$root/tests/cases/json-small-objects/main.ab"
mkdir -p "$out"
cd "$root"

for mode in release fast; do
    flags=()
    [[ $mode == release ]] || flags+=(--fast)
    bin="$out/$mode"
    "$compiler" build "$source" --no-cache -o "$bin" "${flags[@]}"
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$bin" || status=$?
        [[ $status == 42 ]] || { echo "json small objects: $mode stress=$stress exited $status" >&2; exit 1; }
    done
done

object='{"a":0,"b":1,"c":2,"d":3}'
document="[$object"
for (( i=1; i<128; i++ )); do document+=",$object"; done
document+=']'
status=0
backings=$(ABLA_GC_STRESS=0 "$out/release" count "$document") || status=$?
[[ $status == 42 ]] || { echo "json small objects: allocation census exited $status" >&2; exit 1; }
# The outer, growing array has one separate backing. The small member arrays
# should use combined header and item storage.
[[ $backings =~ ^[0-9]+$ ]] && ((backings <= 2)) || {
    echo "json small objects: expected at most 2 separate array backings, found $backings" >&2
    exit 1
}
echo "json small objects: byte order, diagnostics, mutable arrays and combined allocation"
