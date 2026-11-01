# Hashing, encoding and dates

| Import | What it gives you |
|---|---|
| `abla/crypto` | SHA-512, SHA-384, SHA-256, SHA-1, MD5, HMAC, PBKDF2, Base64, hexadecimal, constant-time comparison |
| `abla/crypto/hosted` | AES (GCM, CBC, ECB), RSA signatures and encryption, key parsing: through OpenSSL |
| `abla/random` | a cryptographically secure source (`getrandom(2)`) |
| `abla/date` | UTC calendar dates, ISO 8601 and HTTP dates |
| `abla/jwt`, `abla/jwt/remote` | JSON Web Token verification ([networking.md](../networking.md)) |

`abla/crypto` and `abla/date` are pure Abla: they work on every target and at compile
time. `abla/crypto/hosted` is OpenSSL, and links it into the programs that import it.

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
Where OpenSSL is missing (embedded targets, wasm) there is no AES or RSA in the
standard library: see [why](#why-not-in-abla).

```abla
import "abla/io"
import "abla/crypto"
import "abla/crypto/hosted"
import "abla/random"

fun main {
    val key = secureRandomBytes(32)
    val nonce = secureRandomBytes(12)
    val sealed = aesGcmEncrypt(key.bytes, nonce.bytes, "a message", "its context")
    val opened = aesGcmDecrypt(key.bytes, nonce.bytes, sealed.bytes, "its context")
    println("${sealed.bytes.size} ${opened.bytes}")
    println(aesGcmDecrypt(key.bytes, nonce.bytes, sealed.bytes, "another").error)
    val ecb = aesEcbEncryptPkcs5("0123456789abcdef", "hello")
    println(hexEncode(ecb.bytes))
    val none = rsaPrivateKeyFromPem("not a key")
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
| `aesGcmEncrypt(key, nonce, plaintext, associatedData = "")`, `aesGcmDecrypt(key, nonce, ciphertext, associatedData = "")` | use this one. The result is the ciphertext and then a 16-byte tag; decryption returns nothing unless the tag verifies. The nonce has 12 bytes and must never repeat under a key |
| `aesCbcEncryptPkcs7(key, iv, plaintext)`, `aesCbcDecryptPkcs7(key, iv, ciphertext)` | unauthenticated. The IV has 16 unpredictable bytes. Bad padding is a distinct failure, so never show a remote party which failure happened (a padding oracle): pair it with a MAC checked first |
| `aesEcbEncryptPkcs5(key, plaintext)`, `aesEcbDecryptPkcs5(key, ciphertext)` | **for protocols that require it only**, such as Portugal's AT WS-Security header. Equal blocks encrypt equally |

Keys have 16, 24 or 32 bytes. For a 16-byte block, PKCS#5 and PKCS#7 padding are the same.

### RSA

Load a key, check `ok()` or `error`, and call its methods. A key is a resource: OpenSSL's
copy is freed and cleansed when it's dropped.

| Function | Reads |
|---|---|
| `rsaPrivateKeyFromPem(pem, passphrase = "")` | PKCS#8, encrypted PKCS#8, PKCS#1. An encrypted key without its passphrase fails; it never asks on the terminal |
| `rsaPrivateKeyFromDer(der)` | unencrypted PKCS#8 or PKCS#1 |
| `rsaPrivateKeyFromPkcs12(der, password)` | a `.pfx`. OpenSSL 3 refuses RC2 (what OpenSSL 1.x's `pkcs12 -export` writes) unless re-encrypted: `openssl pkcs12 -in old.pfx -legacy -nodes \| openssl pkcs12 -export -out new.pfx` |
| `rsaPublicKeyFromPem(pem)` | `PUBLIC KEY` (SubjectPublicKeyInfo), `RSA PUBLIC KEY`, or the key of a `CERTIFICATE`. The certificate's chain and dates aren't checked |
| `rsaPublicKeyFromDer(der)`, `rsaPublicKeyFromCertificateDer(der)` | SubjectPublicKeyInfo; an X.509 certificate's key |

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

### Why not in Abla

AES written in Abla would use table lookups indexed by key bytes, which leak through the
cache, and RSA would need big-number code that doesn't branch or index on secret bits,
through a code generator that promises nothing about either. `abla-saft` and `abla-pdf` carry such RSA for themselves, documented as not
hardened. SHA-512 and the HMACs are in Abla because they have no such tables, and so
they run at compile time and on every target, as the older hashes do.

Left out so far: RSA-PSS, RSA key generation, ECDSA signing, Ed25519, ChaCha20-Poly1305, HKDF,
SHA-3, SHA-224, CBC without padding, GCM with other nonce or tag sizes, and OAEP labels. Nothing here needs them
yet, and each is a short wrapper around OpenSSL when something does.

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
