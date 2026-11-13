# Hashing, encoding and dates

| Import | What it gives you |
|---|---|
| `abla/crypto` | SHA-512, SHA-384, SHA-256, SHA-1, MD5, HMAC, PBKDF2, Base64, hexadecimal, constant-time comparison |
| `abla/crypto/aes`, `abla/crypto/rsa`, `abla/crypto/pure` | AES (GCM, CBC, ECB), RSA signing, verifying and encryption, key parsing: in Abla, on every target |
| `abla/crypto/p256` | NIST P-256: ECDH and ECDSA (SHA-256, RFC 6979 nonces), in Abla, on every target |
| `abla/crypto/p384` | NIST P-384 ECDSA verification (for certificates), in Abla |
| `abla/crypto/x509` | X.509 certificates: parsing, chain building and validation (RFC 5280), host names (RFC 6125), a trust store, in Abla |
| `abla/crypto/chacha20poly1305` | ChaCha20, Poly1305 and the RFC 8439 AEAD: in Abla, on every target |
| `abla/crypto/rsapss` | RSASSA-PSS (SHA-256, -384, -512; MGF1 over the same hash) on `abla/crypto/rsa` keys: in Abla, on every target |
| `abla/crypto/hosted` | the same and more, through OpenSSL |
| `abla/random` | a cryptographically secure source (`getrandom(2)`) |
| `abla/date` | UTC calendar dates, ISO 8601 and HTTP dates |
| `abla/jwt`, `abla/jwt/remote` | JSON Web Token verification ([networking.md](../networking.md)) |

`abla/crypto` and `abla/date` are pure Abla: they work on every target and at compile
time. `abla/crypto/aes` and `abla/crypto/rsa` are too, but not at compile time. `abla/crypto/hosted`
is OpenSSL, and links it into the programs that import it. [Which to use](#which-to-use).

## `abla/crypto`

The hash functions return the **raw digest bytes**, not text. Wrap them in
`hexEncode` (or `base64Encode`) to print or compare them as text:

```abla
import "abla/io"
import "abla/crypto"

fun main {
    println(hexEncode(sha256("abc")))
    println(hexEncode(hmacSha256("key", "message")))
    val encoded = base64Encode("hello, world")
    println("$encoded -> ${base64Decode(encoded)}")
    println("${sha256("abc").size} bytes; equal: ${constantTimeEquals("token", "token")}")
}
// output:
// ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
// 6e9ef29b75fffc5b7abae527d58fdadb2fe42e7219011976917343065f58ed4a
// aGVsbG8sIHdvcmxk -> hello, world
// 32 bytes; equal: true
```

| Function | Result |
|---|---|
| `sha512(data)`, `sha384(data)`, `sha256(data)`, `sha1(data)`, `md5(data)` | raw digest bytes (64, 48, 32, 20 and 16 bytes) |
| `hmacSha512(key, message)`, `hmacSha384`, `hmacSha256`, `hmacSha1` | raw MAC of the hash's size |
| `pbkdf2Sha256(password, salt, iterations)` | a raw 32-byte derived key |
| `base64Encode(data)`, `base64Decode(text)` | standard Base64 with padding |
| `hexEncode(data)`, `hexDecode(text)` | lowercase hexadecimal; decoding takes either case, and gives `""` for anything invalid |
| `constantTimeEquals(a, b)` | equality that takes the same time wherever the inputs differ; use it to compare secrets |
| `binaryXor(a, b)` | bytewise XOR of two equal-length strings |

SHA-1 and MD5 are there for protocols that require them (WebSocket
handshakes, legacy checksums), not for security.

The hashes and HMACs have no secret-dependent branch or table index in their rounds,
but nothing stops the code generator adding one, and the key's length shows.
`constantTimeEquals` is `abla/ct`'s `ctEquals` when compiled ([what that promises](../constant-time.md)),
and an ordinary loop at compile time. Different lengths are unequal at once.
`hexEncode`, `hexDecode` and the Base64 functions aren't constant-time at all. Nothing
here wipes memory: a secret in a string stays there until the memory is reused.

## `abla/crypto/hkdf`

HKDF ([RFC 5869](https://www.rfc-editor.org/rfc/rfc5869)) over HMAC-SHA-1, -256, -384 and -512, and TLS 1.3's
HKDF-Expand-Label and Derive-Secret ([RFC 8446](https://www.rfc-editor.org/rfc/rfc8446) section 7.1). The hash is
`HKDF_SHA1`, `HKDF_SHA256`, `HKDF_SHA384` or `HKDF_SHA512`.

| Function | Result |
|---|---|
| `hkdfExtract(hash, salt, ikm)` | the pseudorandom key (an empty salt is hash-length zeros) |
| `hkdfExpand(hash, prk, info, length)` | a `CryptoResult` of `length` bytes; `ok` is false past 255 hash lengths or below 0 |
| `hkdf(hash, salt, ikm, info, length)` | Extract then Expand |
| `tls13ExpandLabel(hash, secret, label, context, length)` | HKDF-Expand-Label (`label` without its `"tls13 "` prefix); `ok` is false for a label of 0 or more than 249 bytes, a context over 255 or a length over 65535 |
| `tls13DeriveSecret(hash, secret, label, transcriptHash)` | Expand-Label with the transcript hash as context and the hash's length as output |

Secrets only pass through `hmacSha1`/`hmacSha256`/`hmacSha384`/`hmacSha512` (the paragraph above applies); the
lengths, labels and contexts are public. Tested against all seven RFC 5869 vectors and the RFC 8448 early and derived
secrets (`tools/test-hkdf.sh`).

## `abla/crypto/x25519`

X25519 ([RFC 7748](https://www.rfc-editor.org/rfc/rfc7748) section 5): Diffie-Hellman on Curve25519, in Abla, no
OpenSSL, on every target.

| Function | Result |
|---|---|
| `x25519(scalar, point)` | a `CryptoResult` of the 32-byte product; `ok` is false for a wrong length and for an all-zero result (a point of small order; TLS 1.3 aborts then) |
| `x25519PublicKey(scalar)` | the public key of a private key: `x25519` of it and the base point 9 |

A private key is any 32 random bytes; the function clamps it as the RFC says. Bit 255 of a point is ignored and a
point at or above 2^255 - 19 is taken mod p, as the RFC says.

It is constant-time: the Montgomery ladder runs its 255 steps and swaps by a mask on every bit, the field arithmetic
(32 limbs of 8 bits in `secretU32`, so nothing wider than 32 bits is needed on any target) has no branch, memory index or
division on a value, and the inverse is Fermat's. `tools/test-ct.sh` reads the core (`BEGIN X25519 SECRET CORE` in
`abla/crypto/x25519/entry.ab`) on x86-64, AArch64, Wasm and Xtensa, with deliberate leaks that it has to catch. The wrapper wipes its
memory and the stack below it (2,048 bytes) after each call, and nothing else (the scalar a caller holds in a string stays
there). Speed: about 1.4 ms per product on a current x86-64 core. Tested against RFC 7748 (section 5.2's two vectors, the
iterated function after 1, 1,000 and, with `X25519_MILLION=1`, 1,000,000 rounds; section 6.1's Alice and Bob), the
refusal of the small-order points, and random scalars and points against the `openssl` CLI (`tools/test-x25519.sh`).

## `abla/crypto/ed25519`

Ed25519 ([RFC 8032](https://www.rfc-editor.org/rfc/rfc8032) section 5.1) in Abla, no OpenSSL, on every target, over the
field of `abla/crypto/x25519`.

| Function | Result |
|---|---|
| `ed25519PublicKey(seed)` | the 32-byte public key of a 32-byte private seed |
| `ed25519Sign(seed, message)` | the 64-byte signature (R, then S), deterministic |
| `ed25519Verify(publicKey, message, signature)` | whether it verifies; `false` for any wrong length |

Verification is the strict one: S is below L, the public key is a point with a canonical encoding, and the encoding of
[S]B - [k]A is R's bytes (so a non-canonical R, or S + L, is refused). The key, the nonce and S are secret; the message,
the public key and R are public.

Constant-time: the scalar multiplications that take a secret run 256 steps of a doubling, an addition (the unified,
complete Edwards formula) and a masked select of the whole point, and the arithmetic modulo L is bit by bit with masked
selects, so no branch, memory index or division depends on a secret. `tools/test-ct.sh` reads the core (`BEGIN ED25519
SECRET CORE` in `abla/crypto/ed25519/entry.ab`) on x86-64, AArch64, Wasm and Xtensa, with deliberate leaks it has to catch.
What it does not cover: the SHA-512 over strings (the seed's hash and the nonce's pass through ordinary strings, which
are not wiped) and, as for X25519, a seed the caller holds in a string. Verification uses the same constant-time code for
both products, so it is not faster than signing. Speed: about 8 ms to sign and 8 ms to verify on a current x86-64 core (a whole process run).
Tested against RFC 8032 section 7.1's vectors, Wycheproof's 210 verification cases (`tests/vectors/crypto/wycheproof-ed25519.json`),
and random seeds and messages against the `openssl` CLI both ways (`tools/test-ed25519.sh`).

## `abla/crypto/hosted`

AES and RSA through OpenSSL's libcrypto, the provider `abla/tls/hosted` already uses, 1.1.1
or 3.x. Programs that don't import it don't link it, and stay free of libc.
Where OpenSSL is missing (embedded targets, wasm), use [`abla/crypto/aes` and `abla/crypto/rsa`](#ablacryptoaes-and-ablacryptorsa).

```abla
import "abla/io"
import "abla/crypto"
import "abla/crypto/hosted"
import "abla/random"

fun main {
    val key = secureRandomBytes(32)
    val nonce = secureRandomBytes(12)
    val sealed = hostedAesGcmEncrypt(key.bytes, nonce.bytes, "a message", "its context")
    val opened = hostedAesGcmDecrypt(key.bytes, nonce.bytes, sealed.bytes, "its context")
    println("${sealed.bytes.size} ${opened.bytes}")
    println(hostedAesGcmDecrypt(key.bytes, nonce.bytes, sealed.bytes, "another").error)
    val ecb = hostedAesEcbEncryptPkcs5("0123456789abcdef", "hello")
    println(hexEncode(ecb.bytes))
    val none = hostedRsaPrivateKeyFromPem("not a key")
    println("${none.ok()}")
}
// output:
// 25 a message
// authentication failed: the data, key, nonce or associated data is wrong
// 674c7ef38e78cabd9cec9c125823a639
// false
```

Each operation returns a `CryptoResult(bytes, ok, error)`. An `error` names what failed
and never holds key material or plaintext.

### AES

| Function | Notes |
|---|---|
| `hostedAesGcmEncrypt(key, nonce, plaintext, associatedData = "")`, `hostedAesGcmDecrypt(key, nonce, ciphertext, associatedData = "")` | use this one. The result is the ciphertext and then a 16-byte tag; decryption returns nothing unless the tag verifies. The nonce has 12 bytes and must never repeat under a key |
| `hostedAesCbcEncryptPkcs7(key, iv, plaintext)`, `hostedAesCbcDecryptPkcs7(key, iv, ciphertext)` | unauthenticated. The IV has 16 unpredictable bytes. Bad padding is a distinct failure, so never show a remote party which failure happened (a padding oracle): pair it with a MAC checked first |
| `hostedAesEcbEncryptPkcs5(key, plaintext)`, `hostedAesEcbDecryptPkcs5(key, ciphertext)` | **for protocols that require it only**, such as Portugal's AT WS-Security header. Equal blocks encrypt equally |

Keys have 16, 24 or 32 bytes. For a 16-byte block, PKCS#5 and PKCS#7 padding are the same.

### RSA

Load a key, check `ok()` or `error`, and call its methods. A key is a resource: OpenSSL's
copy is freed and cleansed when it's dropped.

| Function | Reads |
|---|---|
| `hostedRsaPrivateKeyFromPem(pem, passphrase = "")` | PKCS#8, encrypted PKCS#8, PKCS#1. An encrypted key without its passphrase fails; it never asks on the terminal |
| `hostedRsaPrivateKeyFromDer(der)` | unencrypted PKCS#8 or PKCS#1 |
| `hostedRsaPrivateKeyFromPkcs12(der, password)` | a `.pfx`. OpenSSL 3 refuses RC2 (what OpenSSL 1.x's `pkcs12 -export` writes) unless re-encrypted: `openssl pkcs12 -in old.pfx -legacy -nodes \| openssl pkcs12 -export -out new.pfx` |
| `hostedRsaPublicKeyFromPem(pem)` | `PUBLIC KEY` (SubjectPublicKeyInfo), `RSA PUBLIC KEY`, or the key of a `CERTIFICATE`. The certificate's chain and dates aren't checked |
| `hostedRsaPublicKeyFromDer(der)`, `hostedRsaPublicKeyFromCertificateDer(der)` | SubjectPublicKeyInfo; an X.509 certificate's key |
| `hostedRsaGeneratePrivateKey(bits = 2048)` | a new key of 2048, 3072 or 4096 bits with e = 65537, the sizes and exponent of `rsaGeneratePrivateKey` in `abla/crypto/rsa`; any other size fails. OpenSSL draws the primes, and the key stays in its memory, wiped on drop |

A key, generated or read, exports with `private.toPkcs8Der()` and `private.toPkcs8Pem()` (unencrypted PKCS#8, which `hostedRsaPrivateKeyFromDer` and `FromPem` read back and `abla/crypto/rsa` reads too), and with `toSpkiDer()` and `toSpkiPem()` on a private or a public key (SubjectPublicKeyInfo, read by `hostedRsaPublicKeyFromDer` and `FromPem`). An export is a `CryptoResult` of Abla bytes: it can't be wiped, so write it where it must go and drop it. Nothing in an error names key material.

| Method | Keys | Notes |
|---|---|---|
| `private.signPkcs1Sha256(message)`, `public.verifyPkcs1Sha256(message, signature)` | 2048 bits or more | RSASSA-PKCS1-v1_5, deterministic |
| `private.signPkcs1Sha1Legacy(message)`, `public.verifyPkcs1Sha1Legacy(message, signature)` | 1024 bits or more | **required by Despacho 8632/2014 for Portuguese invoices; nothing new should use it.** SHA-1 collisions are practical, and 1024 bits is within reach of a well-funded attacker |
| `public.encryptOaepSha256(plaintext)`, `private.decryptOaepSha256(ciphertext)` | 2048 bits or more | use this one. SHA-256 for both the hash and MGF1 |
| `public.encryptOaepSha1Legacy(plaintext)`, `private.decryptOaepSha1Legacy(ciphertext)` | 1024 bits or more | SHA-1 for both, the default of Java's OAEP and .NET's `fOAEP` |
| `public.encryptPkcs1Legacy(plaintext)`, `private.decryptPkcs1Legacy(ciphertext)` | 1024 bits or more | RSAES-PKCS1-v1_5, for protocols that require it. See below |

From OpenSSL 3.2, `decryptPkcs1Legacy` on bad padding succeeds with random-looking bytes
(implicit rejection); before it, the call fails, and showing a remote party that failure is
the Bleichenbacher attack. Check the plaintext's expected form either way.

`opensslConstantTimeEquals(a, b)` compares with `CRYPTO_memcmp`, which is built so
that a compiler can't make it stop early. Different lengths are unequal at once.

### Timing and memory

| | Protection | Limit |
|---|---|---|
| RSA private operations | OpenSSL's blinding and constant-time exponentiation, for keys with their CRT values (every format above) | PKCS#1 v1.5 decryption has a history of leaks (Marvin, 2023): implicit rejection from 3.2 is the fix. Use a current OpenSSL |
| AES | AES-NI, ARMv8 instructions, or vector code (VPAES) | a CPU with none of them falls back to OpenSSL's table code, which isn't constant-time. Any x86-64 or ARMv8 server of the last decade has them |
| GCM's tag | carry-less multiply instructions | without them, table-based |
| Verification and public-key encryption | no secret is involved in the key | |
| Key generation | OpenSSL's generator, with its working numbers freed and cleansed | the exported PKCS#8 or PEM is an Abla string, like the key bytes below |
| Key bytes in Abla strings | none: strings can't be wiped | PEM text, passphrases and `secureRandomBytes` results stay in memory until it is reused. Read them late and don't keep them. Failed decryptions cleanse their buffer, and successful ones are the caller's |

Left out so far: RSA-PSS, ECDSA signing, Ed25519, ChaCha20-Poly1305, HKDF,
SHA-3, SHA-224, CBC without padding, GCM with other nonce or tag sizes, and OAEP labels. Nothing here needs them
yet, and each is a short wrapper around OpenSSL when something does.

## `abla/crypto/chacha20poly1305`

RFC 8439 in Abla, with no OpenSSL and no table: `chaCha20Poly1305Seal(key, nonce, plaintext, associatedData = "")` returns the
ciphertext and then the 16-byte tag in a `CryptoResult`; `chaCha20Poly1305Open(key, nonce, sealed, associatedData = "")` checks the
tag in constant time before any plaintext exists and fails with one message whichever part was wrong. The key is 32 bytes and the
nonce 12 (never reuse a nonce under a key). `chaCha20Xor(key, counter, nonce, data)` is the bare cipher and
`poly1305(key, message)` the bare one-time authenticator, for protocols that build on them (TLS 1.3 uses the AEAD). The secret-handling
cores are read in the generated code of x86-64, AArch64, Wasm and Xtensa by `tools/test-ct.sh`, with a leaking twin of each kind that
the check must catch. Tests: RFC 8439's vectors on every target, and every message length from 0 to 200 against Node.

## `abla/crypto/rsapss`

RSASSA-PSS (RFC 8017) over `abla/crypto/rsa`'s keys, for TLS 1.3's `rsa_pss_rsae_*` and X.509: `key.signPssSha256(message)` (also
`signPssSha384`, `signPssSha512`) signs with a random salt of the hash's length; `publicKey.verifyPssSha256(message, signature)`
(and the others) checks one. `rsaPssSign(key, hashBits, message, saltLength)` and `rsaPssVerify(key, hashBits, message, signature,
saltLength)` take another salt length (0 is common); `rsaPssSignWithSalt` signs with a salt you give, for known-answer tests. Keys
under 2048 bits are refused. The private operation is `abla/crypto/rsa`'s (blinded, CRT, constant time); the encoding and the
check hold nothing secret and take variable time. Tests: Wycheproof's RSA-PSS vectors (2048, 3072, 4096 bits, SHA-256 and -512, salt
lengths 32 and 0), and signing and verifying against Node, including a given salt byte for byte.

## `abla/crypto/aes` and `abla/crypto/rsa`

AES and RSA with no OpenSSL, for wherever it isn't, and for programs that shouldn't link it. They answer to the names
`abla/crypto/hosted` gives with `hosted` in front (`rsaPrivateKeyFromPem` there is `hostedRsaPrivateKeyFromPem`), so one
program, or the packages it uses, can have both. `abla/crypto/pure` is both of these two. Same vectors, same results: see [the
tests](#how-this-is-tested). The difference is in what they don't offer, and in how far their timing has been
looked at.

```abla
import "abla/io"
import "abla/crypto"
import "abla/crypto/aes"

fun main {
    val key = hexDecode("000102030405060708090a0b0c0d0e0f")
    val nonce = hexDecode("202122232425262728292a2b")
    val sealed = aesGcmEncrypt(key, nonce, "a message", "its context")
    println(aesGcmDecrypt(key, nonce, sealed.bytes, "its context").bytes)
    println(aesGcmDecrypt(key, nonce, sealed.bytes, "another").error)
    println(aesEcbDecryptPkcs5(key, aesEcbEncryptPkcs5(key, "hello").bytes).bytes)
}
// output:
// a message
// authentication failed: the data, key, nonce or associated data is wrong
// hello
```

| | |
|---|---|
| `aesGcmEncrypt`, `aesGcmDecrypt`, `aesCbcEncryptPkcs7`, `aesCbcDecryptPkcs7`, `aesEcbEncryptPkcs5`, `aesEcbDecryptPkcs5` | as in [`abla/crypto/hosted`](#aes) |
| `rsaPublicKeyFromPem`, `rsaPublicKeyFromDer`, `rsaPublicKeyFromCertificateDer` | as [there](#rsa). A certificate's chain, dates and signature aren't checked |
| `rsaPrivateKeyFromPem(pem)`, `rsaPrivateKeyFromDer(der)` | PKCS#8 and PKCS#1, unencrypted. Password-resource overloads read PBES2/PBKDF2/AES-CBC [encrypted PKCS#8](encrypted-keys.md); `rsaPrivateKeyFromPkcs12(der, password, limits)` reads modern MAC-verified DER key bags (see the same limits and restrictions) |
| `private.signPkcs1Sha256`, `public.verifyPkcs1Sha256`, `private.signPkcs1Sha1Legacy`, `public.verifyPkcs1Sha1Legacy` | as there, with the same minimum sizes |
| RSA encryption and decryption | as above, with empty-label OAEP. PKCS#1 v1.5 uses deterministic implicit rejection: invalid padding returns synthetic plaintext. Prefer OAEP, and make subsequent protocol checks indistinguishable to remote peers |
| `rsaGeneratePrivateKey(bits = 2048)` | Generate a key with 2048, 3072 or 4096 bits and exponent 65537. Check `ok()` or `error`; generation fails without randomness. |
| `private.toPkcs8Der()`, `private.toPkcs8Pem()` | Export unencrypted PKCS#8. A number-only key without its private exponent returns an error. |
| `cryptoSetRandom(source)` | where the randomness for encryption, blinding and key generation comes from. Needed on anything but x86-64 Linux, where it's `getrandom`: a Wasm host's `crypto.getRandomValues`, an ESP32's hardware RNG. Its quality is yours to answer for. Without one, what needs it fails, and signing never goes on unblinded |

For parsed PEM and DER keys, the synthetic PKCS#1 v1.5 result matches OpenSSL's implicit rejection for the same
private exponent and ciphertext. `rsaPrivateFromNumbers` accepts an optional private exponent as its last argument;
without it, rejection is derived from the CRT secrets and is deterministic but does not match OpenSSL. Do not mix
these representations for the same key in an attacker-observable service. The derived hash and intermediate
strings, like PEM text, cannot be wiped.

Key generation uses the probable-prime bounds, separation and Miller–Rabin rounds in
[FIPS 186-5](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf);
this is a choice of parameters, **not** a FIPS validation claim. Prime candidate search, sieving,
primality decisions, and its duration are variable-time. Key derivation uses fixed-width secret
arithmetic; DER/PEM encoding is variable-time. The random source must be cryptographically secure, and its quality is the caller's
responsibility when using `cryptoSetRandom`. Prime candidates, intermediate key strings, and
exported PEM/DER are ordinary strings and cannot be wiped. The private key's raw allocation is
wiped when dropped. Protect the generated unencrypted export as private key material.

## `abla/crypto/p256`

NIST P-256 (secp256r1) with no OpenSSL, on the same constant-time big-number arithmetic as RSA. Keys are `string`s: a
private key is its 32 big-endian bytes, a public key the 65-byte uncompressed point `0x04 || X || Y` (compressed points are
refused). A failure comes back as a `CryptoResult` with `error` set.

| | |
|---|---|
| `p256GeneratePrivateKey()` | a random private key in 1..n-1; needs a random source like RSA's (`cryptoSetRandom`) |
| `p256PublicKey(privateKey)` | the public point of a private key |
| `p256IsValidPublicKey(point)` | whether it is an uncompressed point on the curve |
| `p256Ecdh(privateKey, peerPublicKey)` | ECDH: the shared x coordinate, 32 bytes. The peer's point is checked to be on the curve (P-256 has cofactor 1) |
| `p256EcdsaSign(privateKey, message)`, `p256EcdsaSignRaw` | ECDSA over SHA-256 with the RFC 6979 nonce, so one message always gets one signature: as DER, or as `r || s` (64 bytes) |
| `p256EcdsaVerify(publicKey, message, signature)`, `p256EcdsaVerifyRaw`, `p256EcdsaVerifySha384`, `p256EcdsaVerifyDigestRaw` | verification of a strict DER signature (no BER, no padding, no negative or oversized integers) or of `r || s`; the digest forms take any hash, cut to its leftmost 256 bits |
| `p256SignatureToDer(raw)`, `p256SignatureFromDer(der)` | between the two forms |

Point addition and doubling are the complete formulas of Renes, Costello and Batina, so no input (the point at infinity
included) takes another path. A scalar multiplication always does 64 windows of four doublings and one addition, reading the
whole table of sixteen multiples each time; inversions are Fermat's, by public exponents. A private key out of range is
refused, and so is an RFC 6979 candidate nonce out of range (it happens about once in 2^32 signatures): both outcomes are
public. `tools/test-ct.sh` reads the field, point and scalar-multiplication routines (the `P256 SECRET CORES` of the source) for a
secret reaching a branch or an address on each target, with a planted table read and a planted branch that it must find.
Verification works on public values and is variable-time. A private key, a nonce, its HMAC chain and the exported bytes are strings
and cannot be wiped; the limbs and table made inside a call are, and so is the stack it used.

It is checked against Wycheproof's ECDSA (484 vectors) and ECDH (355 point-encoded vectors, `tests/cases/p256/vectors`), RFC 6979
appendix A.2.5, itself, and the `openssl` command line in both directions (`tools/test-p256.sh`). Wycheproof's compressed-point
cases, which it marks acceptable, are refused.

### What timing protection each has, and hasn't

Read [constant-time.md](../constant-time.md) first: it's what "read" below means, and its limits (a CPU's own
variable-time instructions, Wasm engines, speculation, memory left behind) apply to every line here.

| | Protects | Read on the 4 targets | Doesn't protect |
|---|---|---|---|
| AES software (bitsliced) | no table, no branch on key or data | S-box, rounds, in both directions. **The key schedule and the block's loading aren't read**: they use the same secret types | a CPU whose word operations vary with data |
| AES hardware (x86-64 AES-NI, ARMv8) | no table, per the vendor | no: one instruction a round, and vendors state the timing doesn't depend on data, though ARM's DIT isn't set | |
| Which of the two | | | not hidden: a program on one machine always takes the same one |
| GHASH software | masks and shifts, 128 steps for each block, no table | yes | |
| GHASH hardware | carry-less multiply, per the vendor | no | |
| GCM's tag check | every byte compared, before any plaintext is made | yes | a tag length is public |
| CBC and ECB padding | checked with masks | yes | **the answer**: "bad padding" is returned. That is a padding oracle if a remote party sees it. Never let one |
| RSA verify, encrypt | public values, so nothing to protect but the message before encryption: its bytes aren't branched on in the arithmetic | Montgomery multiplication | padding is built from `string`s with the usual operations; the plaintext's length is public |
| RSA signing | blinded base, CRT with a 4-bit fixed window read whole, squarings and multiplications independent of the exponent, result checked with the public exponent | Montgomery multiplication, the table lookup, the conditional subtraction. **Not read**: the steps around them in `rsaCrt`, which use the same secret types and branch only on lengths | sizes of p, q and their numbers are public. No exponent blinding, which the fixed window makes unnecessary for timing but would help against power analysis. On Xtensa `mull`'s timing is unpublished: see below |
| RSA decryption | the same blinded, checked CRT operation; OAEP and PKCS#1 padding are scanned with masks. PKCS#1 v1.5 selects a deterministic synthetic message on bad padding | padding and synthetic-message selection | malformed ciphertext and operational failures are reported. Decrypted blocks and plaintext are strings and cannot be wiped |
| Key loading | the base 64 of a PEM isn't branched on or looked up | the character step | DER tags and lengths are branched on, which are public, as is the position of line breaks. An integer's length shows through parsing. **The `string`s holding the DER and base 64 aren't wiped** |
| Keys in memory | a private key's numbers are in raw memory, wiped on drop; AES's schedule too | | what was copied before: the PEM, its decoded `string` |
| `hexDecode`, `base64Decode` | nothing | | not constant-time: don't feed them secrets that matter |

On **ESP32-S3** all of this is software (the S3's AES peripheral isn't used), and it's the least examined: read in
the assembly, compiled, and never run here. Its multiplier has no published timing. For a key that matters,
don't use it there without measuring it on the board.

Nothing here has been through what OpenSSL's has: years of attack, and timing measured on real hardware. No
statistical test (`dudect`) has been run: the assembly check shows no branch or index on a secret, and no more
than that.

### Which to use

- On a hosted server with OpenSSL, for keys that matter: `abla/crypto/hosted`. It has broader format support and more scrutiny, and is about 14 times faster at signing. TLS stays on it.
- For embedded and Wasm, or where linking OpenSSL isn't wanted: these. Compared on an i9-13900K with 2048-bit
  keys, 2026-11-01: signing 5.1 ms (OpenSSL 0.36 ms); GCM 476 MiB/s with instructions and 34 MiB/s without (OpenSSL
  2700 MiB/s); ECB 2700 MiB/s and 130 MiB/s.

### How this is tested

`tools/test-crypto-pure.sh`: the NIST CAVP and Wycheproof vectors of `tools/test-crypto.sh` on both AES paths,
on this CPU and on `qemu-x86_64 -cpu qemu64` with neither instruction; refusals; random inputs against
`abla/crypto/hosted` and the `openssl` CLI, both ways. Known answers on AArch64 under qemu (with AES and PMULL) and
on Wasm under Node. On Xtensa it's compiled, and read by `tools/test-ct.sh`, not run. RSA decryption vectors run on the hosted native paths.

`tools/test-crypto-hosted-keygen.sh`: `hostedRsaGeneratePrivateKey` at 2048, 3072 and 4096 bits signs, verifies, encrypts and
decrypts through hosted; its exports read back to the same key; it works both ways with `abla/crypto/rsa` in one program; other sizes
are refused; and the `openssl` CLI checks the 2048-bit key (consistency, e = 65537, its signature) and that its exports are byte-equal to
openssl's.

## Dates: `abla/date`

Times are `int` milliseconds since 1970-01-01T00:00:00Z. A `UtcDate` is
that time split into calendar fields, in the proleptic Gregorian calendar,
without leap seconds:

```abla
import "abla/io"
import "abla/date"

fun main {
    val ms = utcMilliseconds(2024, 2, 29, 13, 5, 9)
    val date = utcDate(ms)
    println("${date.iso8601()} weekday ${date.weekday}, day ${date.dayOfYear()} of the year")
    println(httpDate(ms))
    val parsed = utcIso8601Parse("2024-02-29T13:05:09.000Z")
    if (parsed != null) println("round trip: ${parsed == ms}")
    println("${utcIso8601Parse("not a date") == null} ${dateLeapYear(2100)} ${dateDaysInMonth(2024, 2)}")
}
// output:
// 2024-02-29T13:05:09.000Z weekday 4, day 60 of the year
// Thu, 29 Feb 2024 13:05:09 GMT
// round trip: true
// true false 29
```

| Function | Result |
|---|---|
| `utcMilliseconds(year, month, day, hour = 0, minute = 0, second = 0, millisecond = 0)` | the time of a civil date |
| `utcDate(milliseconds)` | a `UtcDate(year, month, day, hour, minute, second, millisecond, weekday)`: month 1-12, day 1-31, weekday 0 (Sunday) to 6 |
| `date.milliseconds()`, `date.dayOfYear()` | back to a time; the day number (1-366) |
| `date.isoDate()`, `date.isoTime()`, `date.iso8601()`, `utcIso8601(ms)` | `2024-02-29`, `13:05:09.000`, `2024-02-29T13:05:09.000Z` |
| `date.httpDate()`, `httpDate(ms)` | `Thu, 29 Feb 2024 13:05:09 GMT` |
| `utcIso8601Parse(text)`, `httpDateParse(text)` | `int?`: the time, or `null` for invalid text |
| `dateLeapYear(year)`, `dateDaysInMonth(year, month)`, `dateWeekdayName(weekday)`, `dateMonthName(month)` | calendar facts |

The current time comes from `utcNow()` in `abla/process/time`
([system.md](system.md#time-ablaprocesstime)).

## `abla/tls/hosted`: upgrading streams

`tlsUpgrade(connection, host, caPath = "", timeoutMilliseconds = 5000,
readWriteTimeoutMilliseconds = 30000)` consumes an established `TcpConnection`
or `UnixConnection` and returns a verified `TlsConnection`. `host` is the
certificate hostname and SNI name, rather than the Unix socket pathname.
`caPath` selects a CA file; the empty default uses system trust. Failure consumes
and closes the raw connection too.

For mutual TLS, use `tlsUpgradeWithIdentity(connection, host, identity,
caPath = "", timeoutMilliseconds = 5000, readWriteTimeoutMilliseconds = 30000,
deadline = 0)` on either TCP or Unix. The identity comes from
`tlsClientIdentityFromPem` or `tlsClientIdentityFromPkcs12`, as with
`tlsConnectWithIdentity`; the caller may drop it once upgrade returns. The
nonzero `deadline` is an absolute monotonic millisecond time bounding the
handshake. The low-level `tlsUpgradeHandle` also accepts either stream type,
this deadline and explicit identity handles; the ordinary upgrade API keeps
its existing timeout arguments. Already-configured socket timeouts survive
client and server upgrades; otherwise the arguments supply handshake and
subsequent read/write limits.

`tlsServerUpgrade(connection, certificatePath, privateKeyPath,
handshakeTimeoutMilliseconds = 5000, readWriteTimeoutMilliseconds = 30000,
deadline = 0)` consumes an accepted TCP or Unix stream and negotiates server
TLS. **It loads the certificate and private key on every call.** Use `tlsListen`
when serving many TCP connections: it reuses its context. There is no separate
public context handle API. A nonzero deadline bounds the entire server
handshake, including peers that trickle a partial record. A failed upgrade
closes the connection; a successful `TlsConnection` owns it until close/drop.

Unix upgrades support pathname sockets on Linux and Darwin, and Linux abstract
sockets. A Unix peer has no IP `peerAddress` (`socketPeerAddress` returns null).
Closing a TLS connection or listener does not unlink a Unix pathname: the caller
still owns that cleanup. Existing TCP upgrade signatures and behavior are
unchanged; overload selection uses the connection's type, including named calls.

## `abla/crypto/x509`

Certificate parsing and server-chain validation with no OpenSSL, for the TLS that is written in Abla. All of it is public input:
the parser reads a certificate once by a fixed schema (strict DER: minimal lengths, no trailing bytes, one-byte tags, UTCTime and
GeneralizedTime only in their RFC 5280 forms), with no recursion, and answers `ok = false` with an `error` for anything else;
tests feed it every truncation and byte change of a certificate.

```
val store = x509SystemTrustStore()                      // or x509TrustStoreFromPem(text), x509TrustStoreFromFile(path)
val result = x509Verify([leafDer, intermediateDer], store, X509Options("example.com", nowSeconds))
if (!result.ok) println(result.error)                   // result.path is the validated chain, leaf first, anchor last
```

| | |
|---|---|
| `x509ParseDer(der)`, `x509ParsePem(text)` | an `X509Certificate`: `subject`, `issuer` (`X509Name`: DER, relative distinguished names, a canonical form to compare them), `notBefore` and `notAfter` in seconds since 1970, `serial`, `spki` with `keyOid`, `keyParameters` and `keyBits`, and the extensions basicConstraints (`isCa`, `pathLength`), keyUsage (a bit mask), extendedKeyUsage, subjectAltName (`altNames`: DNS, IP address, e-mail, URI, directory names), nameConstraints (`permitted`, `excluded`), the key identifiers, and the first critical extension not known (`unknownCritical`) |
| `x509Verify(chain, store, options)` | builds a path from the leaf (the first DER of `chain`; the others are candidate intermediates in any order, extras and unparsable ones are ignored) to a certificate of the trust store, depth-first, with at most 64 signature checks, and validates it |
| `X509Options(hostname, now, maximumDepth = 8, usage = 0)` | the host name or IP address to match ("" skips the check), the time in seconds since 1970 (required: this module reads no clock, so a TLS layer passes its own), the longest path, and 0 for server authentication (1 for client) |
| `x509MatchesHost(cert, host)`, `x509DnsMatches(pattern, host)`, `x509IpBytes(text)` | the RFC 6125 rules on their own |
| `x509CheckSignature(cert, issuer)`, `x509ValidatePath(path, options)` | the pieces: one signature, and the checks of a built path |
| `x509TrustStoreFromPem`, `x509TrustStoreFromFile`, `x509SystemTrustStore()` | the store; the system one is the first of the usual bundle files (`x509SystemBundlePaths()`: Debian, Red Hat, SUSE, Alpine, FreeBSD, macOS) that holds a certificate |

What a path must satisfy: every certificate is within its validity and has no critical extension this code does not know; every
issuer is a CA (basicConstraints cA, and keyCertSign in its keyUsage if it has one), within its path length constraint (self-issued
intermediates not counted), and, unless it is the anchor, allows server authentication in its extended key usage; the leaf allows
the purpose and has the host name among its subjectAltName entries (the common name is never used; a wildcard is a lone `*` as the
whole left label of a name with at least three labels and matches exactly one label; IP addresses match iPAddress entries byte for
byte); name constraints (DNS, IP, directory name) of each CA apply to the names below it, a wildcard that covers an excluded name
is refused, and e-mail or URI names and other name forms under constraints are refused as unchecked. Signatures: RSA PKCS#1 v1.5 and
ECDSA with SHA-256, -384 or -512 on RSA, P-256 and P-384 keys; SHA-1 and MD5 signatures are refused, and RSASSA-PSS and Ed25519 are
reported as unsupported until their verifiers exist. RSA keys under 2048 bits and unusual EC curves in a leaf or an intermediate
are refused. Not done: revocation, certificate policies, the common name, the public suffix list, Ed25519/PSS signatures.

`abla/crypto/p384` has ECDSA verification on P-384 only (variable time, on public values), checked against Wycheproof's 504
secp384r1/SHA-384 vectors. Tests (`tools/test-x509.sh`): the chains committed in `tests/cases/x509/chains` (made with `openssl` by
`tools/gen-x509-fixtures.sh`: good RSA, P-256 and P-384 chains, expired, not yet valid, wrong name, wildcard and IP names, wrong
usage, missing intermediate, unknown root, self-signed, tampered signature, name constraints, path length, a CA that is not one,
an unknown critical extension), the system bundle's certificates, and [x509-limbo](https://github.com/C2SP/x509-limbo)'s 270 server
cases and every 25th of BetterTLS's 9,491 name-constraint cases (`tests/cases/x509/limbo`): the cases this code answers
differently from the suite are listed in `known.tsv` with the reason (CA/Browser Forum profile rules, key identifiers, policies,
the trust anchor's own fields, the public suffix list), and the test fails when one is missing from it or no longer differs.
