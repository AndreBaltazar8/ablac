#!/usr/bin/env bash
# Fixed-width secret arithmetic against a BigInt oracle.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
out=build/bignum-secret-tests
mkdir -p "$out"
# Compile the exact private production bodies in the same temporary module as
# the oracle harness. The real internal module exports none of these functions.
cat tests/cases/crypto-bignum-secret/run.ab > "$out/run.ab"
sed -n '/^\/\/ BEGIN RSA SECRET BIGNUM PRIMITIVES$/,/^\/\/ END RSA SECRET BIGNUM PRIMITIVES$/p' stdlib/abla/crypto/rsa/entry.ab >> "$out/run.ab"
cat tests/cases/crypto-bignum-secret/alias.ab > "$out/alias.ab"
sed -n '/^\/\/ BEGIN RSA SECRET BIGNUM PRIMITIVES$/,/^\/\/ END RSA SECRET BIGNUM PRIMITIVES$/p' stdlib/abla/crypto/rsa/entry.ab >> "$out/alias.ab"
for case in forbidden forbidden-qualified; do
    if "$compiler" build "tests/cases/crypto-bignum-secret/$case.ab" -o "$out/forbidden" --fast --no-cache > "$out/$case.log" 2>&1; then
        echo "private bignum helper was callable: $case" >&2
        exit 1
    fi
    grep -Eq 'name.private:bnSecretExactDivBody|E_NAME_PRIVATE' "$out/$case.log" || { cat "$out/$case.log" >&2; exit 1; }
done
echo "ok   private bignum helpers are inaccessible"
for mode in --fast ''; do
    label=${mode:---release}
    "$compiler" build "$out/run.ab" -o "$out/oracle" --no-cache $mode
    node tests/cases/crypto-bignum-secret/oracle.mjs "$PWD/$out/oracle" "$PWD/$out"
    "$compiler" build "$out/alias.ab" -o "$out/alias" --no-cache $mode
    "$out/alias" || { echo "overlap guard failed" >&2; exit 1; }
    echo "ok   overlap guards reject aliased buffers"
    echo "ok   bignum secret $label"
done
# Cross-target numeric oracle: BigInt supplies the expected integers, and the
# static no-libc executable runs under qemu-aarch64 without a network or files.
node tests/cases/crypto-bignum-secret/aarch64-kat.mjs "$out/aarch64-kat.ab"
sed -n '/^\/\/ BEGIN RSA SECRET BIGNUM PRIMITIVES$/,/^\/\/ END RSA SECRET BIGNUM PRIMITIVES$/p' stdlib/abla/crypto/rsa/entry.ab >> "$out/aarch64-kat.ab"
"$compiler" build tests/cases/crypto-bignum-secret/aarch64-build.ab -o "$out/aarch64-driver" --no-cache
llvm-mc -triple aarch64-linux-gnu -filetype=obj tests/cases/simd/aarch64-start.s -o "$out/aarch64-start.o"
ld.lld -static --no-pie -z notext "$out/aarch64.o" "$out/aarch64-start.o" -o "$out/aarch64"
timeout 180 qemu-aarch64 -cpu max "$out/aarch64" || { echo "AArch64 bignum numerical oracle failed" >&2; exit 1; }
echo "ok   AArch64 numerical oracle under qemu"
