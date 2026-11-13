# TLS test vectors

- `rfc8448-section3.txt`: the Simple 1-RTT Handshake of RFC 8448 ("Example Handshake Traces for TLS 1.3",
  J. Thomson, January 2019; TLS_AES_128_GCM_SHA256, X25519, RSA-PSS), one value per line as
  `heading|name|hex`, the RFC's own step names and value names, in the RFC's order. Extracted from the RFC text
  (fetched 2026-11-13 from https://www.rfc-editor.org/rfc/rfc8448.txt) by `tools/tls/extract-rfc8448.sh`; read
  by `tests/cases/tls-pure/keysched.ab`, run by `tools/test-tls-pure.sh`. The traces' keys are the RFC's published
  test keys.
- `rfc8448-section5.txt`, `-section6.txt`, `-section7.txt`: the same extraction (`tools/tls/extract-rfc8448.sh rfc8448.txt N`)
  of section 5 (HelloRetryRequest), 6 (Client Authentication) and 7 (Compatibility Mode: a 32-byte session id and
  ChangeCipherSpec records). Section 7 is used by `tests/cases/tls-pure/client.ab`; 5 and 6 are kept for the
  HelloRetryRequest and client-certificate tests (they need P-256 and the signature primitives).
