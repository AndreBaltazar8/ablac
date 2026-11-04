#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/crypto-encrypted-rsa
mkdir -p "$out"
compile() { (ulimit -s 131072; "$compiler" build "$@"); }
python3 tests/cases/crypto-encrypted-rsa/prepare.py "$out"
for mode in "" --fast; do
    compile "$out/primitives.ab" -o "$out/primitives" --no-cache $mode
    "$out/primitives"
done
ABLA_GC_STRESS=1 "$out/primitives"
compile tests/cases/crypto-encrypted-rsa/tool.ab -o "$out/tool" --no-cache
python3 tests/cases/crypto-encrypted-rsa/check.py "$root/$out/tool" "$out"
compile "$out/wasm-build.ab" -o "$out/wasm-builder" --fast --no-cache
"$out/wasm-builder"
node --input-type=module - "$out/primitives.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const {instance}=await WebAssembly.instantiate(readFileSync(process.argv[2]),{});
const value=instance.exports.check();
if(value!==0&&value!==0n) throw new Error(`PBE Wasm ${value}`);
JS
compile "$out/arm-build.ab" -o "$out/arm-builder" --fast --no-cache
"$out/arm-builder"
llvm-mc -triple aarch64-linux-gnu -filetype=obj tests/cases/simd/aarch64-start.s -o "$out/start.o"
ld.lld -static --no-pie -z notext "$out/primitives-arm.o" "$out/start.o" -o "$out/arm"
qemu-aarch64 -cpu max "$out/arm"
if compile tests/cases/crypto-encrypted-rsa/private-password.ab --fast --no-cache -o "$out/private" > "$out/private.log" 2>&1; then
    echo 'CryptoPassword private storage unexpectedly accessible' >&2
    exit 1
fi
grep -Eq 'name.private|E_NAME_PRIVATE' "$out/private.log"
echo 'encrypted RSA: native fast/release, GC stress, AArch64 and Wasm KATs passed'
