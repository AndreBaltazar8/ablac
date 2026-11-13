# Crypto test vectors

Converted by a script (`tools/crypto/convert-vectors.py`, removed with the repository's Python: see git history at a8e65b35) into one record per line; read by
`tests/cases/crypto/vectors.ab`, run by `tools/test-crypto.sh`. All keys are the sources'
published test keys. Fetched 2026-10-31.

- NIST CAVP (public domain), from `csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents`:
  `aes/KAT_AES.zip`, `aes/aesmmt.zip` (ECB and CBC, whole), `mac/gcmtestvectors.zip` (96-bit IV,
  128-bit tag, every third), `shs/shabytetestvectors.zip` (short messages whole, long ones every tenth),
  `mac/hmactestvectors.zip` (every third of the full-length hash sizes). Monte Carlo files aren't used.
- Wycheproof (Apache-2.0), C2SP/wycheproof `testvectors_v1` at d17cc89fa5c8f4f4d378b5385ebf75da5d0926c9:
  `aes_cbc_pkcs5`, `aes_gcm` (96-bit IV), `hmac_sha1/256/384/512`, `rsa_pkcs1_1024_sig_gen` (SHA-1),
  `rsa_pkcs1_2048_sig_gen` (SHA-256), `rsa_signature_2048_sha256`, `rsa_pkcs1_2048`, `rsa_oaep_2048_sha1_mgf1sha1`,
  `rsa_oaep_2048_sha256_mgf1sha256` (empty labels).
- Wycheproof (Apache-2.0), C2SP/wycheproof `testvectors_v1/ed25519_test.json` (the last commit that touched it, a3d5d1423f2592d6646836a45a21a1b209da9f4d, fetched
  2026-11-13), kept as the original JSON in `wycheproof-ed25519.json` (210 verification cases: valid, invalid and acceptable); read by
  `tests/cases/ed25519/main.ab` through abla/json, run by `tools/test-ed25519.sh`.

## wycheproof/ (JSON, as published)

Wycheproof (Apache-2.0), C2SP/wycheproof `testvectors_v1` at 65ca494727a52944c204441c860b039e6786b99b (master when fetched), fetched 2026-11-13: `chacha20_poly1305_test.json`
(read by `tests/cases/crypto-chacha/wycheproof.ab`, `tools/test-crypto-chacha.sh`) and `rsa_pss_{2048_sha256_mgf1_32,
2048_sha256_mgf1_0,3072_sha256_mgf1_32,4096_sha512_mgf1_32}_test.json` (read by `tests/cases/crypto-pss/vectors.ab`,
`tools/test-crypto-pss.sh`). Parsed with abla/json, not converted.

Also from C2SP/wycheproof `testvectors_v1` at 65ca494727a52944c204441c860b039e6786b99b, fetched 2026-11-13, for the
primitives abla/tls/pure uses that had no Wycheproof test: `x25519_test.json`, `ecdh_secp256r1_ecpoint_test.json`,
`ecdsa_secp256r1_sha256_test.json`, `ecdsa_secp384r1_sha384_test.json` (DER signatures), `hkdf_sha256_test.json`,
`hkdf_sha384_test.json`, `hmac_sha256_test.json`, `hmac_sha384_test.json`, `rsa_signature_2048_sha384_test.json`,
`rsa_signature_2048_sha512_test.json` and `rsa_pss_2048_sha384_mgf1_48_test.json` (read by
`tests/cases/crypto-pure/wycheproof-tls.ab`, `tools/test-crypto-pure.sh`).
