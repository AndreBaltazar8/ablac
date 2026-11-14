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

The system trust store is `NIX_SSL_CERT_FILE` or `SSL_CERT_FILE` if set, else `SSL_CERT_DIR` if set (a variable that is set is the whole trust, see below), else the first
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

## Together with `abla/tls/hosted`

`abla/http/tls`, `abla/websocket/tls` and the Xtensa installer import `abla/tls/pure` under an alias, so a program
that imports `abla/tls/hosted` itself (for OpenSSL's handles and internals: `tlsControlPointer`, `tlsAllocateConnection`,
`TlsConnection(handle)` views of a handle, as NovaKind's abla-s3 and abla-postgres do) and also imports `abla/http` compiles
and runs: the two modules' public names do not collide, because the pure ones are reached through the alias inside the
stdlib. A program that imports `abla/tls/pure` directly and `abla/tls/hosted` in the same program gets a name clash and
must alias one of them. (A type that the stdlib hands out, such as `TlsWebSocketConnection.stream`, is the pure module's
`TlsConnection`.)

## Checks that refuse by default

- An empty host name is refused (`TLS failed at configuration`) by `tlsConnect*` and `tlsUpgrade*`, and by the verifier
  (`tlsVerifyServerCertificate` takes `allowAnyHost = true` for the caller that really wants a certificate for any name):
  `abla/crypto/x509` reads an empty name as "do not check the name".
- A handshake message is capped by its type as soon as its four-byte header arrives, before the body is buffered: hellos
  at 2^17 bytes, a Certificate at 2^16, anything else at 2^14; a peer that declares more is sent `illegal_parameter`.
  Fragments are joined once, when a message is whole.
- If `NIX_SSL_CERT_FILE`, `SSL_CERT_FILE` or `SSL_CERT_DIR` is set, it is the whole trust: a missing file or one with no
  certificate, an empty directory, or the variable set to nothing (`SSL_CERT_FILE=`, as OpenSSL reads it) gives a store in
  which nothing verifies, not the system bundle (`tools/test-tls-trust-env.sh`).

## One certificate for several protocols (ALPACA)

A certificate that is valid for a host name is valid for every service on that name. A client that is tricked into a
connection to the wrong one (a browser sent to an FTP or SMTP port) can have the TLS handshake succeed and its requests
read as the other protocol (the ALPACA attacks). `abla/tls/pure` does not select a certificate by server name, and a
server whose `alpn` is `[]` accepts any client. A server that shares one certificate (or a wildcard) across protocols
must set `alpn` to the protocols it speaks: then a client that offers protocols and none of them match is refused with
`no_application_protocol`, (a client that offers no ALPN at all is still accepted:
require ALPN in the application if that matters). A client that sends ALPN refuses a server's answer that it did not offer.

## Secrets in memory

The client and server clear each secret they made once nothing reads it again (overwritten with zeros, by volatile
stores): their key shares once the shared secret is made (and the first share when a HelloRetryRequest replaces it), the
shared secret and the early, handshake and master secrets once the handshake keys and the application secrets are made,
the handshake traffic secrets and keys after the Finished messages, an old traffic secret and its keys at each KeyUpdate,
and everything left when the connection closes, fails or is detached (`detach()`). In TLS 1.2: the ephemeral key and the premaster secret once
the master secret is made, the master secret after the Finished messages, the key block at the end. An identity holds
its key bytes in `secrets`; `TlsIdentity.wipe()` clears them, after which it signs nothing: `tlsServerUpgrade` does it
for the identity it loaded once the handshake is over, and a listener for its own when it closes or is dropped. An
identity the program made and passed in is the program's to wipe. Key pairs given to `tlsClientStartWith` are copied, and
the copies cleared.

What this does not reach: copies that HMAC and HKDF make inside a call (the padded key, intermediate blocks), what the
AEADs and signers already wipe themselves aside, a string the program passed in, and copies an earlier collection or a
large string's rope left behind. (A string shares its bytes with its slices, so only strings the TLS code made itself are
cleared, and only once their last reader is done.) `tests/cases/tls-pure/wipe.ab` checks each of these points.

## Layers

`abla/tls/pure/keysched`, `record`, `handshake`, `tls12`, `client` and `server` are sans-IO: bytes in with `feed`,
bytes out with `takeOutput`, so they can run over any transport and are tested against the RFC 8448 traces without a
socket. `connection` drives them over a TCP or Unix socket; `verify` is the certificate check; `identity` loads client
certificates and keys. Tests: `tools/test-tls-pure.sh` (RFC 8448 sections 3, 5, 6 and 7 byte for byte, fuzzed input) and
`tools/test-tls-pure-interop.sh` (live handshakes against `openssl s_server` and `openssl s_client` for every certificate
type, suite, group and TLS version, mutual TLS, ALPN, Unix sockets, a 6 MB transfer). Hardening:
`tools/test-tls-fuzz.sh` (a client and a server with an attacker between them that changes one handshake record per run:
harmless changes must still connect, harmful ones must not, none may be slow), `tools/test-crypto-pure.sh` (Wycheproof for
every primitive TLS uses) and, opt-in, `tools/test-tls-bogo.sh` (BoringSSL's BoGo suite through `tools/tls-bogo/shim.ab`,
the runner fetched at a pinned commit; needs Go and network access; `tools/tls-bogo/expected-failures.txt` is the
list of what fails today and why).

## TlsSession: a client over a socket you poll yourself

`abla/tls/pure` also has `TlsSession`, for a program that owns the descriptor and its event loop (a database
driver that has done its own plaintext exchange on the socket first, such as PostgreSQL's SSLRequest). Nothing in it
blocks or sets a timeout; it tells you what it needs from the socket:

```abla build
import "abla/sys/linux/net"
import "abla/tls/pure"

// `descriptor`: a connected, non-blocking TCP socket (here the caller made it; a driver would hand over the one it used
// for its own plaintext exchange). The poll is your event loop's.
fun handshakeOn(descriptor: int): bool {
    val session = tlsSessionClient(descriptor, "db.example.com", TLS_VERIFY_HOST, "")
    var status = session.handshake()
    while (status == TLS_IO_WANT_READ || status == TLS_IO_WANT_WRITE) {
        linuxPollSocket(descriptor, status == TLS_IO_WANT_READ, status == TLS_IO_WANT_WRITE, 5000)
        status = session.handshake()
    }
    // status 1: connected; -1: failed, session.detail() says why.
    status == 1
}

fun main: int {
    val socket = tcpConnectIpv6(ipv6Loopback(5432), 1000)
    if (socket.descriptor < 0) return 1
    socket.setNonblocking(true)
    if (handshakeOn(socket.descriptor)) 0 else 1
}
```

- `handshake()` returns 1 (done), 2 (wait for the socket to be readable), 3 (writable) or -1.
- `readReady(max)` returns a `TlsIo`: status 1 with `bytes`, 2/3 as above, 0 when the peer closed the stream cleanly, -1.
- `writeReady(bytes, offset)` takes at most 16 KiB from `offset` and reports `written` only when those bytes are through to
  the socket; on 3, call again with the same arguments once the socket is writable. A write never raises SIGPIPE.
- `close()` sends close_notify once without blocking and shuts the connection down; the descriptor stays yours.
- Verification: `TLS_VERIFY_NONE` encrypts only (the handshake signature is still checked), `TLS_VERIFY_CHAIN` requires a
  chain to a root in `caPath` ("" or "system": the system bundle, or what `SSL_CERT_FILE` names), `TLS_VERIFY_HOST` also
  requires the host (a DNS name, or an IP address matched against the certificate's IP entries). The server name is sent in
  every mode unless the host is an IP address. A CN without a subjectAltName is not accepted in any host check.
