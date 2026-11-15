# ML-KEM-768 known answers

Source: NIST ACVP-Server, https://github.com/usnistgov/ACVP-Server, commit 975de31eb83d87039ec88934fdc47d8c312b892d,
gen-val/json-files/ML-KEM-keyGen-FIPS203/internalProjection.json and gen-val/json-files/ML-KEM-encapDecap-FIPS203/internalProjection.json,
the ML-KEM-768 groups only. One test per line, fields in lowercase hex, produced with jq (and `tr A-F a-f`):

    keygen TCID d z ek dk                  key generation from the seeds d and z (keyGen, AFT)
    encaps TCID ek m c k                   encapsulation with the message m (encapDecap encapsulation, AFT)
    decaps TCID dk c k                     decapsulation (encapDecap decapsulation, VAL; some ciphertexts are altered: k is the implicit-rejection secret)
    ekcheck TCID ek passed                 the encapsulation key check of FIPS 203 section 7.2 (true or false)
    dkcheck TCID dk passed                 the decapsulation key check of FIPS 203 section 7.3
