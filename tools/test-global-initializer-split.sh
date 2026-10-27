#!/usr/bin/env bash
# A program whose literal tables make a module initializer larger than engines compile
# (built unsplit, its largest function is about 8 MB): its globals are
# initialized by pieces the initializer calls in order (BOOTSTRAP_IR_GLOBALS_CHUNK), a
# large table's items by functions of their own (BOOTSTRAP_IR_OUTLINED_TABLE). Built
# for WebAssembly (--fast, as a development client is) every function body stays far
# under what engines compile (V8: 7,654,321 bytes), the module instantiates, and its
# checksum over every field is the native build's.
set -euo pipefail
# This test reads the module's LLVM text, which a development build keeps only when asked.
export ABLA_KEEP_LLVM_TEXT=1

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/global-initializer-split"
mkdir -p "$output_directory"
fail() {
    echo "global initializer split: $1" >&2
    exit 1
}
python3 "$project_root/tests/cases/global-initializer-split/generate.py" \
    "$output_directory/tables.ab" "$output_directory/native.ab"
"$compiler" build "$output_directory/native.ab" -o "$output_directory/native" \
    --fast --no-cache
native=$("$output_directory/native")
cat > "$output_directory/build.ab" <<DRIVER
import "abla/wasm/build"

val built = #wasmBuildModule(
    "tables",
    "build/global-initializer-split/tables.ab",
    "build/global-initializer-split/tables.wasm",
    true,
    false
)

fun main: int = if (built) 0 else 1
DRIVER
(cd "$project_root" && "$compiler" build "$output_directory/build.ab" \
    -o "$output_directory/build-driver" --no-cache)
"$output_directory/build-driver" || fail "the module did not build"

# The initializer was cut into pieces, and the table's items computed by functions.
grep -q '"abla.source"="__bootstrap_globals_0"' "$output_directory/tables.wasm.ll" ||
    fail "the module initializer was not cut into pieces"
grep -q '"abla.source"="__bootstrap_globals_element_' "$output_directory/tables.wasm.ll" ||
    fail "the table's items were not computed by functions of their own"
# The largest function body in the module's code section.
largest=$(python3 - "$output_directory/tables.wasm" <<'READER'
import sys
data = open(sys.argv[1], "rb").read()
def leb(at):
    result = shift = 0
    while True:
        byte = data[at]
        at += 1
        result |= (byte & 0x7f) << shift
        shift += 7
        if byte < 0x80:
            return result, at
at, largest = 8, 0
while at < len(data):
    section = data[at]
    size, at = leb(at + 1)
    if section == 10:
        count, body = leb(at)
        for _ in range(count):
            length, body = leb(body)
            largest = max(largest, length)
            body += length
    at += size
print(largest)
READER
)
(( largest < 2000000 )) || fail "a function body of $largest bytes"
wasm=$(node -e '
const bytes = require("fs").readFileSync(process.argv[1]);
WebAssembly.instantiate(bytes, {}).then(({ instance }) =>
    console.log(String(instance.exports.checksum())));
' "$output_directory/tables.wasm")
[[ $wasm == "$native" ]] || fail "WebAssembly checksum $wasm, native $native"
echo "global initializer split: largest WebAssembly function $largest bytes; checksum $native in both"
