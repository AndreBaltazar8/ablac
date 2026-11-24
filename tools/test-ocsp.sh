#!/usr/bin/env bash
# abla/crypto/ocsp against the responses `openssl ocsp` made for a test CA (tests/cases/ocsp/main.ab; tools/gen-ocsp-fixtures.sh makes the files): good, revoked,
# unknown, delegated responders, expiry, damage of every kind, the policy over a path, and the request; release and fast builds. Usage: tools/test-ocsp.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/ocsp
rm -rf "$out"
mkdir -p "$out"
for mode in fast release; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/ocsp/main.ab -o "$out/ocsp.$mode" "${flags[@]}" > "$out/build.$mode.log" 2>&1 || { cat "$out/build.$mode.log" >&2; exit 1; }
    result=$("$root/tools/run-limited.sh" "$out/ocsp.$mode" tests/cases/ocsp) || { echo "ocsp ($mode): $result" >&2; exit 1; }
    [[ $result == "ocsp ok" ]] || { echo "ocsp ($mode): $result" >&2; exit 1; }
done
# The staple verifier never uses a path recorded for another chain (tests/cases/tls-pure/ocsp-shared.ab, the same fixtures).
for mode in fast release; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/tls-pure/ocsp-shared.ab -o "$out/shared.$mode" "${flags[@]}" > "$out/build-shared.$mode.log" 2>&1 || { cat "$out/build-shared.$mode.log" >&2; exit 1; }
    result=$("$root/tools/run-limited.sh" "$out/shared.$mode" tests/cases/ocsp) || { echo "ocsp-shared ($mode): $result" >&2; exit 1; }
    [[ $result == "tls-pure ocsp-shared ok" ]] || { echo "ocsp-shared ($mode): $result" >&2; exit 1; }
done
echo "ocsp ok: responses judged for good, revoked, unknown, delegated and foreign signers, freshness, damage, the policy over a path and the request"
