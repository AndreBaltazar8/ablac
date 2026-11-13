# TLS in Abla (`abla/tls/pure`)

`abla/tls/pure` is TLS written in Abla: a client and a server for TLS 1.3 and for TLS 1.2 in a modern subset, with
X.509 verification, over the sockets of `abla/sys/linux/net`. It needs no OpenSSL and no libc. `abla/http/tls`,
`abla/websocket/tls` and the Xtensa installer's HTTPS stream use it, so a program that opens HTTPS connections links
as a static, libc-free executable. `abla/tls/hosted` (OpenSSL) remains for the server modules that still import it
(`abla/websocket/server/tls`) and for the flat host API (`abla/platform/host/tls`).

The module has the calls of `abla/tls/hosted`: `tlsConnect`, `tlsConnectWithCa`, `tlsConnectWithIdentity`,
`tlsUpgrade` and `tlsUpgradeWithIdentity` (TCP and Unix sockets), `tlsListen`, `TlsListener.accept`,
`tlsServerUpgrade`, `TlsConnection` (`handle`, `read`, `write`, `setTimeouts`, `close`), `tlsLastError`,
`tlsAvailable`, `tlsClientIdentityFromPem` and `tlsClientIdentityFromPkcs12`, with the same meanings (end of stream is
an empty read with an empty `tlsLastError`; a timed-out read can be repeated; a failed connection has `handle == -1`).
`TlsConnection.detail()` gives the specific reason of the last failure.

## What is supported

| | |
|---|---|
| Versions | TLS 1.3 (RFC 8446) and TLS 1.2 (RFC 5246) in the subset below. One ClientHello offers both; a server answers with the best. |
| TLS 1.3 suites | `TLS_AES_128_GCM_SHA256`, `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256` |
| TLS 1.2 suites | `TLS_ECDHE_{ECDSA,RSA}_WITH_AES_128_GCM_SHA256`, `..._AES_256_GCM_SHA384`, `..._CHACHA20_POLY1305_SHA256` |
| Key exchange | X25519 and secp256r1 (P-256); a HelloRetryRequest when the server wants a group the client has no share for |
| Signatures | ECDSA P-256 (SHA-256), ECDSA P-384 (SHA-384, TLS 1.3 only), RSA-PSS (rsae, SHA-256/384/512), Ed25519; RSA PKCS#1 v1.5 (SHA-256/384) in TLS 1.2 only |
| Certificates | X.509 chains to the system trust store or a CA file, with name, validity, key-usage, basic-constraints, name-constraints and signature checks (`abla/crypto/x509`); client certificates (RSA, P-256, Ed25519) from PEM (PKCS#8, PKCS#1, SEC1, encrypted PKCS#8) or PKCS#12 (PBES2) |
| Other | ALPN, SNI, KeyUpdate, close_notify, middlebox-compatibility ChangeCipherSpec, the TLS 1.3 downgrade sentinel, deadlines |

The system trust store is `NIX_SSL_CERT_FILE` or `SSL_CERT_FILE` if set, else `SSL_CERT_DIR` if set, else the first
bundle found among the usual system locations; it is read when the server's certificate arrives, not when the
connection starts.

## What is refused

CBC suites, RSA key exchange, static or finite-field Diffie-Hellman, RC4, 3DES and every non-AEAD cipher; SSL 3.0, TLS
1.0 and 1.1; renegotiation (a HelloRequest after the handshake ends the connection); compression; a TLS 1.2 peer that
does not support the extended master secret (RFC 7627) or secure renegotiation info; 0-RTT early data; session
resumption and tickets (the server sends none, the client ignores them); a certificate that matches the host only by
its Common Name (a subjectAltName is required, RFC 6125); TLS 1.2 with a P-384 *certificate* (a TLS 1.2 server needs
the certificate's curve among the client's groups and there is no P-384 key exchange to offer; TLS 1.3 has no such rule
and works); RSA keys under 2048 bits for PSS verification.

## Differences from the OpenSSL-backed module

- The certificate's host name must be in its subjectAltName (no Common Name fallback).
- Legacy encrypted PEM private keys (`Proc-Type: 4,ENCRYPTED`) are not read; encrypted PKCS#8 is.
- PKCS#12 containers must use PBES2 and a SHA-1 or SHA-256 MAC (what OpenSSL 3 and current tools write), not the
  RC2/3DES-era PKCS#12 key derivation.
- Speed: an RSA-2048 signature (a server with an RSA certificate, or a client certificate) takes about 8 ms in a release
  build and about 300 ms in a `--fast` build; ECDSA and Ed25519 are far cheaper. Parsing a system bundle of 145
  certificates takes about 6 ms in a release build and 90 ms in a `--fast` build.
- Server side: one certificate, no SNI selection.

## Layers

`abla/tls/pure/keysched`, `record`, `handshake`, `tls12`, `client` and `server` are sans-IO: bytes in with `feed`,
bytes out with `takeOutput`, so they can run over any transport and are tested against the RFC 8448 traces without a
socket. `connection` drives them over a TCP or Unix socket; `verify` is the certificate check; `identity` loads client
certificates and keys. Tests: `tools/test-tls-pure.sh` (RFC 8448 sections 3, 5, 6 and 7 byte for byte, fuzzed input) and
`tools/test-tls-pure-interop.sh` (live handshakes against `openssl s_server` and `openssl s_client` for every certificate
type, suite, group and TLS version, mutual TLS, ALPN, Unix sockets, a 6 MB transfer).
