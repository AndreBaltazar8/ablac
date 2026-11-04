#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-tls-deadline"
mkdir -p "$out"
rm -f "$out/ready"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost \
    -keyout "$out/key.pem" -out "$out/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$out/key.pem" -in "$out/cert.pem" \
    -passout pass:test -out "$out/identity.p12" 2>/dev/null
python3 - "$out/ready" <<'PY' &
import os, socket, sys, threading, time
server = socket.socket(); server.bind(("127.0.0.1", 0)); server.listen(8)
with open(sys.argv[1] + ".next", "w") as ready:
    ready.write(str(server.getsockname()[1]))
os.rename(sys.argv[1] + ".next", sys.argv[1])
def stall(conn, silent):
    try:
        conn.recv(4096)
        if silent:
            time.sleep(3)
            return
        # A partial TLS record trickles in; a per-read timeout alone cannot
        # enforce the exchange deadline while the peer continues sending.
        for byte in b'\x16\x03\x03\x01\x00':
            time.sleep(.16)
            conn.sendall(bytes([byte]))
        time.sleep(3)
    except OSError: pass
    finally: conn.close()
count = 0
while True:
    conn, _ = server.accept()
    threading.Thread(target=stall, args=(conn, count == 0), daemon=True).start()
    count += 1
PY
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 500); do [[ -e $out/ready ]] && break; sleep 0.02; done
[[ -e $out/ready ]]
port=$(cat "$out/ready")
sed -e "s|CERTFILE|$out/cert.pem|g" -e "s|KEYFILE|$out/key.pem|g" \
    -e "s|P12FILE|$out/identity.p12|g" -e "s/39093/$port/g" \
    "$root/tests/cases/http-tls-deadline/main.ab" > "$out/main.ab"
"$compiler" build "$out/main.ab" -o "$out/main" --fast --no-cache
status=0
"$out/main" || status=$?
[[ $status -eq 42 ]]
echo 'HTTPS handshake deadline: plain, PEM and PKCS12 passed'
