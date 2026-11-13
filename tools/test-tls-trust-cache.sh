#!/usr/bin/env bash
# #820: the pure TLS module parses the system CA bundle once per process, and four threads share the parsed store.
# The variables that name a CA file or directory are unset, so the store is the system bundle (skipped, with a message,
# on a machine without one).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-trust-cache
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/tls-pure/trust-cache.ab -o "$out/trust-cache" --no-cache
result=$(env -u NIX_SSL_CERT_FILE -u SSL_CERT_FILE -u SSL_CERT_DIR "$root/tools/run-limited.sh" "$out/trust-cache") || {
    printf '%s\n' "$result" >&2
    echo 'tls trust cache: failed' >&2
    exit 1
}
printf '%s\n' "$result"
[[ $result == *'trust cache ok'* || $result == 'no system bundle'* ]] || { echo 'tls trust cache: failed' >&2; exit 1; }
