#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-close-delimited"
mkdir -p "$out"
rm -f "$out/ready"
# The clients trust the test certificate through SSL_CERT_FILE. Nixpkgs' OpenSSL
# reads NIX_SSL_CERT_FILE before it, and a Nix install sets that to the system
# bundle (CI does), so it would not see the certificate.
unset NIX_SSL_CERT_FILE
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
def handle(conn, secure):
    try:
        if secure: conn = context.wrap_socket(conn, server_side=True)
        conn.settimeout(4)
        path = conn.recv(65536).split(b" ", 2)[1]
        gate.set()  # release any previous bodyless response
        if path in (b"/close", b"/tls-close", b"/async-close"):
            conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n")
            time.sleep(0.15)
            body = {b"/close": b"delayed body", b"/tls-close": b"secure body", b"/async-close": b"async body"}[path]
            conn.sendall(body)
        elif path in (b"/head", b"/tls-head", b"/async-head", b"/empty", b"/not-modified", b"/info"):
            if path in (b"/head", b"/tls-head", b"/async-head"):
                head = b"HTTP/1.1 200 OK\r\nContent-Length: 999\r\nConnection: close\r\n\r\n"
            elif path == b"/empty": head = b"HTTP/1.1 204 No Content\r\n\r\n"
            elif path == b"/info": head = b"HTTP/1.1 101 Switching Protocols\r\n\r\n"
            else: head = b"HTTP/1.1 304 Not Modified\r\n\r\n"
            gate.clear()
            conn.sendall(head)
            gate.wait(3)
        elif path in (b"/differ", b"/async-differ"):
            # Two Content-Lengths that differ, then the connection stays open: a client must stop at once.
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 5\r\n\r\nabc")
            time.sleep(1.5)
        elif path in (b"/stall", b"/tls-stall"):
            conn.sendall(b"HTTP/1.0 200 OK\r\n\r\npartial")
            time.sleep(1.5)
        elif path == b"/over":
            conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n" + b"x" * 200)
        elif path == b"/at-limit":
            conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n" + b"x" * 45)
        elif path == b"/chunked":
            conn.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nchunk\r\n0\r\n\r\n")
        else:
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
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
    "$root/tests/cases/http-close-delimited/main.ab" > "$out/main.ab"
"$compiler" build "$out/main.ab" -o "$out/main" --fast
status=0
SSL_CERT_FILE="$out/cert.pem" "$out/main" || status=$?
[[ $status -eq 42 ]]
echo 'HTTP close-delimited bodies, TLS, async, limits and bodyless responses passed'
