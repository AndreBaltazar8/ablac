#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/text-blocks"
mkdir -p "$out"
cd "$root"
# CRLF copy: every line ends in LF (checked below), so appending CR before it is exact.
sed $'s/$/\r/' "$root/tests/cases/text-blocks/main.ab" > "$out/crlf.ab"
[[ $(tr -cd '\r' < "$out/crlf.ab" | wc -c) -eq $(tr -cd '\n' < "$root/tests/cases/text-blocks/main.ab" | wc -c) ]] || { echo "text blocks: CRLF copy is not one CR per LF" >&2; exit 1; }
for mode in fast release; do
    options=()
    [[ $mode == release ]] || options+=(--fast)
    for source in "$root/tests/cases/text-blocks/main.ab" "$out/crlf.ab"; do
        "$compiler" build "$source" -o "$out/main" --no-cache ${options[@]+"${options[@]}"}
        status=0
        "$out/main" || status=$?
        [[ $status -eq 42 ]] || { echo "text blocks: $source $mode returned $status" >&2; exit 1; }
    done
done
reject() {
    local name=$1 code=$2 line=$3 column=$4
    if "$compiler" build "tests/cases/text-blocks/$name.ab" -o "$out/invalid" --no-cache --fast > "$out/$name.log" 2>&1; then
        echo "text blocks: $name unexpectedly compiled" >&2; exit 1
    fi
    grep -qF "E_PARSE_$code" "$out/$name.log" || { cat "$out/$name.log" >&2; exit 1; }
    grep -qF "$name.ab:$line:$column" "$out/$name.log" || { cat "$out/$name.log" >&2; exit 1; }
}
reject invalid-open RAW_OPEN_LINE 2 19
reject invalid-indent RAW_INDENT 4 1
reject invalid-import-indent RAW_INDENT 3 1
reject invalid-close RAW_CLOSE_LINE 4 7
reject invalid-close-suffix RAW_CLOSE_LINE 4 13
reject invalid-unclosed RAW_UNTERMINATED 2 16
"$compiler" build "$root/tests/cases/text-blocks/extern.ab" -o "$out/extern" --fast --no-cache
status=0
"$out/extern" || status=$?
[[ $status -eq 42 ]]
for evaluation in interp jit; do
    ABLA_COMPILE_EVAL=$evaluation "$compiler" build "$root/tests/cases/text-blocks/main.ab" -o "$out/staged-$evaluation" --fast --no-cache
    status=0
    "$out/staged-$evaluation" || status=$?
    [[ $status -eq 42 ]]
done
"$compiler" build "$root/tests/cases/text-blocks/build-wasm.ab" -o "$out/wasm-driver" --fast --no-cache
"$out/wasm-driver"
node "$root/tests/cases/text-blocks/run.mjs" "$out/text-blocks.wasm"
echo 'raw text blocks: native, staged, hostless Wasm, CRLF and diagnostics passed'
