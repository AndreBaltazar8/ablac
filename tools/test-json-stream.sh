#!/usr/bin/env bash
# Shared grammar and byte parity through the tree and streaming lowerings.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/json-stream
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/modules/json-stream.ab -o "$out/test.$mode" "${flags[@]}"
    "$out/test.$mode"
done
# These errors must come from the shared JSON parser or ordinary typing.
rejected() {
    local name=$1 pattern=$2 value=$3
    printf 'import "abla/bytes"\nimport "abla/json"\nfun main { val out = byteBuffer(); $jsonw(out) %s }\n' "$value" > "$out/$name.ab"
    if "$compiler" build "$out/$name.ab" -o "$out/$name" --no-cache > "$out/$name.log" 2>&1; then
        echo "json-stream: accepted $name" >&2
        exit 1
    fi
    if ! grep -q "$pattern" "$out/$name.log" || grep -q 'E_LLVM\|E_IR_EMISSION' "$out/$name.log"; then
        cat "$out/$name.log" >&2
        exit 1
    fi
}
rejected duplicate 'duplicate key' '{"a":1,"a":2}'
rejected missing-colon 'expected `:`' '{"a" 1}'
rejected wrong-key 'ablaJsonKey' '{42:1}'
rejected wrong-value 'ablaJsonWriteValue' 'byteBuffer()'
echo 'ok   json-stream shared grammar, typed diagnostics, runtime/staged byte parity'
