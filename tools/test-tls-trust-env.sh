#!/usr/bin/env bash
# abla/tls/pure's trust from the environment (#825, tests/cases/tls-pure/trust-env.ab): a set NIX_SSL_CERT_FILE,
# SSL_CERT_FILE or SSL_CERT_DIR is the whole trust, so a missing file, an empty file, an empty directory and a variable set
# to nothing each trust nothing (no system bundle behind them), NIX_SSL_CERT_FILE wins over SSL_CERT_FILE, and a file or a
# directory that holds the server's certificate lets a connection through; with none set the system bundle is used.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-trust-env
rm -rf "$out"
mkdir -p "$out/empty-dir" "$out/cert-dir"
if ! command -v openssl > /dev/null || ! openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/key.pem" 2> /dev/null; then
    echo 'tls-trust-env: no openssl; skipped'
    exit 0
fi
openssl req -x509 -new -key "$out/key.pem" -out "$out/cert.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
cp "$out/cert.pem" "$out/cert-dir/cert.pem"
: > "$out/empty.pem"
"$compiler" build tests/cases/tls-pure/trust-env.ab -o "$out/trust-env" --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }

# run VARIABLE=VALUE ... -- arguments: the program with only the given trust variables set.
run() {
    local settings=()
    while [[ $1 != -- ]]; do settings+=("$1"); shift; done
    shift
    env -u NIX_SSL_CERT_FILE -u SSL_CERT_FILE -u SSL_CERT_DIR "${settings[@]}" "$root/tools/run-limited.sh" "$out/trust-env" "$@"
}
expect_count() { # expected settings...
    local expected=$1 actual; shift
    actual=$(run "$@" -- count)
    [[ $actual == "$expected" ]] || { echo "tls-trust-env: [$*] holds $actual certificates, expected $expected" >&2; exit 1; }
}
expect_count 0 NIX_SSL_CERT_FILE="$out/missing.pem"
expect_count 0 SSL_CERT_FILE="$out/missing.pem"
expect_count 0 SSL_CERT_FILE="$out/empty.pem"
expect_count 0 SSL_CERT_FILE=
expect_count 0 NIX_SSL_CERT_FILE=
expect_count 0 SSL_CERT_DIR="$out/empty-dir"
expect_count 0 SSL_CERT_DIR="$out/missing-dir"
expect_count 0 SSL_CERT_DIR=
expect_count 1 SSL_CERT_FILE="$out/cert.pem"
expect_count 1 SSL_CERT_DIR="$out/cert-dir"
# NIX_SSL_CERT_FILE is read first: set, it decides even when SSL_CERT_FILE names a good file.
expect_count 0 NIX_SSL_CERT_FILE="$out/missing.pem" SSL_CERT_FILE="$out/cert.pem"
expect_count 1 NIX_SSL_CERT_FILE="$out/cert.pem" SSL_CERT_FILE="$out/missing.pem"
system=$(run -- count)
echo "ok   trust stores: a set variable is the whole trust (12 settings); with none set, the system bundle ($system certificates)"

pids=()
trap 'for p in "${pids[@]:-}"; do [[ -z $p ]] || kill "$p" 2> /dev/null || true; done' EXIT
for attempt in 1 2 3 4 5 6; do
    port=$(( 20000 + RANDOM % 20000 ))
    openssl s_server -accept "$port" -cert "$out/cert.pem" -key "$out/key.pem" -www -tls1_3 > "$out/server.log" 2>&1 &
    pids+=("$!")
    for _ in $(seq 100); do grep -q ACCEPT "$out/server.log" 2> /dev/null && break; sleep 0.1; done
    grep -q ACCEPT "$out/server.log" && break
    kill "${pids[-1]}" 2> /dev/null || true
done
expect_connect() { # expected (connected | refused) settings...
    local expected=$1 actual; shift
    actual=$(run "$@" -- connect "$port")
    [[ $actual == "$expected"* ]] || { echo "tls-trust-env: [$*] gave '$actual', expected $expected" >&2; exit 1; }
}
expect_connect connected SSL_CERT_FILE="$out/cert.pem"
expect_connect connected SSL_CERT_DIR="$out/cert-dir"
expect_connect refused SSL_CERT_FILE="$out/missing.pem"
expect_connect refused SSL_CERT_FILE=
expect_connect refused SSL_CERT_DIR="$out/empty-dir"
expect_connect refused NIX_SSL_CERT_FILE="$out/missing.pem" SSL_CERT_FILE="$out/cert.pem"
echo "ok   connections: the server's certificate in a set file or directory lets one through; a set variable naming nothing refuses it"
echo "tls-trust-env ok"
