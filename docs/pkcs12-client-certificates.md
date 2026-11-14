# PKCS#12 client certificates, and the tax authority's

A mutual-TLS client reads its key and certificate chain from a PKCS#12 (`.pfx`/`.p12`) file:
`tlsClientIdentityFromPkcs12` (`abla/tls/pure`), `abla/crypto/pbe`'s `pbeOpenPkcs12Contents`. This note says which encodings
that reader accepts and why, what the Portuguese tax authority (AT, Autoridade Tributária e Aduaneira) does, and how to test
the path.

## What the reader accepts

Read only. Nothing in the repository writes the old encodings: the writers use PBES2 with AES.

| Part of the file | Read |
|---|---|
| Container | PFX v3 with password integrity; a MAC is required (a MAC-less file is refused: no tool writes one by default, and the MAC is what tells a wrong password from a corrupt file before anything is decrypted) |
| MAC | HMAC-SHA-1 and HMAC-SHA-256 with the PKCS#12 key derivation. Refused: SHA-224/384/512 (nothing writes them by default) and PBMAC1 (OpenSSL 3.4's `-pbmac1_pbkdf2`, not a default) |
| Key and certificate bags | PBES2 with PBKDF2 (HMAC-SHA-1 or SHA-256) and AES-128/192/256-CBC or 3DES-CBC; the PKCS#12 SHA-1 schemes `pbeWithSHA1And3-KeyTripleDES-CBC`, `...And2-KeyTripleDES-CBC`, `...And128BitRC2-CBC`, `...And40BitRC2-CBC`; unencrypted bags |
| Refused | RC4 (`pbeWithSHA1And128BitRC4`, `...40BitRC4`): no tool writes it any more; single DES and PBES2 with RC2: nothing writes them; PKCS#5 v1.5 PBE-MD5-DES |
| Passwords | UTF-8, converted to the BMP string of the PKCS#12 KDF; empty and non-ASCII passwords work |
| Keys | RSA (any size up to 16384 bits; 2048 and 4096 tested), P-256, Ed25519 |

The legacy schemes use 3DES and RC2, which are not constant time (`abla/crypto/legacy`); the container is decrypted once, from a
file, by its owner. The AES and PBKDF2 paths keep their constant-time cores.

## Who writes what

| Writer | Key bag | Certificate bags | MAC |
|---|---|---|---|
| OpenSSL 3.x default | PBES2 AES-256-CBC, PBKDF2-HMAC-SHA-256 | the same | SHA-256 |
| OpenSSL 1.1 default, OpenSSL 3 with `-legacy` | 3DES (`pbeWithSHA1And3-KeyTripleDES-CBC`) | RC2-40 | SHA-1, 2048 rounds |
| Windows 10+ (certutil, MMC, "AES256-SHA256") | PBES2 AES-256-CBC | the same | SHA-256, 2000 rounds |
| Windows, older exports ("TripleDES-SHA1") | 3DES | 3DES | SHA-1 |
| Java 8 to 17 (keytool default) | 3DES, 50000 rounds | RC2-40 | HmacPBESHA1, 100000 rounds |
| Java 18+ | PBES2 AES-256 (`PBEWithHmacSHA256AndAES_256`) | the same | HmacPBESHA256, 10000 rounds |
| **AT's published test certificate** | 3DES | 3DES | SHA-1, 2000 rounds |

Fixtures for each row that can be made with OpenSSL or the JDKs' keytool are in `tests/vectors/crypto/encrypted-rsa/legacy/`
(`generate-legacy.sh` records the commands); `cases.txt` opens every one of them, checks that a wrong password gives exactly
"wrong password or corrupt key", and that the refused ones say why. Windows and macOS exports were not made on those systems:
the OpenSSL profiles above are the same encodings.

## The tax authority

Its web services (invoice communication, series, transport documents, the VAT and tax declarations) are mutual-TLS endpoints.
From AT's manuals ("Comunicação das Faturas à AT", "Certificados Digitais e Endpoints"):

* A producer generates the key and the signing request itself:
  `openssl req -new -subj "/C=PT/…/CN=<NIF>" -newkey rsa:… -nodes -out <NIF>.csr -keyout <NIF>.key`, AT signs it, and the
  producer joins them: `openssl pkcs12 -export -in <NIF>.crt -inkey <NIF>.key -out <NIF>.pfx`, **with no encryption options**. The
  `.pfx` is therefore whatever the producer's OpenSSL writes by default: RC2-40/3DES/SHA-1 on OpenSSL 1.x, PBES2 on OpenSSL 3.
  (Other people use Java or Windows tools: the table above.)
* Since AT's notice of 27 March 2025 requests must be RSA-4096; certificates of 2048 bits expired by 28 June 2025; a new
  certification authority went into production on 31 May 2025. Test with RSA-4096 keys.
* AT publishes a client certificate for its **test environment**, with its password: the "Certificado de teste para comunicação
  com Web Services da AT" on the Portal das Finanças page "Certificados de segurança"
  (`info.portaldasfinancas.gov.pt/pt/apoio_ao_contribuinte/Outras_entidades/Suporte_tecnologico/Certificados_de_seguranca`,
  `…/Documents/TesteWebservices.zip`). The file is `TesteWebservices.pfx`, valid to 2027-01-06, an RSA-4096 leaf `CN=TesteWebservices`
  under "AT Issuing CA1" and "AT Root CA"; the installation password is published in "Certificados Digitais e Endpoints" (section 4).
  Its encoding is the AT row above: 3DES key and certificates, SHA-1 MAC with 2000 rounds. **It is not in this repository**: it is AT's
  file and its terms of reuse are AT's. Download it yourself and run
  `AT_TEST_PFX=/path/to/TesteWebservices.pfx tools/test-crypto-legacy.sh build/ablac`.
* The test endpoints are `https://servicos.portaldasfinancas.gov.pt:700/fews/faturas` (invoices; production is `:400`) and the other
  test ports 7XX and 8XX of the same host; they accept only the test certificate. A connectivity page for producers exists
  ("Testar Webservice" on the e-fatura producers page). **Nothing in this repository contacts AT's servers**; whether and how to
  run a handshake against the test endpoint is a decision for the owner of this repository, not for a test.

## How to test the path

1. `tools/test-crypto-encrypted-rsa.sh` (every fixture above, including wrong passwords and limits), `tools/test-crypto-legacy.sh`
   (the 3DES and RC2 ciphers against OpenSSL's known answers), `tools/test-tls-unix.sh` (a mutual-TLS handshake from a 3DES/SHA-1
   PKCS#12 identity against a Node server that checks the client certificate).
2. With AT's test certificate: `AT_TEST_PFX=… tools/test-crypto-legacy.sh` (reads it as a TLS identity: the leaf and its chain).
3. The part nothing local proves is AT's server: that its TLS 1.2/1.3 stack accepts what `abla/tls/pure` sends as a client with
   an RSA-4096 certificate (CertificateVerify with RSA-PSS, or PKCS#1 v1.5 in TLS 1.2). Only a connection to
   `:700` with the test certificate shows that; it needs the owner's go-ahead.
