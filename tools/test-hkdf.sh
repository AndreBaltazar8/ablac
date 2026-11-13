#!/usr/bin/env bash
# abla/crypto/hkdf: RFC 5869 appendix A (all seven), the TLS 1.3 labels (RFC 8448's early and
# derived secrets, SHA-384 values from openssl), and the length bounds; release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/hkdf
rm -rf "$out"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/hkdf/main.ab -o "$out/main.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/main.$mode") || { echo "hkdf ($mode): $result" >&2; exit 1; }
    [[ $result == 'hkdf ok' ]] || { echo "hkdf ($mode): $result" >&2; exit 1; }
done
echo 'hkdf ok'
