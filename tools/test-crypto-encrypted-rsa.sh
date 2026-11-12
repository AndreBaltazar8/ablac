#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/crypto-encrypted-rsa
mkdir -p "$out"
compile() { (ulimit -s 131072; "$compiler" build "$@"); }
cases=tests/cases/crypto-encrypted-rsa
# The generated sources: the PBE library, its test helpers, the committed known-answer
# checks, and build wrappers filled in from templates.
{ cat stdlib/abla/crypto/pbe/entry.ab; echo; cat $cases/primitive-test.inc; echo; cat $cases/primitive-kats.inc; } > "$out/primitives.ab"
fill() { sed -e "s|@SOURCE@|$2|" -e "s|@OUTPUT@|$3|" "$cases/$1" > "$out/$4"; }
fill build-wasm.ab.in "$out/primitives.ab" "$out/primitives.wasm" wasm-build.ab
fill build-arm.ab.in "$out/primitives.ab" "$out/primitives-arm.o" arm-build.ab
fill build-wasm.ab.in "$out/reader.ab" "$out/reader.wasm" reader-wasm-build.ab
fill build-arm.ab.in "$out/reader.ab" "$out/reader-arm.o" reader-arm-build.ab
cp $cases/abla.toml "$out/abla.toml"
p12hex=$(od -An -v -tx1 tests/vectors/crypto/encrypted-rsa/empty.p12 | tr -d ' \n')
awk -v hex="$p12hex" '{ sub(/@P12HEX@/, hex); print }' $cases/reader.ab.in > "$out/reader.ab"
for mode in "" --fast; do
    compile "$out/primitives.ab" -o "$out/primitives" --no-cache $mode
    "$out/primitives"
done
ABLA_GC_STRESS=1 "$out/primitives"
compile tests/cases/crypto-encrypted-rsa/tool.ab -o "$out/tool" --no-cache
bash $cases/check.sh "$root/$out/tool"
compile "$out/wasm-build.ab" -o "$out/wasm-builder" --fast --no-cache
"$out/wasm-builder"
node --input-type=module - "$out/primitives.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const module=new WebAssembly.Module(readFileSync(process.argv[2]));
for (const item of WebAssembly.Module.imports(module)) {
    if(item.module!=="abla_host"||!["write","exit"].includes(item.name)||item.kind!=="function")
        throw new Error(`unexpected import ${JSON.stringify(item)}`);
}
const panic=()=>{throw new Error("unexpected Wasm panic/host I/O");};
const instance=new WebAssembly.Instance(module,{abla_host:{write:panic,exit:panic}});
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

compile "$out/reader.ab" -o "$out/reader" --no-cache
"$out/reader"
ABLA_GC_STRESS=1 "$out/reader"
compile "$out/reader-wasm-build.ab" -o "$out/reader-wasm-builder" --fast --no-cache
"$out/reader-wasm-builder"
node --input-type=module - "$out/reader.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const module=new WebAssembly.Module(readFileSync(process.argv[2]));
for (const item of WebAssembly.Module.imports(module)) {
    if(item.module!=="abla_host"||!["write","exit"].includes(item.name)||item.kind!=="function")
        throw new Error(`unexpected import ${JSON.stringify(item)}`);
}
const panic=()=>{throw new Error("unexpected Wasm panic/host I/O");};
const instance=new WebAssembly.Instance(module,{abla_host:{write:panic,exit:panic}});
const value=instance.exports.check();
if(value!==0&&value!==0n) throw new Error(`PKCS12 reader Wasm ${value}`);
JS
compile "$out/reader-arm-build.ab" -o "$out/reader-arm-builder" --fast --no-cache
"$out/reader-arm-builder"
ld.lld -static --no-pie -z notext "$out/reader-arm.o" "$out/start.o" -o "$out/reader-arm"
qemu-aarch64 -cpu max "$out/reader-arm"
echo 'PKCS12: end-to-end native, GC stress, AArch64 and Wasm passed'
