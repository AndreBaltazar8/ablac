# Crypto test vectors

Converted by `tools/crypto/convert-vectors.py` into one record per line; read by
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
