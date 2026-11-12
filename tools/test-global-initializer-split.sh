#!/usr/bin/env bash
# A program whose literal tables make a module initializer larger than engines compile
# (built unsplit, its largest function is about 8 MB): its globals are
# initialized by pieces the initializer calls in order (BOOTSTRAP_IR_GLOBALS_CHUNK), a
# large table's items by functions of their own (BOOTSTRAP_IR_OUTLINED_TABLE). Built
# for WebAssembly (--fast, as a development client is) every function body stays far
# under what engines compile (V8: 7,654,321 bytes), the module instantiates, and its
# checksum over every field is the native build's.
set -euo pipefail
# Only the Wasm checks below read LLVM text. The native development build
# keeps its module in process instead of rendering and reparsing it.

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/global-initializer-split"
mkdir -p "$output_directory"
fail() {
    echo "global initializer split: $1" >&2
    exit 1
}
awk -f "$project_root/tests/cases/global-initializer-split/generate.awk" > "$output_directory/body.ab"
{
    cat "$output_directory/body.ab"
    printf '\n@export("checksum")\nfun exportedChecksum(): int = checksum()\n'
} > "$output_directory/tables.ab"
{
    printf 'import "abla/io"\n'
    cat "$output_directory/body.ab"
    printf '\nfun main: int {\n    println("${checksum()}")\n    0\n}\n'
} > "$output_directory/native.ab"
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
(cd "$project_root" && ABLA_KEEP_LLVM_TEXT=1 "$compiler" build "$output_directory/build.ab" \
    -o "$output_directory/build-driver" --no-cache)
"$output_directory/build-driver" || fail "the module did not build"

# The initializer was cut into pieces, and the table's items computed by functions.
grep -q '"abla.source"="__bootstrap_globals_0"' "$output_directory/tables.wasm.ll" ||
    fail "the module initializer was not cut into pieces"
grep -q '"abla.source"="__bootstrap_globals_element_' "$output_directory/tables.wasm.ll" ||
    fail "the table's items were not computed by functions of their own"
# The largest function body in the module's code section.
# The reader is checked first on a module built by hand: bodies of 2, 300 and 1 bytes
# in a code section followed by another section.
reader="$project_root/tests/cases/global-initializer-split/largest-function.awk"
sample=$(awk 'BEGIN {
    printf "0 97 115 109 1 0 0 0  1 2 0 0  10 180 2 3  2 0 0  172 2"
    for (i = 0; i < 300; i++) printf " 0"
    print "  1 0  0 3 0 0 0"
}' | awk -f "$reader")
[[ $sample == 300 ]] || fail "the section reader found $sample for a module whose largest body is 300"
largest=$(od -An -v -tu1 -w32 "$output_directory/tables.wasm" | awk -f "$reader")
(( largest < 2000000 )) || fail "a function body of $largest bytes"
wasm=$(node -e '
const bytes = require("fs").readFileSync(process.argv[1]);
WebAssembly.instantiate(bytes, {}).then(({ instance }) =>
    console.log(String(instance.exports.checksum())));
' "$output_directory/tables.wasm")
[[ $wasm == "$native" ]] || fail "WebAssembly checksum $wasm, native $native"
echo "global initializer split: largest WebAssembly function $largest bytes; checksum $native in both"
