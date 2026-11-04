#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-interim"
mkdir -p "$out"
rm -f "$out/ready"
cp "$root/tests/vectors/crypto/test-keys/tls-server.pem" "$out/key.pem"
openssl req -x509 -new -key "$out/key.pem" -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
    -out "$out/cert.pem" 2>/dev/null
python3 - "$out/ready" "$out/cert.pem" "$out/key.pem" <<'PY' &
import os, socket, ssl, sys, threading, time
plain = socket.socket(); plain.bind(("127.0.0.1", 0)); plain.listen(16)
tls = socket.socket(); tls.bind(("127.0.0.1", 0)); tls.listen(16)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
with open(sys.argv[1] + ".next", "w") as ready:
    ready.write(f"{plain.getsockname()[1]} {tls.getsockname()[1]}\n")
os.rename(sys.argv[1] + ".next", sys.argv[1])
closed = threading.Event()
gate = threading.Event()
counts = {b"/incomplete": 0}
counts_lock = threading.Lock()
def handle(conn, secure):
    try:
        if secure: conn = context.wrap_socket(conn, server_side=True)
        conn.settimeout(4)
        path = conn.recv(65536).split(b" ", 2)[1]
        gate.set()  # release any previous bodyless response
        if path == b"/reuse":
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            next_path = conn.recv(65536).split(b" ", 2)[1]
            assert next_path == b"/incomplete"
            with counts_lock: counts[next_path] += 1
            conn.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
        elif path == b"/switch":
            conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\n\r\n")
        elif path == b"/incomplete":
            with counts_lock: counts[path] += 1
            conn.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
        elif path == b"/counts":
            with counts_lock: count = counts[b"/incomplete"]
            body = str(count).encode()
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
        else:
            conn.sendall(b"HTTP/1.1 100 Continue\r\n\r\n" * 20 + b"HTTP/1.1 103 Early Hints\r\nX-")
            time.sleep(0.1)
            conn.sendall(b"Second: yes\r\n\r\n")
            time.sleep(0.1)
            if path in (b"/head", b"/async-head"):
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 999\r\nConnection: close\r\n\r\n")
                time.sleep(1.5)
            else:
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nfinal")
    except (OSError, ssl.SSLError):
        pass
    finally:
        conn.close()
def serve(server, secure):
    server.settimeout(0.1)
    while not closed.is_set():
        try:
            conn, _ = server.accept()
            threading.Thread(target=handle, args=(conn, secure), daemon=True).start()
        except socket.timeout: pass
threads = [threading.Thread(target=serve, args=(plain, False)), threading.Thread(target=serve, args=(tls, True))]
for thread in threads: thread.start()
try:
    while not closed.wait(0.1): pass
except KeyboardInterrupt: pass
finally:
    closed.set()
    for thread in threads: thread.join()
    plain.close(); tls.close()
PY
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 500); do [[ -e $out/ready ]] && break; sleep 0.02; done
[[ -e $out/ready ]]
read -r plain_port tls_port < "$out/ready"
sed -e "s/39092/$plain_port/g" -e "s/39093/$tls_port/g" \
    "$root/tests/cases/http-interim/main.ab" > "$out/main.ab"
"$compiler" build "$out/main.ab" -o "$out/main" --fast
status=0
SSL_CERT_FILE="$out/cert.pem" "$out/main" || status=$?
[[ $status -eq 42 ]]
echo 'HTTP interim responses: repeated, split, TLS, async, HEAD and 101 passed'
