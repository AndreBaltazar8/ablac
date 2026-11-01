#!/usr/bin/env python3
"""Writes tests/cases/crypto-pure/kat.ab: a few vectors of tests/vectors/crypto, with no file to read, for what
runs where there's no file system. Run it after changing the choice and commit its output."""
import pathlib

root = pathlib.Path(__file__).resolve().parents[2]
vectors = root / "tests/vectors/crypto"
out = []
w = out.append
w('''// Known answers from NIST CAVP and Wycheproof (tools/crypto/gen-kat.py), for targets with no files. On each path
// of AES. 0 if all agree, or the number of the first that doesn't.
import "abla/crypto"
import "abla/crypto/aes"
import "abla/crypto/rsa"

var katAt = 0
var katFailure = 0

fun katCheck(ok: bool): void {
    katAt = katAt + 1
    if (katFailure == 0 && !ok) katFailure = katAt
    return
}

fun hx(text: string): string = hexDecode(text)

// A fixed sequence, not randomness: only blinding reads it here, which doesn't change a signature.
var katRandomState = 1
fun katRandom(count: int): string {
    var out = ""
    for (i in 0 until count) {
        katRandomState = (katRandomState * 1103515245 + 12345) & 2147483647
        out = out + hexDecode("00".slice(0, 0) + katByte((katRandomState >> 16) & 255))
    }
    out
}

fun katByte(value: int): string {
    val digits = "0123456789abcdef"
    digits.slice(value >> 4, (value >> 4) + 1) + digits.slice(value & 15, (value & 15) + 1)
}

fun katAes(): void {''')
block = (vectors / "aes-block.txt").read_text().splitlines()
picked = {}
for line in block:
    f = line.split(" ")
    if f[0] in ("ecb", "cbc") and len(picked) < 12:
        k = (f[0], len(f[2]))
        if k not in picked and f[4] != "-":
            picked[k] = f
for f in picked.values():
    h = lambda s: "" if s == "-" else s
    if f[0] == "ecb":
        w(f'    katCheck(aesEcbEncryptPkcs5(hx("{f[2]}"), hx("{f[4]}")).bytes.slice(0, {len(f[5]) // 2}) == hx("{f[5]}"))')
        w(f'    katCheck(aesEcbDecryptPkcs5(hx("{f[2]}"), aesEcbEncryptPkcs5(hx("{f[2]}"), hx("{f[4]}")).bytes).bytes == hx("{f[4]}"))')
    else:
        w(f'    katCheck(aesCbcEncryptPkcs7(hx("{f[2]}"), hx("{f[3]}"), hx("{f[4]}")).bytes.slice(0, {len(f[5]) // 2}) == hx("{f[5]}"))')
        w(f'    katCheck(aesCbcDecryptPkcs7(hx("{f[2]}"), hx("{f[3]}"), aesCbcEncryptPkcs7(hx("{f[2]}"), hx("{f[3]}"), hx("{f[4]}")).bytes).bytes == hx("{f[4]}"))')
gcm = (vectors / "aes-gcm.txt").read_text().splitlines()
seen = set()
h = lambda s: "" if s == "-" else s
for line in gcm:
    f = line.split(" ")
    k = (len(f[1]), f[3] != "-", f[4] != "-")
    if f[7] == "valid" and k not in seen and len(seen) < 12:
        seen.add(k)
        w(f'    katCheck(aesGcmEncrypt(hx("{f[1]}"), hx("{f[2]}"), hx("{h(f[3])}"), hx("{h(f[4])}")).bytes == hx("{h(f[5])}{h(f[6])}"))')
        w(f'    katCheck(aesGcmDecrypt(hx("{f[1]}"), hx("{f[2]}"), hx("{h(f[5])}{h(f[6])}"), hx("{h(f[4])}")).bytes == hx("{h(f[3])}"))')
        w(f'    katCheck(!aesGcmDecrypt(hx("{f[1]}"), hx("{f[2]}"), hx("{h(f[5])}{h(f[6])[:-2]}" + "00"), hx("{h(f[4])}x")).ok)')
w('    return')
w('}')
w('')
w('fun katRsa(): void {')
rsa = (vectors / "rsa.txt").read_text().splitlines()
key = None
done = 0
for line in rsa:
    f = line.split(" ")
    if f[0] == "key":
        key = f
    if f[0] == "sign-sha1" and done == 0 and f[1] != "-":
        w(f'    val key = rsaPrivateKeyFromDer(hx("{key[1]}"))')
        w(f'    val publicKey = rsaPublicKeyFromDer(hx("{key[2]}"))')
        w('    katCheck(key.ok() && publicKey.ok())')
        w(f'    katCheck(key.signPkcs1Sha1Legacy(hx("{f[1]}")).bytes == hx("{f[2]}"))')
        w(f'    katCheck(publicKey.verifyPkcs1Sha1Legacy(hx("{f[1]}"), hx("{f[2]}")))')
        w(f'    katCheck(!publicKey.verifyPkcs1Sha1Legacy(hx("{f[1]}00"), hx("{f[2]}")))')
        w('    katCheck(publicKey.encryptOaepSha1Legacy("message").ok)')
        done = 1
w('''    return
}

fun katChecks(): int {
    cryptoSetRandom({ count: int -> katRandom(count) })
    for (hardware in [true, false]) {
        aesUseHardware = hardware
        katAes()
    }
    katRsa()
    katFailure
}''')
(root / "tests/cases/crypto-pure/kat.ab").write_text("\n".join(out) + "\n")
