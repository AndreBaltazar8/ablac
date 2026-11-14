#!/usr/bin/env bash
# abla/tls/pure's int handles (tlsRelease, tlsReadHandle, tlsWriteHandle, tlsClaim, tlsCloseHandle), descriptor(), detach() and
# tlsLastErrorTimedOut, against openssl in both directions (tests/cases/tls-pure/handles.ab): the pure client through a
# handle against `openssl s_server`, a pure server through a handle against `openssl s_client`, a detached and reset socket
# seen by a pure client as an error, not a clean end, and a read timeout. Usage: tools/test-tls-handles.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
. "$root/tools/lib/openssl-server.sh"
out=build/tls-handles
rm -rf "$out"
mkdir -p "$out"
if ! command -v openssl > /dev/null || ! openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/key.pem" 2> /dev/null; then
    echo 'tls-handles: no openssl; skipped'
    exit 0
fi
openssl req -x509 -new -key "$out/key.pem" -out "$out/cert.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
"$compiler" build tests/cases/tls-pure/handles.ab -o "$out/handles" --fast --no-cache
pids=()
trap 'for p in "${pids[@]:-}"; do [[ -z $p ]] || kill "$p" 2> /dev/null || true; done' EXIT

# 1. The pure client, through a handle, against openssl s_server.
openssl_server_start "$out/server.log" 0 -cert "$out/cert.pem" -key "$out/key.pem" -www -tls1_3 || { echo "tls-handles: s_server did not start" >&2; exit 1; }
pids+=("$openssl_server_pid")
port=$openssl_server_port
result=$("$out/handles" fetch "$port" "$out/cert.pem" 2>&1) || { echo "tls-handles fetch: $result" >&2; exit 1; }
echo "ok   $result"
kill "${pids[-1]}" 2> /dev/null || true

# 2. A pure server, through a handle, against openssl s_client.
"$out/handles" serve "$out/cert.pem" "$out/key.pem" "$out/port" > "$out/serve.log" 2>&1 &
pids+=("$!")
for _ in $(seq 100); do [[ -s $out/port ]] && break; sleep 0.1; done
answer=$(printf 'GET /handles HTTP/1.0\r\n\r\n' | timeout 15 openssl s_client -connect "127.0.0.1:$(cat "$out/port")" -tls1_3 -servername localhost \
    -CAfile "$out/cert.pem" -verify_return_error -verify_hostname localhost -quiet 2> "$out/s_client.err" || true)
wait "${pids[-1]}" || { echo "tls-handles serve: $(cat "$out/serve.log")" >&2; exit 1; }
[[ $answer == *'HTTP/1.0 200 OK'* ]] || { echo "tls-handles serve: answer [$answer]" >&2; cat "$out/serve.log" "$out/s_client.err" >&2; exit 1; }
grep -q 'serve ok' "$out/serve.log"
echo "ok   tls-pure handles serve ok (answer $(printf %s "$answer" | wc -c) bytes)"

# 3. A detached, reset socket: the pure client sees an error.
rm -f "$out/port"
"$out/handles" reset "$out/cert.pem" "$out/key.pem" "$out/port" > "$out/reset.log" 2>&1 &
pids+=("$!")
for _ in $(seq 100); do [[ -s $out/port ]] && break; sleep 0.1; done
result=$("$out/handles" expect-reset "$(cat "$out/port")" "$out/cert.pem" 2>&1) || { echo "tls-handles expect-reset: $result" >&2; cat "$out/reset.log" >&2; exit 1; }
wait "${pids[-1]}" || { cat "$out/reset.log" >&2; exit 1; }
grep -q 'reset ok' "$out/reset.log"
echo "ok   $result"

# 4. A silent peer: the read times out and tlsLastErrorTimedOut says so.
OPENSSL_SERVER_INHERIT_STDIN=1 openssl_server_start "$out/silent.log" 0 -cert "$out/cert.pem" -key "$out/key.pem" -tls1_3 < <(sleep 30) || { echo "tls-handles: s_server did not start" >&2; exit 1; }
pids+=("$openssl_server_pid")
port=$openssl_server_port
result=$("$out/handles" timeout "$port" "$out/cert.pem" 2>&1) || { echo "tls-handles timeout: $result" >&2; exit 1; }
echo "ok   $result"
