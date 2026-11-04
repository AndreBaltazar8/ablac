# Encrypted RSA import fixtures

All files use the repository's already-public `../rsa-implicit-key.pem` test key.
They are NOT production credentials. The normal password is the literal
`test-only-password`; `empty-sha1.pem` uses an empty password,
`long-password.pem` uses eighty ASCII zeroes, and `utf8-password.pem` uses
`tést-only-password`. Never substitute a real key/password in this directory.

Initial fixtures were generated with OpenSSL 3.5.8 (25 Aug 2026).

`generate.sh` records the OpenSSL commands (`pkcs8 -topk8 -v2 aes-256-cbc` and
its AES128 / SHA1 variants). Salt and IV are randomized on regeneration;
regenerated ciphertext is not expected to be byte-identical. Tests check the
same public RSA modulus fingerprint against independent OpenSSL output.

The normal files use2048 iterations, `low-count.pem` and `empty-sha1.pem` use1
(compatibility fixtures, not advice for new encrypted keys), and the long/UTF8
password fixtures use17. `legacy-3des.pem` is a real OpenSSL PKCS12-PBE/3DES
PKCS8 export and must be refused with an explicit unsupported-legacy error.

PKCS#12 fixtures use `openssl pkcs12 -export` and the same public key, plus
`certificate.pem` (a self-signed test certificate for `pbe-fixture.invalid`,
not a trusted identity). `modern.p12` uses OpenSSL's AES256/SHA256 defaults
and 2048 iterations. `sha1-mac.p12`, `utf8.p12` and `long.p12` use17 iterations;
the last two use the UTF8 and eighty-zero passwords above. `empty.p12` uses
one iteration and an empty password. `keybag.p12` has unencrypted bags but a
required MAC. `no-mac.p12` and `legacy.p12` are deliberate rejection fixtures.
The Python oracle independently derives SHA1/SHA256 MAC keys and authenticates
mutated containers; tests prove that MAC failure precedes cipher inspection.
