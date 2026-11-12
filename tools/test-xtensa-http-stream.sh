#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out="$root/build/xtensa-http-stream"
mkdir -p "$out"
"$compiler" build tests/cases/xtensa-http-stream/main.ab --fast --no-cache -o "$out/test"
"$compiler" build tests/cases/xtensa-http-stream/tls.ab --fast --no-cache -o "$out/tls"
test_root=$(mktemp -d "$out/files.XXXXXXXX")
trap 'rm -rf "$test_root"' EXIT
ABLA_HTTP_STREAM_ROOT="$test_root" "$out/test"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/key.pem" -out "$out/cert.pem" \
    -days 2 -subj /CN=localhost -addext subjectAltName=DNS:localhost 2>/dev/null
python3 - "$out/tls" "$out/cert.pem" "$out/key.pem" "$test_root" <<'PY'
import socket, ssl, subprocess, sys, threading
binary, cert, key, output = sys.argv[1:]
listener = socket.socket(socket.AF_INET6); listener.bind(('::1', 0)); listener.listen(1)
port = listener.getsockname()[1]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
errors = []
def serve():
    try:
        sock, _ = listener.accept()
        with context.wrap_socket(sock, server_side=True) as conn:
            request = b''
            while b'\r\n\r\n' not in request:
                part = conn.recv(4096)
                if not part: raise ValueError('truncated request')
                request += part
            if not request.startswith(b'GET /fixture HTTP/1.1\r\n'): raise ValueError('wrong request')
            for part in [b'HTTP/1.1 200 OK\r\nTransfer-', b'Encoding: chunked\r\n\r\n', b'2\r\nhe\r\n', b'3\r\nllo\r\n0\r\n\r\n']:
                conn.sendall(part)
    except Exception as exc: errors.append(repr(exc))
    finally: listener.close()
thread = threading.Thread(target=serve, daemon=True); thread.start()
result = subprocess.run([binary, output, cert, str(port)], timeout=15)
thread.join(5)
if result.returncode or thread.is_alive() or errors: raise SystemExit(f'TLS fixture failed: {result.returncode}, {errors}')
PY
echo 'xtensa-http-stream: bounded framing and loopback TLS passed'
