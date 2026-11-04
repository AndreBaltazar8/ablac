# Encrypted RSA private keys

`abla/crypto/rsa` reads encrypted PKCS#8 (`BEGIN ENCRYPTED PRIVATE KEY`) without
OpenSSL. The supported encryption is PBES2 with PBKDF2-HMAC-SHA256 or
HMAC-SHA1 and AES-128-CBC or AES-256-CBC. An omitted PBKDF2 PRF means SHA1.
The optional derived-key length must match the selected cipher.

The original one-argument PEM/DER functions continue to read unencrypted PKCS#1
and PKCS#8. RSA-PSS is still hosted-only. An encrypted key requires the password
overload. Legacy PEM `Proc-Type`, PBES1, RC2 and DES/3DES are rejected explicitly;
the reader does not retry them through another implementation.

## Resource form

Create a `CryptoPassword` with `cryptoPassword(bytes)`, check `ok()`/`error()`,
and pass it by borrow. It can be reused until dropped. A direct
`CryptoPassword()` is an invalid owner; its memory is private.

```abla
import "abla/crypto/rsa"
import "abla/io"

fun openKey(pem: string, passwordText: string): RsaPrivateKey {
    val password = cryptoPassword(passwordText)
    rsaPrivateKeyFromPem(pem, password)
}

fun main(): int {
    val password = cryptoPassword("example-only-password")
    println(if (password.ok()) "owned password ready" else password.error())
    0
}
// output: owned password ready
```

The recommended resource form wipes **its own copied password** on drop.
**The caller's original password string cannot be wiped.** Do not log it or keep
unnecessary copies. Password bytes, including an empty password or embedded NUL,
are used as exact octets for PKCS#8. The factory accepts at most 1,024 bytes.

Both `rsaPrivateKeyFromPem(pem, password, limits)` and
`rsaPrivateKeyFromDer(der, password, limits)` return the usual affine
`RsaPrivateKey`; inspect `ok()` and `error`. Derived keys, HMAC pads/digests and
hash states stay in wiped native scratch rather than managed strings. AES key
schedules are wiped too, using volatile stores. Decrypted DER still passes
through the existing string-based RSA parser and cannot be wiped; neither can
copies the caller made before importing a password.

## Bounds and compatibility

`RsaKeyReadLimits` defaults/hard maxima are:

| Parameter | Default / maximum |
| --- | ---: |
| `maximumIterations` | 1,000,000 |
| `maximumKdfWork` (hash compression blocks, shared across a read) | 8,000,000 |
| `maximumDerBytes` | 1,048,576 |
| `maximumPemBytes` | 2,097,152 |
| `maximumSaltBytes` | 1,024 |
| `maximumDepth` | 8 |
| `maximumBags` | 64 |

Callers may lower these limits. Zero is permitted only for the salt byte cap;
other nonpositive limits, or limits above the hard maxima, are invalid. The
iteration value is checked as a bounded positive DER integer before starting
any derivation. An overflow, zero, negative value or excessive count fails.
Decrypted private-integer widths are also bounded before CRT arithmetic (within
the existing 16,384-bit RSA boundary). The aggregate work budget also counts password normalization and HMAC setup;
raising an iteration count cannot bypass it by requesting many output blocks.

**Low positive counts, including one, are accepted without warnings** for
compatibility reads. Acceptance is not a recommendation for newly protected
keys. This API imports existing keys; it does not create encrypted exports.

Malformed public parameters, unsupported algorithms and exceeded limits have
named errors. Wrong passwords, CBC padding failures and decrypted DER failures
converge on the same `wrong password or corrupt key` result. PBES2-CBC itself
has no authentication. This key-file loader is not an authenticated encryption
protocol, and its complete execution time is not claimed to be constant-time.

## PKCS#12 key bags

`rsaPrivateKeyFromPkcs12(der, password, limits)` reads DER PFXv3 using the same
`CryptoPassword` resource and limits. It requires a SHA256 or SHA1 `MacData`
and verifies it **before traversing or decrypting any bag**. The MAC key uses
RFC7292 Appendix B (diversifier 3); PBES2 encryption uses PBKDF2 as above.
The work budget is shared by MAC verification and every encrypted safe or key.

```abla
import "abla/crypto/rsa"
import "abla/io"

fun readPfx(der: string, passwordText: string): RsaPrivateKey {
    val password = cryptoPassword(passwordText)
    rsaPrivateKeyFromPkcs12(der, password)
}

fun main(): int {
    val password = cryptoPassword("example-only-password")
    val key = rsaPrivateKeyFromPkcs12("", password)
    println(if (key.ok()) "key read" else "invalid container rejected")
    0
}
// output: invalid container rejected
```

Supported contents are `data`, PBES2 `EncryptedData`, plain PKCS#8 `keyBag`,
PBES2 `pkcs8ShroudedKeyBag`, and bounded nested `safeContentsBag`. Exactly one
private key is required. X.509 certificate bags and attributes are structurally
checked and ignored: this API neither selects a certificate identity nor makes
any trust decision. `maximumBags` bounds both bags across nested contents and
the number of outer content records. `maximumDepth` also bounds constructed
attribute nesting. A normal OpenSSL `pkcs12 -export` is supported.

PKCS#12 passwords must be valid UTF-8 text in the BMP, without embedded NUL;
the empty password is supported. The factory also creates and wipes its own
big-endian UTF-16 copy with its terminating zero. That text conversion is an
explicit **variable-time import boundary**, outside the cryptographic cores.
Invalid UTF-8, non-BMP characters and NUL are rejected for PKCS#12, while the
same owner still permits exact-octet PKCS#8 use. Containers with separate MAC
and encryption passwords are unsupported. The same password must protect both.

Missing MACs, PBMAC1, signed/enveloped integrity, non-DER/indefinite encodings,
unknown bag kinds and legacy PBES1/RC2/DES/3DES encryption are rejected with
named errors. A valid MAC does not change the CBC caveat above: this is a
bounded key-file importer, not a new authenticated-encryption protocol.
Wrong passwords, bad padding and decrypted-key DER errors still share the
same `wrong password or corrupt key` result. No alternate password encoding or
legacy cipher is retried after failure.

## Timing and portability

The new cryptographic cores use `secretU8`/`secretU32` for password/key bytes,
SHA1/SHA256 state, HMAC and PBKDF2 arithmetic. Their memory indexes, block counts,
algorithm choices and iteration counts depend on public metadata and lengths.
The existing string-based `pbkdf2Sha256`/HMAC APIs are unchanged and have not been
relabeled as secret APIs. ASN.1 parsing and final validity decisions remain
outside the constant-time claim. See [the timing limits](../constant-time.md).

Targeted assembly checks cover SHA schedules/rounds, HMAC digest blocks,
password-pad construction, MAC comparison and PBKDF2 accumulation on x86-64, AArch64, Wasm and
Xtensa, with deliberate leak controls. Primitive known answers run on native,
AArch64 under QEMU and Wasm, including an end-to-end PKCS#12 key read. This is assembly analysis, not a statistical timing
study or a promise about every CPU or Wasm engine.

Fixtures in `tests/vectors/crypto/encrypted-rsa` use an already-public test key,
explicit test-only passwords, and the recorded OpenSSL regeneration script.
Standards: [PBKDF2 and PBES2](https://www.rfc-editor.org/rfc/rfc8018.html),
[PKCS#12](https://www.rfc-editor.org/rfc/rfc7292.html).
