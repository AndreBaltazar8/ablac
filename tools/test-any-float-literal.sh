#!/usr/bin/env bash
set -euo pipefail
# A float compared with an `any` through ==, != and `when` compares erased values, kind included
# (0 != 0.0, "0" != 0.0, no trap): native fast and release, the compile-time evaluator (the
# program checks itself under `#`), and a hostless Wasm module.
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/any-float-literal"
fixture=tests/cases/any-float-literal/main.ab
rm -rf "$out"
mkdir -p "$out"
cd "$project_root"

"$compiler" build "$fixture" -o "$out/release" --no-cache
"$out/release"
"$compiler" build "$fixture" -o "$out/fast" --fast --no-cache
"$out/fast"

cat > "$out/build-wasm.ab" <<WASM
import "abla/wasm/build"
val built = #wasmBuildModule("any-float-literal", "$fixture", "build/any-float-literal/main.wasm", false, false)
fun main: int = if (built) 0 else 1
WASM
"$compiler" build "$out/build-wasm.ab" -o "$out/build-wasm" --fast --no-cache
"$out/build-wasm"
node -e '
const bytes = require("fs").readFileSync(process.argv[1]);
const abla_host = {
    write: (fd, data, length) => length,
    exit: (code) => { throw new Error("exit " + code); },
    clock_ns: () => 0n,
    random: (data, length) => length,
};
const { exports } = new WebAssembly.Instance(new WebAssembly.Module(bytes), { abla_host });
const status = Number(exports.main());
if (status !== 0) { console.error("Wasm module exited " + status); process.exit(1); }
' "$out/main.wasm"
echo "any compared with a float literal keeps the kind in native, compile-time and Wasm code"
