# OCSP stapling: a minimal revocation check (design)

Status: design only, nothing is implemented. Written for #1139 (TLS round 2), area 3's known gap "revocation: no CRL or OCSP at all".

## Where we are

`abla/crypto/x509` validates a path (names, validity, basic constraints, key usage, extended key usage, name constraints, signatures) and says
so in its header: revocation (CRL, OCSP) and certificate policies are not done. The x509-limbo `crl::*` cases (15) are all "accepted, expected
failure". The pure TLS client never offers `status_request`, and a certificate entry that carries an extension nobody asked for is refused
(`tlsParseCertificate` reports `entryExtension`; the client and server fail with unsupported_extension, RFC 8446 section 4.4.2). So a
revoked certificate that is otherwise valid is accepted until it expires.

## What stapling is

The server fetches an OCSP response for its own certificate from the CA's responder, and sends it in the handshake, so the client makes no
request of its own (no privacy leak, no blocking fetch, no extra connection).

- ClientHello: extension `status_request` (5), body `status_type = ocsp (1)`, an empty `responder_id_list`, empty `request_extensions`.
- TLS 1.3: the server puts `status_request` in the Certificate entry's extensions, body `CertificateStatus { status_type = 1, opaque OCSPResponse<1..2^24-1> }`;
  each entry of the chain may carry one, in practice only the leaf's does.
- TLS 1.2: a CertificateStatus handshake message (type 22) between Certificate and ServerKeyExchange.
- Must-staple (RFC 7633): a leaf with the `id-pe-tlsfeature` extension (1.3.6.1.5.5.7.1.24) that lists `status_request` (5) promises a staple;
  the client must refuse the handshake without a valid one.

## Scope

In: a client that checks a stapled response for the leaf (and, in TLS 1.3, for any chain entry that carries one); a server that sends a response
the application supplies; must-staple honoured; a parser and verifier for OCSP responses that is fuzzed like the other area 4 parsers.

Out, on purpose:

- The library fetching responses (an HTTP POST to the certificate's AIA responder from inside the TLS stack: blocking, a privacy leak, an outbound
  request chosen by the certificate). The application refreshes the staple; the library may offer `ocspRequestDer(leafDer, issuerDer)` to build the request.
- CRLs (large, fetched over HTTP, a different parser and a revocation cache). CRLite and browser-style revocation lists.
- Soft-fail OCSP fetching by the client.

## The pieces

### 1. `abla/crypto/ocsp`: parse and verify a response

`OCSPResponse ::= SEQUENCE { responseStatus ENUMERATED, responseBytes [0] EXPLICIT ResponseBytes OPTIONAL }`, the only `responseType` accepted is
`id-pkix-ocsp-basic` (1.3.6.1.5.5.7.48.1.1); its `response` is a `BasicOCSPResponse { tbsResponseData, signatureAlgorithm, signature, certs [0] OPTIONAL }`.
Read with `derItem`, which already refuses non-minimal lengths and a leading zero length byte. `ocspCheck(response, leaf, issuer, now, policy)` returns
a status (good, revoked, unknown) or an error, and checks, in this order:

1. `responseStatus == successful (0)`; anything else is an error (an unauthorized or tryLater response is not a staple).
2. The `ResponseData` holds a `SingleResponse` whose `CertID` matches the leaf: `hashAlgorithm` SHA-1 or SHA-256 (SHA-1 is what CAs send; a CertID is a
   name for the certificate, not a security use of the hash), `issuerNameHash` of the issuer's DER subject, `issuerKeyHash` of the issuer's public key bits,
   `serialNumber` equal to the leaf's. A response with several `SingleResponse`s is searched for the matching one.
3. The signer: the issuer itself (`responderID` byKey or byName matching the issuer), or a delegated responder certificate in `certs` that the issuer signed,
   that has `id-kp-OCSPSigning` among its extended key usages and `digitalSignature` in its key usage, and that is valid at `now`. The signature over
   `tbsResponseData` is checked with the signer's key. No other certificate in `certs` is trusted.
4. Freshness: `thisUpdate <= now + skew` (5 minutes), `nextUpdate` present and `now <= nextUpdate`, and `nextUpdate - thisUpdate` at most the policy's
   maximum (7 days, as browsers); a response without `nextUpdate` is refused. `producedAt` is not trusted for anything.
5. `certStatus`: good, revoked (with the time and reason, always a failure), unknown (a failure under a require policy).

It needs from x509: the signature check over arbitrary bytes. Today `x509CheckSignature(cert, issuer)` takes two certificates, so it is split into
`x509VerifySignature(algorithmOid, parameters, signed, signature, issuerKey)` and the existing function becomes a call to it. No new crypto.

### 2. Policy in `X509Options`

`X509Options` gains `revocation: int = 0` (0: as today, nothing checked; 1: use a staple when there is one, a revoked or invalid one fails the path, no staple is
accepted unless the leaf is must-staple; 2: require a good staple) and `staples: array<string> = []` (one response per path element, "" for none, in chain
order). A leaf with must-staple is treated as policy 2 whenever the policy is not 0. The default stays 0 so no existing caller changes. `X509Verification`
reports `revocation` (not checked, good, no staple, revoked, ...) so a caller can tell.

### 3. TLS client

- `TlsClientConfig.revocation: int = 0` and `staples` are not added to the `verifier` closure type (it is public and every caller builds one): the handshake
  keeps the stapled responses it received (`TlsCertificateMessage.statuses`, one per entry) and hands them to the verifier through a new optional field of the
  config, `stapleVerifier: ((array<string>, array<string>) -> TlsVerdict)?`, called after the chain verifier succeeds. `tlsX509Verifier` gets a sibling that
  runs `x509Verify` with the staples. A config with `revocation > 0` offers `status_request`; one with 0 does not (and keeps refusing an unsolicited extension).
- TLS 1.3: `tlsParseCertificate` keeps every entry's `status_request` body (today it only reports the first extension's type) and refuses a body that is not
  `status_type = 1` or has a length that does not fit. TLS 1.2: the CertificateStatus message (type 22) is parsed in the transcript where it belongs, refused when
  it comes without having been offered, and a server that sends one without the client's request is a protocol error as today.
- A staple that is present and fails is a handshake failure with `bad_certificate_status_response` (113, RFC 6066), not a silent fall back to no staple. A
  handshake that is resumed from a ticket does not check again (the ticket's lifetime is bounded to 7 days by the session cache; stated in the docs).

### 4. TLS server

`TlsIdentity` gets `staple: string = ""` (the DER response the application refreshed for this identity's leaf). When the client offered `status_request` and the
identity has a staple, the server sends it (1.3: the leaf entry's extension; 1.2: CertificateStatus). The server does not check the staple's freshness (it
cannot do anything about a stale one but send it; a doc note says to refresh it). Multiple identities (`tlsServerConfigWithIdentities`) each carry their own.

### 5. Limits

A staple is at most 16 KiB (a response for one certificate is about 1.5 KiB; delegated responder certificates add 1-2 KiB). The Certificate message is already limited
to 64 KiB (`tlsMessageLimit`). Parsing is linear in the staple; the signature check is one verification (plus one for a delegated responder).

## Security notes

- Soft-fail is bypassable: a man in the middle can strip `status_request` from the ClientHello or the staple from the ServerHello flight, and a revoked
  certificate then passes under policy 1. Policy 2 and must-staple close that, for the servers that opt in. The docs say so.
- A revoked certificate stays acceptable until the staple expires (the server sends the old "good" response as long as it is fresh: up to the 7 day cap).
- The responder certificate check is where implementations fail (a delegated responder without the OCSPSigning EKU, a certificate for another issuer
  accepted as a responder, a response for a different serial or issuer). Each is a test.
- `unknown` is not `good`. An `OCSPResponse` that is `tryLater`, `unauthorized` or `malformedRequest` is not a staple.

## Tests

1. Vectors made with `openssl ocsp -respond` from a test CA (committed, with the tool that makes them, like `tools/gen-x509-fixtures.sh`): good, revoked (each
   reason), unknown, delegated responder, delegated without the EKU, responder signed by another CA, wrong serial, wrong issuer hashes, `nextUpdate` passed,
   `thisUpdate` in the future, no `nextUpdate`, a window over 7 days, a bad signature, a status other than successful, a response type other than basic.
2. Interop: our client against `openssl s_server -status_file` and a Go `tls.Server` with `Certificate.OCSPStaple` (good, revoked, expired, none, must-staple
   leaf with and without); our server against `openssl s_client -status` and a Go client reading `ConnectionState.OCSPResponse`. The BoGo runner has the
   OCSP cases (`-expect-ocsp-response`, `-ocsp-response`), which come off `tools/tls-bogo/expected-failures.txt` as they pass.
3. A parser harness `tools/fuzz/parsers/ocsp.ab` (area 4's method): mutated valid responses never verify unless identical in the signed part and the CertID,
   never crash or hang, and the status of a mutated response never turns from revoked to good.

## Order of work

1. `x509VerifySignature` split and `abla/crypto/ocsp` with the vectors and the harness (nothing else depends on the TLS side).
2. `X509Options.revocation`/`staples`, the tlsfeature extension, `X509Verification.revocation`.
3. Client: `status_request` offered, entries' statuses kept, `stapleVerifier`, the failure alert; interop against OpenSSL and Go.
4. Server: `TlsIdentity.staple`, both versions; interop in the other direction.
5. BoGo OCSP cases; documentation (`docs/stdlib/tls.md`, x509's header), and the x509 header's "not done" list loses revocation by staple (CRLs stay).

## Open questions

Answered by the security reviewer (7e) on 2026-11-24:

- The default for `revocation` stays 0 (today's behaviour). Flipping it to 1 changes what every client accepts, so it is the project owner's decision when the implementation is scheduled; the proposal above (0 until the interop is in, then 1 in a minor release, announced in the notes) is what is put to them then.
- `ocspRequestDer` goes in the stdlib next to the response parser: it is pure encoding. Fetching a response stays with the application.
- Per-entry staples in TLS 1.3 (intermediates) are verified when present and not requested specially, as designed.
