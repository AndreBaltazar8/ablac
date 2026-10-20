#!/usr/bin/env bash
# Cross-check the native JSON/UTF-8 paths on Wasm, including portable-reference
# diagnostics and control/scalar boundaries from the ordinary module tests.
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory="$project_root/build/json-native-paths"
mkdir -p "$output_directory"
cd "$project_root"
for name in json-subparser text-unicode; do
    cp "tests/cases/modules/$name.ab" "$output_directory/$name.ab"
    cat >> "$output_directory/$name.ab" <<'AB'

@export("check")
fun wasmCheck(): int = main()
AB
    cat > "$output_directory/build-$name.ab" <<AB
import "abla/wasm/build"
val built = #wasmBuildModule(
    "$name", "build/json-native-paths/$name.ab",
    "build/json-native-paths/$name.wasm", false, false
)
fun main: int = if (built) 0 else 1
AB
    "$compiler" build "$output_directory/build-$name.ab" --no-cache \
        -o "$output_directory/build-$name"
    node --input-type=module - "$output_directory/$name.wasm" <<'JS'
import { readFileSync } from "node:fs";
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const actual = instance.exports.check();
if (actual !== 42n && actual !== 42) throw new Error(`check returned ${actual}`);
console.log(`PASS Wasm ${process.argv[2]}`);
JS
done
