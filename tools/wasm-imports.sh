#!/usr/bin/env bash
# Builds each given .ab source to a Wasm module, fast and release, and prints
# the module's imports and size: `<name> <mode> <bytes> <module.name,...>`.
# Usage: wasm-imports.sh <compiler> <out dir> <source.ab>...
set -euo pipefail
compiler=$1
out=$2
shift 2
mkdir -p "$out"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# A build call reads its paths against the build file (decision #91 A): give it absolute ones.
absolute() { case $1 in /*) echo "$1" ;; *) echo "$root/$1" ;; esac; }
for source in "$@"; do
    name=$(basename "$(dirname "$source")")-$(basename "$source" .ab)
    for mode in fast release; do
        fast=false
        [[ $mode == fast ]] && fast=true
        driver="$out/$name-$mode.build.ab"
        cat >"$driver" <<DRIVER
import "abla/wasm/build"
val built = #wasmBuildModule("$name", "$(absolute "$source")", "$(absolute "$out")/$name-$mode.wasm", $fast, false)
fun main: int = if (built) 0 else 1
DRIVER
        "$compiler" build "$driver" -o "$out/$name-$mode.driver" --fast >/dev/null
        "$out/$name-$mode.driver" >/dev/null
        node -e '
const m = new WebAssembly.Module(require("fs").readFileSync(process.argv[1]));
console.log(process.argv[2], process.argv[3], require("fs").statSync(process.argv[1]).size,
    WebAssembly.Module.imports(m).map(i => i.module + "." + i.name).sort().join(",") || "-");
' "$out/$name-$mode.wasm" "$name" "$mode"
    done
done
