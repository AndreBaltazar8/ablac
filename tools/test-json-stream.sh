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
# The provider and buffer can both arrive through aliases. Resolved method
# targets must retain the original receiver's identity in runtime and staging.
cat > "$out/aliases.ab" <<'ABLA'
import "abla/bytes" as buffers
import "abla/json" as jsonProvider

fun aliased(selected: bool): string {
    val out = buffers.byteBuffer()
    $jsonw(out) {"text": "quote\"", if (selected) "number": 42,}
    out.toText()
}
val staged = #aliased(true)
fun main: int {
    val expected = "{\"text\":\"quote\\\"\",\"number\":42}"
    if (aliased(true) != expected || staged != expected) return 1
    if (aliased(false) != "{\"text\":\"quote\\\"\"}") return 1
    if (jsonProvider.jsonStringify(jsonProvider.jsonInteger(42)) != "42") return 1
    0
}
ABLA
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build "$out/aliases.ab" -o "$out/aliases.$mode" "${flags[@]}"
    "$out/aliases.$mode"
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
rejected guard-type 'bool' '{if (1) "key": 1}'
rejected guard-null 'bool' '{if (null) "key": 1}'
rejected guard-comma 'expected a \$json object member' '{if (false) "key": 1,,}'
rejected guarded-duplicate 'duplicate key' '{if (true) "key": 1, if (false) "key": 2}'
# A computed key that repeats another key (decision #154): one member per key, at the first position, with the later value, in the tree and
# streaming forms alike, and jsonParse accepts the output (tests/cases/modules/json-merge.ab).
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/modules/json-merge.ab -o "$out/merge.$mode" "${flags[@]}"
    result=$("$out/merge.$mode") || { echo "json-merge ($mode): $result" >&2; exit 1; }
    [[ $result == 'json merge ok' ]] || { echo "json-merge ($mode): $result" >&2; exit 1; }
done
echo 'ok   json-stream shared grammar, typed diagnostics, runtime/staged byte parity, repeated computed keys merged'
