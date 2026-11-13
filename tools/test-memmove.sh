#!/usr/bin/env bash
# #809: ablaUnsafeCopyMemory is llvm.memmove, so a copy of overlapping ranges, forward or backward, whatever its size,
# leaves what a copy through a buffer leaves (tests/cases/memmove/main.ab: small constant sizes that LLVM expands
# inline, variable sizes up to two blocks, every overlap). Run on x86-64 (release and --fast), on AArch64 Linux under
# qemu-aarch64 and on Wasm (wasm32, bulk memory) under node. With llvm.memcpy the same program fails: a constant-size
# copy is expanded inline as if the ranges were apart.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/memmove
rm -rf "$out"
mkdir -p "$out"
source=tests/cases/memmove/main.ab
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    if [[ $(uname -m) == x86_64 && $(uname -s) == Linux ]]; then
        "$compiler" build "$source" -o "$out/native-$mode" "${flags[@]}"
        result=$("$root/tools/run-limited.sh" "$out/native-$mode") || { echo "memmove x86-64 ($mode): $result" >&2; exit 1; }
        [[ $result == 'memmove ok' ]] || { echo "memmove x86-64 ($mode): $result" >&2; exit 1; }
    fi
    if command -v qemu-aarch64 > /dev/null; then
        "$compiler" build "$source" --target aarch64-linux -o "$out/arm-$mode" "${flags[@]}"
        result=$("$root/tools/run-limited.sh" qemu-aarch64 "$out/arm-$mode") || { echo "memmove AArch64 ($mode): $result" >&2; exit 1; }
        [[ $result == 'memmove ok' ]] || { echo "memmove AArch64 ($mode): $result" >&2; exit 1; }
    fi
done
if command -v node > /dev/null; then
    cat > "$out/build.ab" <<BUILD
import "abla/wasm/build"
val built = #wasmBuildModule("memmove", "$source", "$out/memmove.wasm", true, false)
fun main: int = if (built) 0 else 1
BUILD
    "$compiler" build "$out/build.ab" -o "$out/driver" --fast --no-cache
    "$out/driver"
    node --input-type=module - "$out/memmove.wasm" <<'NODE'
import fs from 'node:fs';
const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), { abla_host: { write: () => 0 } });
const failed = instance.exports.checks();
if (failed !== 0n && failed !== 0) { console.error(`memmove on Wasm: ${failed} failures`); process.exit(1); }
NODE
fi
echo 'memmove ok'
