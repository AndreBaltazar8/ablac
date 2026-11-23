#!/usr/bin/env bash
# The RSA keys of a JWKS: minimal-length n and e (RFC 7518), so a padded small modulus is no key; fast and release builds, with and without GC stress.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/jwt-keys"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/jwt-keys/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" || status=$?
        [[ $status -eq 42 ]] || { echo "jwt keys: status $status (mode '$mode', stress $stress)" >&2; exit 1; }
    done
done
echo "jwt keys: a real RSA key imports, a modulus or exponent with a leading zero byte does not"
