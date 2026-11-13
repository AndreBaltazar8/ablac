#!/usr/bin/env bash
# #820: TlsListener.accept bounds the whole handshake. A client sends the start of a TLS record one byte every 200 ms
# (faster than accept's 1.5 s wait for each read, so no single wait ever times out); accept must still give up after
# about 1.5 s with no connection, not after the bytes run out (minutes). Needs openssl (for a certificate) and node
# (for the dripping client).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-accept-deadline
rm -rf "$out"
mkdir -p "$out"
if ! command -v openssl > /dev/null || ! command -v node > /dev/null; then
    echo 'tls accept deadline: needs openssl and node; skipped'
    exit 0
fi
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/key.pem" 2> /dev/null
openssl req -x509 -new -key "$out/key.pem" -out "$out/cert.pem" -subj /CN=localhost -days 2 2> /dev/null
"$compiler" build tests/cases/tls-pure/accept-deadline.ab -o "$out/server" --no-cache
"$out/server" "$out/cert.pem" "$out/key.pem" > "$out/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2> /dev/null || true' EXIT
for _ in $(seq 100); do
    grep -q '^port ' "$out/server.log" 2> /dev/null && break
    sleep 0.1
done
port=$(sed -n 's/^port //p' "$out/server.log")
[[ -n $port ]] || { cat "$out/server.log" >&2; echo 'tls accept deadline: the server did not listen' >&2; exit 1; }
node --input-type=module - "$port" <<'NODE' &
import net from 'node:net';
const socket = net.connect({ host: '127.0.0.1', port: Number(process.argv[2]) });
socket.on('error', () => {});
socket.on('close', () => process.exit(0));
// A handshake record header (type 22, version 3.1) claiming 600 bytes, then its first bytes one at a time.
const bytes = Buffer.concat([Buffer.from([22, 3, 1, 2, 88, 1, 0, 2, 84, 3, 3]), Buffer.alloc(400, 7)]);
let at = 0;
const timer = setInterval(() => { if (at < bytes.length && socket.writable) socket.write(bytes.subarray(at++, at)); else clearInterval(timer); }, 200);
setTimeout(() => process.exit(0), 20000);
NODE
client_pid=$!
for _ in $(seq 150); do
    grep -q '^elapsed ' "$out/server.log" 2> /dev/null && break
    sleep 0.1
done
kill "$client_pid" 2> /dev/null || true
grep -q '^accepted false$' "$out/server.log" || { cat "$out/server.log" >&2; echo 'tls accept deadline: the dripped handshake was accepted, or accept did not return' >&2; exit 1; }
elapsed=$(sed -n 's/^elapsed //p' "$out/server.log")
[[ -n $elapsed && $elapsed -ge 1000 && $elapsed -le 4000 ]] || { cat "$out/server.log" >&2; echo "tls accept deadline: accept took $elapsed ms, expected about 1500" >&2; exit 1; }
echo "tls accept deadline: a byte-at-a-time client was cut off after $elapsed ms"
