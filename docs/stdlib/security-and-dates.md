# Hashing, encoding and dates

| Import | What it gives you |
|---|---|
| `abla/crypto` | SHA-512, SHA-384, SHA-256, SHA-1, MD5, HMAC, PBKDF2, Base64, hexadecimal, constant-time comparison |
| `abla/crypto/aes`, `abla/crypto/rsa`, `abla/crypto/pure` | AES (GCM, CBC, ECB), RSA signing, verifying and encryption, key parsing: in Abla, on every target |
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
| Key bytes in Abla strings | none: strings can't be wiped | PEM text, passphrases and `secureRandomBytes` results stay in memory until it is reused. Read them late and don't keep them. Failed decryptions cleanse their buffer, and successful ones are the caller's |

Left out so far: RSA-PSS, RSA key generation, ECDSA signing, Ed25519, ChaCha20-Poly1305, HKDF,
SHA-3, SHA-224, CBC without padding, GCM with other nonce or tag sizes, and OAEP labels. Nothing here needs them
yet, and each is a short wrapper around OpenSSL when something does.

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
| `rsaPrivateKeyFromPem(pem)`, `rsaPrivateKeyFromDer(der)` | PKCS#8 and PKCS#1, unencrypted. Password-resource overloads read PBES2/PBKDF2/AES-CBC [encrypted PKCS#8](encrypted-keys.md); PKCS#12 remains hosted-only |
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

- On a hosted server with OpenSSL, for keys that matter: `abla/crypto/hosted`. It has more (decryption, encrypted
  keys, PKCS#12) and more scrutiny, and is about 14 times faster at signing. TLS stays on it.
- For embedded and Wasm, or where linking OpenSSL isn't wanted: these. Compared on an i9-13900K with 2048-bit
  keys, 2026-11-01: signing 5.1 ms (OpenSSL 0.36 ms); GCM 476 MiB/s with instructions and 34 MiB/s without (OpenSSL
  2700 MiB/s); ECB 2700 MiB/s and 130 MiB/s.

### How this is tested

`tools/test-crypto-pure.sh`: the NIST CAVP and Wycheproof vectors of `tools/test-crypto.sh` on both AES paths,
on this CPU and on `qemu-x86_64 -cpu qemu64` with neither instruction; refusals; random inputs against
`abla/crypto/hosted` and the `openssl` CLI, both ways. Known answers on AArch64 under qemu (with AES and PMULL) and
on Wasm under Node. On Xtensa it's compiled, and read by `tools/test-ct.sh`, not run. RSA decryption vectors run on the hosted native paths.

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
