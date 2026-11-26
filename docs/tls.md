# TLS in Abla (`abla/tls/pure`)

`abla/tls/pure` is TLS written in Abla: a client and a server for TLS 1.3 and for TLS 1.2 in a modern subset, with
X.509 verification, over the sockets of `abla/sys/linux/net`. It needs no OpenSSL and no libc. `abla/http/tls`,
`abla/websocket/tls` and the Xtensa installer's HTTPS stream use it, so a program that opens HTTPS connections links
as a static, libc-free executable. `abla/websocket/server/tls` is pure too. `abla/tls/hosted` (OpenSSL) remains only for programs that import it
themselves (OpenSSL's handles and internals); such a program links libc. The flat host API (`abla/platform/host/tls`, which the compiler's compile-time evaluator
uses) is over `abla/tls/pure` too: the compiler imports no libssl or libcrypto.

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
| Key exchange | TLS 1.3: X25519MLKEM768 (the hybrid of X25519 and ML-KEM-768, draft-ietf-tls-ecdhe-mlkem; what browsers offer first), X25519, secp256r1 (P-256), secp384r1 (P-384); TLS 1.2: the three classic groups. A HelloRetryRequest when the server wants a group the client has no share for. A client sends shares for the first classical group and the first hybrid of its list (`TlsClientConfig.groups`; by default X25519 and the hybrid: BoringSSL's and the browsers' rule), a server prefers its own `groups` order (the default is the hybrid first) |
| Signatures | ECDSA P-256 (SHA-256), ECDSA P-384 (SHA-384, TLS 1.3 and 1.2), RSA-PSS (rsae, SHA-256/384/512), Ed25519; RSA PKCS#1 v1.5 (SHA-256/384) in TLS 1.2 only |
| Certificates | X.509 chains to the system trust store or a CA file, with name, validity, key-usage, basic-constraints, name-constraints and signature checks (`abla/crypto/x509`); client certificates (RSA, P-256, P-384, Ed25519) from PEM (PKCS#8, PKCS#1, SEC1, encrypted PKCS#8) or PKCS#12 (PBES2 with AES or 3DES, and the legacy RC2/3DES encodings, read only: see [PKCS#12 client certificates](pkcs12-client-certificates.md)) |
| Other | ALPN, SNI, KeyUpdate, close_notify, middlebox-compatibility ChangeCipherSpec, the TLS 1.3 downgrade sentinel, deadlines |

The system trust store is `NIX_SSL_CERT_FILE` or `SSL_CERT_FILE` if set, else `SSL_CERT_DIR` if set (a variable that is set is the whole trust, see below), else the first
bundle found among the usual system locations; it is read when the server's certificate arrives, not when the
connection starts.

## What is refused

CBC suites, RSA key exchange, static or finite-field Diffie-Hellman, RC4, 3DES and every non-AEAD cipher; SSL 3.0, TLS
1.0 and 1.1; renegotiation (a HelloRequest after the handshake ends the connection); compression; a TLS 1.2 peer that
does not support the extended master secret (RFC 7627) or secure renegotiation info;
TLS 1.2 session resumption (ids or tickets); 0-RTT early data; a certificate that matches the host only by
its Common Name (a subjectAltName is required, RFC 6125);
RSA keys under 2048 bits for PSS verification.

## Differences from the OpenSSL-backed module

- The certificate's host name must be in its subjectAltName (no Common Name fallback).
- Legacy encrypted PEM private keys (`Proc-Type: 4,ENCRYPTED`) are not read; encrypted PKCS#8 is.
- PKCS#12 containers are read in the encodings that real tools write: PBES2 (AES-128/192/256, 3DES) and the RC2/3DES
  PKCS#12 key derivation of OpenSSL 1.x, Windows, macOS and Java 8, with a SHA-1 or SHA-256 MAC (read only; our writers use
  PBES2). A MAC is required, and RC4, single DES, SHA-224/384/512 and PBMAC1 MACs are refused:
  [PKCS#12 client certificates](pkcs12-client-certificates.md).
- Speed: an RSA-2048 signature (a server with an RSA certificate, or a client certificate) takes about 8 ms in a release
  build and about 300 ms in a `--fast` build; ECDSA and Ed25519 are far cheaper. Parsing a system bundle of 145
  certificates takes about 6 ms in a release build and 90 ms in a `--fast` build.
- Server side: one certificate by default; several are chosen by server name and signature algorithms (below).

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

## Several certificates: SNI and signature algorithms

A server has one certificate unless it is given more: `tlsServerConfigFromPems([TlsServerPem(certificatePem, privateKeyPem, names), ...])`
(or `tlsServerConfigWithIdentities(config, identityNames, identities)` over identities already loaded) makes a configuration that picks a
certificate for each ClientHello, from the server name (SNI, RFC 6066) the client sent and the signature algorithms it accepts. `names` are exact host
names (compared without case or a final dot) or `*.example.com` (exactly one label: `a.example.com`, not `example.com` or `a.b.example.com`); `[]` is any
name. The rule, in order: among the certificates whose names match the client's name, the first (the first entry, then the others in the given order) that
can sign with a scheme the client lists (on TLS 1.2 also with a cipher suite of its key type and, for ECDSA, a curve the client lists); else, when the name
matches a certificate the client cannot use, that certificate (the handshake then fails with `handshake_failure`, as with one certificate); else, for a name
nothing matches or a client without a name, the first certificate the client can use. The first entry is therefore the default. To serve one name with an
ECDSA and an RSA certificate, give both the name and put the ECDSA one first: a client that takes ECDSA gets it, a client that lists only RSA schemes gets RSA.
A server never refuses a name it does not know (no `unrecognized_name` alert): it answers with the default certificate, whose name the client then
checks. A resumed session sends no certificate; its ticket is bound to the server name. With the one `identity` (no list) nothing is chosen and the server's
bytes are as they were before this existed (`tests/cases/tls-pure/sni.ab` compares them).
`httpsEventServerTlsPems` and `webSocketServerTlsPems` take the same list for `HttpsEventServer`, `H2Server` and `WebSocketServer`.

## One certificate for several protocols (ALPACA)

A certificate that is valid for a host name is valid for every service on that name. A client that is tricked into a
connection to the wrong one (a browser sent to an FTP or SMTP port) can have the TLS handshake succeed and its requests
read as the other protocol (the ALPACA attacks). `abla/tls/pure` serves the one certificate unless given several (above), and a
server whose `alpn` is `[]` accepts any client. A server that shares one certificate (or a wildcard) across protocols
must set `alpn` to the protocols it speaks: then a client that offers protocols and none of them match is refused with
`no_application_protocol`, (a client that offers no ALPN at all is still accepted:
require ALPN in the application if that matters). A client that sends ALPN refuses a server's answer that it did not offer.
A session client offers protocols with `tlsSessionClient(descriptor, host, mode, caPath, sessions, alpn)` (for example `["h2", "http/1.1"]`; `abla/http/async` does this for
`HttpAsyncOptions.http2`) and reads the server's choice with `TlsSession.alpn()` once the handshake is done ("" if none). A server offers its list with `tlsServerConfigWithAlpn(config, alpn)` and
reads the client's pick with `TlsServerSession.alpn()` (`abla/http/event/tls` serves `h2` and `http/1.1` this way).

## Key exchange groups and the hybrid X25519MLKEM768

The default client offers `X25519MLKEM768`, `x25519`, `secp256r1`, `secp384r1` in that order and sends key shares for the first
(1216 bytes: the ML-KEM-768 encapsulation key, then the X25519 key) and for X25519, as browsers do, so a server without the hybrid
answers with no extra round trip; a server that wants P-256 or P-384 gets a HelloRetryRequest answered. `TlsClientConfig.groups`
changes the list and the order (shares go to the first classical group and the first hybrid of the list; a TLS 1.2-only client lists no hybrid). The default server prefers the hybrid, then X25519, P-256 and P-384
(`TlsServerConfig.groups` is its order); it answers a hybrid share with the ML-KEM ciphertext and its X25519 key (1120 bytes) and
a client share it cannot use with a HelloRetryRequest.

The hybrid follows draft-ietf-tls-ecdhe-mlkem section 4: the ML-KEM part comes first in the key shares and in the shared
secret (4.1: the order is the reverse of the group name's, "for historical reasons"; 4.2; 4.3: the secret is the ML-KEM secret, then
X25519's, 64 bytes). The server checks the client's encapsulation key (FIPS 203 section 7.2) and the X25519 part (the all-zero
check, RFC 8446 section 7.4.2) and sends `illegal_parameter` if either fails; the client checks the share's length
(`illegal_parameter`) and the X25519 part. A ciphertext that was not made for the client's key is not an error at that point
(ML-KEM's implicit rejection): the keys differ and the handshake fails at the first protected record, so a bad ciphertext does not
tell a server whether it decapsulated. The hybrid is a TLS 1.3 group only: a TLS 1.2 server never selects it, and a TLS 1.2
client refuses a ServerKeyExchange for it. P-384 works as an ECDHE group in both versions, and as a certificate key (ECDSA with SHA-384,
RFC 6979 nonces: `p384EcdsaSign`; a server identity can be a P-384 key, in PKCS#8, SEC1 or PKCS#12). In TLS 1.2 the group list also names the curves of
the certificates a client accepts (RFC 8422 section 5.1.1): a client refuses an EC certificate whose curve it did not list (`bad_certificate`), and a
server with a P-256 or P-384 key does not serve a TLS 1.2 client that lists no such curve (`handshake_failure`); TLS 1.3 has no such rule.

## Revocation by OCSP stapling (client side, on by default since v0.2.70)

The pure TLS client checks OCSP staples by default (v0.2.68 and v0.2.69 had it opt in). Every stock client of `abla/tls/pure` does: `tlsConnect` and its relatives (`tlsConnectWithCa`,
`tlsConnectWithIdentity`, the upgrade functions), `tlsSessionClient` with `TLS_VERIFY_HOST` (the asynchronous HTTP client), and so the HTTPS clients and the WebSocket TLS client built on them. Their ClientHello offers
`status_request`, and a staple the server sends is judged after the chain verifies, against the same trust store; **a server that sends no staple connects as before** (policy 1, `OCSP_POLICY_STAPLE`). What a
caller can newly see: a handshake that ends with `certificate_revoked` (the staple says the certificate is revoked), `bad_certificate_status_response` (a staple that is for another certificate, not signed by the
issuer or an authorized responder, not fresh, or valid for more than ten days), or `bad_certificate` (the certificate is must-staple and the server sent none); `tlsLastError()` says "TLS failed at certificate_verification" for all of them.
A server that staples a stale or wrong response, which a client without the check connected to, is now refused: the server's operator refreshes the staple.

To opt out, or to require a staple, build the configuration: `TlsClientConfig.revocation` is the policy (1 staple, 2 require, 0 off: no `status_request`, a staple is not looked at, as in v0.2.69), and
`tlsClientConfigWithRevocation(config, policy, tlsOcspVerifier(store, host, now, policy))` sets it with its verifier (`tlsOcspVerifierLazy` takes the store when the staples arrive). The setting takes effect only with a staple
verifier: a configuration made by hand with its own `verifier` has none and checks nothing until it is given one. The hosted (OpenSSL) client, which a program built for a platform with its own TLS library uses, has no revocation
setting: the default covers the pure client only. The ClientHello is 9 bytes longer (the extension). A handshake with a server that sends no staple costs nothing measurable; one that staples costs about 0.4 ms more (the response's signature check and parse: 1.7 to 2.1 ms in a release build, one core, local server).

How it works. The ClientHello offers `status_request`; a server that staples an OCSP response (TLS 1.3: in the Certificate entry; TLS 1.2: a CertificateStatus message the
ServerHello promised) has it judged by `abla/crypto/ocsp` after the chain and the signature have verified: the response must be for that certificate, signed by its issuer or by a
certificate the issuer authorized to sign OCSP responses, and fresh (a nextUpdate that has not passed and at most ten days after thisUpdate, the Baseline Requirements' limit). `OCSP_POLICY_STAPLE` (1) uses a
staple when there is one: a revoked certificate ends the handshake with `certificate_revoked`, an invalid or expired staple with `bad_certificate_status_response`, no staple is accepted,
unless the certificate is must-staple (RFC 7633: the TLS Feature extension lists status_request), which is then refused. `OCSP_POLICY_REQUIRE` (2) refuses a certificate without a good staple.
Nothing is fetched: a client that wants a response of its own gets one from the certificate's responder with `ocspRequestDer` and `ocspCheck`. Limits: a man in the middle can strip
the staple, which policy 1 accepts (policy 2 and must-staple close that); a revoked certificate stays acceptable until the staple the server holds expires; a resumed TLS 1.3 session is not
checked again (it skips the Certificate); CRLs are not read. The server side (sending a staple) is not implemented. The design is `docs/design/ocsp-stapling.md`.

## Session resumption (TLS 1.3 tickets)

PSK resumption with tickets, `psk_dhe_ke` only (a fresh key exchange every time, so a resumed session keeps forward secrecy), no 0-RTT early data
(RFC 8446 sections 2.2, 4.2.11 and 4.6.1). A resumed handshake sends no Certificate: it saves the signature, the chain and its verification.

- **Server:** give `TlsServerConfig.tickets` a `tlsTicketKeysNew(random, now, lifetime, count, rotateAfter)` (`abla/tls/pure/resume`). The server keeps no state:
  a NewSessionTicket carries the session's PSK sealed under a ticket key (AES-256-GCM, the key's name as associated data), with the suite, the time it was
  issued, the ticket_age_add, the ALPN protocol and the server name. A ticket resumes only for the same server name and cipher suite (not the same ALPN protocol: ALPN belongs to the connection, RFC 7301 section 3.1, and the server chooses it afresh; no early data is sent), and while it is
  younger than `lifetime` (at most 7 days); a binder that does not verify is `decrypt_error`; a ticket that does not open or does not fit is a full handshake.
  `keys.rotate()` makes a new current key (the old one keeps opening its tickets until they expire; `rotateAfter` does it by itself, by default after 24 hours (0: never), and so does a key that has sealed `maximumSeals` tickets, 2^24 by default: a ticket is AES-GCM under a random 96-bit nonce); `keys.wipe()` wipes them.
  A server that asks for client certificates sends and accepts no tickets. Anti-replay is not needed without 0-RTT.
- **Client:** keep a `tlsSessionCacheNew(now, capacity)` between connections and give it to the configuration with `tlsClientConfigWithSessions(config, cache, scope)`; `scope` names what authenticates the server (a resumption skips the Certificate, RFC 8446 section 4.6.1, so a ticket is kept and offered only under the scope it was obtained under: `tlsX509Scope(store)` for `tlsX509Verifier(store, now)`; abla/tls/pure derives it from the verify mode and trust file in its own functions; an empty scope keeps and offers none, so a connection that verified nothing leaves no ticket, and `peerVerified()` of a resumed connection is true) (`tlsConnectWithSessions(host, cache)`,
  `tlsUpgradeWithSessions`, `tlsSessionClient`, and `HttpAsyncOptions.sessions` for `abla/http/async`, whose connections then share it). A new connection to
  a host that has a ticket takes it out of the cache (a ticket is used once) and offers it with its binder, again after a HelloRetryRequest; the tickets a
  server sends go in. A ticket is chosen by host (whatever ALPN list the hello offers); `connection.resumed()` says whether the server took it.
- **Secrets:** tickets, PSKs and ticket keys are buffers of their own and follow the wipe rule of `abla/crypto` (below): wiped when used up, expired, replaced or
  cleared (`cache.clear()`). Time comes from the `now` function you give, in seconds.
- **TLS 1.2** has no resumption here (neither session ids nor RFC 5077 tickets): every TLS 1.2 connection is a full handshake.

Tested against BoGo's resumption tests (about 45 of them run and pass), `openssl s_client -sess_out/-sess_in` against the pure server and the pure client
against `openssl s_server` tickets, and `abla/http/async` reusing a session across connections (`tools/test-tls-pure-interop.sh`).

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
