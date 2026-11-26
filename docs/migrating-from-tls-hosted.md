# Migrate from hosted TLS and crypto

`abla/tls/hosted` and `abla/crypto/hosted` have been removed. Change TLS imports to `abla/tls/pure`, the standard library’s only TLS implementation. For AES and RSA, use `abla/crypto/aes` and `abla/crypto/rsa`, or `abla/crypto/pure` to import both.

Use certificates with a matching DNS or IP subject alternative name. The pure TLS verifier refuses certificates that identify the host only in the Common Name. Use TLS 1.3 or [the supported TLS 1.2 subset](tls.md). Convert traditional OpenSSL encrypted PEM (`Proc-Type: 4,ENCRYPTED`) to encrypted PKCS#8 with `openssl pkcs8 -topk8 -v2 aes-256-cbc -in old-key.pem -out key.pem`. See [PKCS#12 client certificates](pkcs12-client-certificates.md) for supported bundles.

## TLS API

| Removed API | Replacement |
| --- | --- |
| `TlsConnection`, `TlsListener` | Import the corresponding resource types from `abla/tls/pure`. Check `handle == -1` for failure and call `descriptor()` to get the socket. Use `tlsFailedConnection()` for the old `TlsConnection(-1)` sentinel. |
| `TlsClientIdentity` | Use `TlsIdentity` from `abla/tls/pure/client`. Check `ok()` or `error`, and call `wipe()` when the identity is no longer needed. |
| `tlsAvailable`, `tlsLastError` | Keep the same calls. Use `tlsLastErrorTimedOut()` for timeout checks, or `connection.detail()` for the connection’s specific error. |
| `tlsClientIdentityFromPem`, `tlsClientIdentityFromPkcs12` | Keep the same calls. They now return `TlsIdentity`. |
| `tlsConnect`, `tlsConnectWithCa`, `tlsConnectWithIdentity` | Keep the same calls after changing the import. |
| `tlsUpgrade`, `tlsUpgradeWithIdentity`, `tlsServerUpgrade` | Keep the same calls for TCP and Unix streams. Pure server upgrades apply their explicit read/write timeout. Use `setTimeouts` after the upgrade if you need different read and write limits. |
| `tlsOpen` | Use `tlsConnectWithCa` for a CA file or `tlsConnect` for system trust, then `tlsRelease(move(connection))` if you need an integer handle. |
| `tlsUpgradeHandle` | Use `tlsUpgrade`, then `tlsRelease(move(connection))` if you need a handle. For an absolute deadline without a client identity, use `tlsPureUpgrade` in `abla/tls/pure/connection` with a verified client configuration, or drive `tlsSessionClient` from a poller with a deadline. |
| `tlsListen`, `tlsListenHandle` | Use `tlsListen` and keep the returned `TlsListener`. For client authentication, use `tlsListenWithClientCa`. |
| `TlsListener.localPort`, `TlsListener.accept`, `TlsListener.close` | Keep the same calls. |
| `TlsConnection.read`, `TlsConnection.write`, `TlsConnection.setTimeouts`, `TlsConnection.close` | Keep the same calls. With a released handle, use `tlsReadHandle`, `tlsWriteHandle`, `tlsSetTimeoutsHandle`, or `tlsCloseHandle`. |
| `tlsCloseHandle`, `TlsConnection(handle)` | Close a released handle with `tlsCloseHandle`, or take the connection back with `tlsClaim`. Keep each handle on one thread. |
| `tlsControlInt` | Use `descriptor()` to poll or configure the socket. Use `detach()` to take the socket and discard its TLS state. |
| `tlsControlPointer` | Use the typed API. For client auth use `tlsListenWithClientCa`; for peer identity use `peerCertificate()`, `peerChain()` and `peerCertificateVerified()`. OpenSSL context and session pointers have no replacement. |
| `hostedTlsErrorSlot`, `hostedTlsSetError`, `HostedTlsWait` | Use the connection’s timeout and error APIs. The implementation’s error slot and wait state have no replacement. |

For a nonblocking socket you already own, use `tlsSessionClient` or `tlsServerSession` and drive handshake and I/O readiness from your poller.

### Client

```abla
import "abla/tls/pure"

fun main: int {
    val connection = tlsConnect("example.com")
    if (connection.handle == -1) return 1
    return if (connection.write("GET / HTTP/1.0\r\nHost: example.com\r\n\r\n") > 0) 0 else 2
}
```

### Server

```abla
import "abla/tls/pure"

fun main: int {
    val listener = tlsListen("certificate.pem", "private-key.pem", "127.0.0.1", 8443)
    if (listener.handle == -1) return 1
    val connection = listener.accept()
    if (connection.handle == -1) return 2
    return if (connection.write("hello\n") == 6) 0 else 3
}
```

## Crypto API

| Removed API | Replacement |
| --- | --- |
| `opensslConstantTimeEquals` | `abla/crypto`’s `constantTimeEquals`. |
| `hostedAesEcbEncryptPkcs5`, `hostedAesEcbDecryptPkcs5` | `aesEcbEncryptPkcs5`, `aesEcbDecryptPkcs5` in `abla/crypto/aes`. Use ECB only for legacy interoperability. |
| `hostedAesCbcEncryptPkcs7`, `hostedAesCbcDecryptPkcs7` | `aesCbcEncryptPkcs7`, `aesCbcDecryptPkcs7`. Prefer authenticated encryption for new data. |
| `hostedAesGcmEncrypt`, `hostedAesGcmDecrypt` | `aesGcmEncrypt`, `aesGcmDecrypt`. For new code that manages its own envelope, consider `aesGcmSealRandom` and `aesGcmOpenRandom`. |
| `HostedRsaPrivateKey`, `HostedRsaPublicKey` | `RsaPrivateKey`, `RsaPublicKey` in `abla/crypto/rsa`. Check `ok()` after loading. |
| `hostedRsaGeneratePrivateKey` | `rsaGeneratePrivateKey`. |
| `hostedRsaPrivateKeyFromPem`, `hostedRsaPrivateKeyFromDer`, `hostedRsaPrivateKeyFromPkcs12` | `rsaPrivateKeyFromPem`, `rsaPrivateKeyFromDer`, `rsaPrivateKeyFromPkcs12`. For encrypted inputs, wrap the password with `cryptoPassword`. |
| `hostedRsaPublicKeyFromPem`, `hostedRsaPublicKeyFromDer`, `hostedRsaPublicKeyFromCertificateDer` | `rsaPublicKeyFromPem`, `rsaPublicKeyFromDer`, `rsaPublicKeyFromCertificateDer`. |
| `signPkcs1Sha256`, `verifyPkcs1Sha256`, `signPkcs1Sha1Legacy`, `verifyPkcs1Sha1Legacy` | Use the same methods on the pure key types. Keep SHA-1 for legacy interoperability only. |
| `encryptOaepSha256`, `decryptOaepSha256`, `encryptOaepSha1Legacy`, `decryptOaepSha1Legacy` | Use the same methods on the pure key types. Prefer the SHA-256 variants. |
| `encryptPkcs1Legacy`, `decryptPkcs1Legacy` | Use the same methods on the pure key types. Like OpenSSL 3.2 and later, bad padding can return deterministic substitute plaintext with `ok = true`. Validate the result in your protocol, or use OAEP. |
| Private key `toPkcs8Der`, `toPkcs8Pem` | Use the same methods on `RsaPrivateKey`. They export unencrypted key bytes. |
| Private or public key `toSpkiDer`, `toSpkiPem` | Keep an existing public key or certificate in SPKI form, or export SPKI with your key provisioning tool. The pure RSA API has no SPKI export method. |
| `CryptoResult`, `cryptoFailed` | Import `abla/crypto/result` directly or through the pure AES and RSA modules. |
