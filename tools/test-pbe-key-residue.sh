#!/usr/bin/env bash
# The decrypted private key of abla/crypto/pbe is wiped, not left in freed memory (TODO "Secret residue": the Wasm
# freed heap). tests/cases/pbe-key-residue opens the committed encrypted fixtures (PKCS#8, PKCS#12, the PEM through
# abla/crypto/rsa, and the password written inline as a temporary owner), each in a fresh instance of the release Wasm
# module under Node; after two collections its linear memory is searched for 16-byte windows of the key's p, q, d, dp,
# dq and qinv in both byte orders and for 8-byte windows of the password in ASCII and UTF-16, each counted against the
# instance's memory before the call (its own static data). Nothing may be found. The control, a plain managed copy of
# the decrypted DER that nothing wipes, must be found: without it a search that sees nothing would prove nothing.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
out=build/pbe-key-residue
rm -rf "$out"
mkdir -p "$out"
command -v node > /dev/null || { echo "pbe key residue: no node, skipped"; exit 0; }
command -v openssl > /dev/null || { echo "pbe key residue: no openssl, skipped"; exit 0; }

fixtures=tests/vectors/crypto/encrypted-rsa
hex() { od -An -v -tx1 | tr -d ' \n'; }
p8=$(sed '1d;$d' "$fixtures/aes128-sha256.pem" | base64 -d | hex)
p12=$(hex < "$fixtures/modern.p12")
pem=$(hex < "$fixtures/aes128-sha256.pem")
sed -e "s|@P8HEX@|$p8|" -e "s|@P12HEX@|$p12|" -e "s|@PEMHEX@|$pem|" tests/cases/pbe-key-residue/main.ab.in > "$out/main.ab"
cat > "$out/build.ab" <<EOF
import "abla/wasm/build"
val built = #wasmBuildModule("pbe-key-residue", "main.ab", "main.wasm", false, false)
fun main(): int = if (built) 0 else 1
EOF
"$compiler" build "$out/build.ab" -o "$out/builder" --fast --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; echo "pbe key residue: the module did not build" >&2; exit 1; }
"$out/builder"
# The key's integers, from the public test key the fixtures encrypt (never from the program under test).
openssl rsa -in tests/vectors/crypto/rsa-implicit-key.pem -text -noout > "$out/key.txt" 2> /dev/null

node --input-type=module - "$out/main.wasm" "$out/key.txt" <<'JS'
import {readFileSync} from 'node:fs';
import {randomFillSync} from 'node:crypto';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const text = readFileSync(process.argv[3], 'utf8');
const integer = name => {
    const match = text.match(new RegExp(`^${name}:\\n((?:\\s+[0-9a-f:]+\\n)+)`, 'm'));
    if (!match) throw new Error(`no ${name} in openssl's dump`);
    let bytes = Buffer.from(match[1].replace(/[\s:]/g, ''), 'hex');
    while (bytes.length > 1 && bytes[0] === 0) bytes = bytes.subarray(1);
    return bytes;
};
const windows = (bytes, size, step) => {
    const found = [];
    for (let at = 0; at + size <= bytes.length; at += step) found.push(Buffer.from(bytes.subarray(at, at + size)));
    return found;
};
const needles = [];
for (const name of ['prime1', 'prime2', 'privateExponent', 'exponent1', 'exponent2', 'coefficient']) {
    const big = integer(name);
    const little = Buffer.from(big).reverse();
    for (const window of windows(big, 16, 8)) needles.push([`${name} (big-endian)`, window]);
    for (const window of windows(little, 16, 8)) needles.push([`${name} (little-endian)`, window]);
}
const password = Buffer.from('test-only-password', 'ascii');
const utf16 = Buffer.alloc(password.length * 2);
for (let i = 0; i < password.length; i++) utf16[2 * i + 1] = password[i];
for (const window of windows(password, 8, 1)) needles.push(['password (ASCII)', window]);
for (const window of windows(utf16, 8, 1)) needles.push(['password (UTF-16)', window]);
const count = (memory, needle) => {
    let n = 0, at = memory.indexOf(needle);
    while (at >= 0) { n++; at = memory.indexOf(needle, at + 1); }
    return n;
};
const panic = () => { throw new Error('unexpected Wasm panic or host I/O'); };
const scan = which => {
    let instance;
    const random = (pointer, count) => { randomFillSync(new Uint8Array(instance.exports.memory.buffer, pointer, count)); return count; };
    instance = new WebAssembly.Instance(module, {abla_host: {write: panic, exit: panic, random}});
    const memory = () => Buffer.from(instance.exports.memory.buffer);
    const before = needles.map(([, needle]) => count(memory(), needle));
    const status = Number(instance.exports.run(BigInt(which)));
    if (status !== 0) throw new Error(`run ${which}: status ${status}`);
    instance.exports.collect();
    const after = memory();
    const left = new Map();
    needles.forEach(([name, needle], i) => {
        if (count(after, needle) > before[i]) left.set(name, (left.get(name) || 0) + 1);
    });
    return left;
};
const labels = {1: 'pbeOpenPkcs8', 2: 'pbeOpenPkcs12', 3: 'pbeOpenPkcs8 with the password inline',
    4: 'rsaPrivateKeyFromPem (encrypted)'};
let failed = false;
for (const which of [1, 2, 3, 4]) {
    const left = scan(which);
    if (left.size > 0) {
        failed = true;
        console.error(`pbe key residue: ${labels[which]} left ${[...left].map(([n, c]) => `${c} windows of ${n}`).join(', ')}`);
    } else console.log(`ok   ${labels[which]}: no key or password bytes after two collections`);
}
const control = scan(9);
const keyLeft = [...control.keys()].filter(name => !name.startsWith('password'));
if (keyLeft.length === 0) {
    console.error('pbe key residue: the control (an unwiped copy of the key) was not found: the search sees nothing');
    failed = true;
} else console.log(`ok   control: an unwiped copy is found (${keyLeft.join(', ')})`);
if (failed) process.exit(1);
JS
echo "pbe key residue: the opened keys and passwords are wiped; an unwiped copy is found"
