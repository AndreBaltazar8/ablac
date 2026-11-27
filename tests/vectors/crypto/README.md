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
primitives abla/tls/pure uses that had no Wycheproof test (`ecdh_secp384r1_ecpoint_test.json` was fetched later, 2026-11-15, at the same commit): `x25519_test.json`, `ecdh_secp256r1_ecpoint_test.json`, `ecdh_secp384r1_ecpoint_test.json`,
`ecdsa_secp256r1_sha256_test.json`, `ecdsa_secp384r1_sha384_test.json` (DER signatures), `hkdf_sha256_test.json`,
`hkdf_sha384_test.json`, `hmac_sha256_test.json`, `hmac_sha384_test.json`, `rsa_signature_2048_sha384_test.json`,
`rsa_signature_2048_sha512_test.json` and `rsa_pss_2048_sha384_mgf1_48_test.json` (read by
`tests/cases/crypto-pure/wycheproof-tls.ab`, `tools/test-crypto-pure.sh`).

## mlkem768/

ML-KEM-768 known answers from the NIST ACVP server (commit and format in `mlkem768/README.md`), read by `tests/cases/crypto-pure/mlkem.ab` and, in part, embedded in `tests/cases/crypto-pure/kat.ab` (`tools/test-crypto-pure.sh`).

Also from C2SP/wycheproof `testvectors_v1` (master when fetched, 2026-11-23), read by `tests/cases/crypto-pure/wycheproof-more.ab` (`tools/test-crypto-pure.sh`): `mlkem_768_test`, `mlkem_768_encaps_test` and
`mlkem_768_semi_expanded_decaps_test` (ML-KEM-768: the implicit-rejection secret of altered ciphertexts, encapsulation keys with a coefficient over q refused, key validation),
`ecdsa_secp256r1_sha512_test`, `ecdsa_secp256r1_sha512_p1363_test`, `ecdsa_secp384r1_sha256_test`, `ecdsa_secp384r1_sha512_test` (a digest longer or shorter than the curve order),
`rsa_pkcs1_3072_test` (PKCS#1 v1.5 decryption: the Bleichenbacher cases), `rsa_oaep_3072_sha256_mgf1sha256_test`, `rsa_oaep_4096_sha256_mgf1sha256_test` and `rsa_signature_4096_sha256_test`.
Not read: the sets below 2048 bits (refused by policy), SHA-3 and SHAKE variants, SHA-1/224/512 OAEP, RSA-PSS "misc"/"params".

Also from C2SP/wycheproof `testvectors_v1` at 65ca494727a52944c204441c860b039e6786b99b, fetched 2026-11-23, read by `tests/cases/crypto-pure/wycheproof-hashes.ab` (`tools/test-crypto-pure.sh`): `hmac_sha1`, `hmac_sha512` and `hmac_sha3_{224,256,384,512}`, `hkdf_sha1` and `hkdf_sha512`, `ecdsa_secp256r1_{sha3_256,sha3_512,shake128,shake128_p1363}`, `ecdsa_secp384r1_{sha3_384,sha3_512,shake256,shake256_p1363}` (SHA-3 and SHAKE digests), `rsa_oaep_2048_{sha1,sha224,sha256,sha384,sha512}_mgf1sha*`, `rsa_oaep_{3072,4096}_sha512_mgf1sha512`, `rsa_oaep_misc` (hash and MGF1 hash pairs, 1024 to 8192 bits), and RSASSA-PSS with SHA-1, SHA-256, SHA-384, SHA-512, SHA-512/256 and SHAKE128, other MGF1 hashes and the "params" variants. The library takes one hash for the message and for MGF1, so the other pairs are read for what they must not do. Not read: `ed25519_to_x25519` (no such conversion exists in the library), KMAC, SM3, SHA-224 and SHA-512/t MACs, PBKDF2 and PBES2.

Also from C2SP/wycheproof `testvectors_v1` at 65ca494727a52944c204441c860b039e6786b99b, fetched 2026-11-27: `aes_gcm_test` (every nonce size; only 12 bytes is taken), `ecdsa_secp256r1_sha256_p1363_test`,
`ecdsa_secp384r1_sha384_p1363_test`, `ecdsa_secp384r1_sha512_p1363_test`, `rsa_signature_2048_sha256_test`, `rsa_signature_3072_{sha256,sha384,sha512}_test`, `rsa_signature_4096_{sha384,sha512}_test` and
`rsa_signature_8192_sha384_test` (read by `wycheproof-more.ab`), and `rsa_pss_4096_sha512_mgf1_64_test`, `rsa_pss_4096_sha512_mgf1_64_params_test`, `rsa_pss_misc_test`, `rsa_pss_misc_params_test` (read by `wycheproof-hashes.ab`).
