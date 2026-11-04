import os, select, socket, ssl, subprocess, sys, tempfile
binary, cert, key = sys.argv[1:]
request = b'GET /item/42 HTTP/1.1\r\nHost: localhost\r\nCF-Connecting-IP: 203.0.113.90\r\nX-Forwarded-For: 198.51.100.24\r\nConnection: close\r\n\r\n'
for mode in ('sync4', 'sync6', 'mapped', 'event', 'noescape', 'event6', 'noescape6', 'tls4', 'tls6', 'tlsws6', 'unix'):
    with tempfile.TemporaryDirectory(prefix='ab-peer-', dir='/tmp') as directory:
        path = os.path.join(directory, 'socket')
        args = [binary, mode] + ([path] if mode == 'unix' else [cert, key])
        proc = subprocess.Popen(args, stderr=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            if not select.select([proc.stderr], [], [], 15)[0]:
                raise AssertionError((mode, 'server did not become ready'))
            ready = proc.stderr.readline().strip()
            if not ready:
                raise AssertionError((mode, proc.poll(), proc.stderr.read()))
            family = socket.AF_UNIX if mode == 'unix' else socket.AF_INET6 if mode.endswith('6') else socket.AF_INET
            sock = socket.socket(family, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect(path if mode == 'unix' else ('::1' if family == socket.AF_INET6 else '127.0.0.1', int(ready)))
            local_port = None if mode == 'unix' else sock.getsockname()[1]
            if mode.startswith('tls'):
                context = ssl._create_unverified_context()
                sock = context.wrap_socket(sock, server_hostname='localhost')
            payload = request
            if mode == 'tlsws6':
                payload = request.replace(b'Connection: close', b'Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')
            if mode in ('event', 'noescape', 'event6', 'noescape6'):
                payload = request.replace(b'Connection: close', b'Connection: keep-alive') + request
            sock.sendall(payload)
            response = b''
            while True:
                chunk = sock.recv(4096)
                if not chunk: break
                response += chunk
            sock.close()
            bodies = []
            while response:
                header, response = response.split(b'\r\n\r\n', 1)
                length = next(int(line.split(b':', 1)[1]) for line in header.split(b'\r\n') if line.lower().startswith(b'content-length:'))
                bodies.append(response[:length].decode())
                response = response[length:]
            peer_family = 6 if family == socket.AF_INET6 or mode == 'mapped' else 4
            peer_ip = '::ffff:7f00:1' if mode == 'mapped' else '::1' if family == socket.AF_INET6 else '127.0.0.1'
            expected = ('null' if mode == 'unix' else f'{peer_family}|{peer_ip}|{local_port}|0')
            # The direct noescape handler bypasses router parameters.
            suffix = '|' + '203.0.113.90' + ('|' if mode in ('noescape', 'noescape6', 'unix') or mode.startswith('tls') else '|42')
            assert bodies == [expected + suffix] * (2 if mode in ('event', 'noescape', 'event6', 'noescape6') else 1), (mode, bodies, expected + suffix)
            if mode in ('event', 'noescape', 'event6', 'noescape6'):
                # A new accepted connection can reuse a slot, but never its peer.
                second = socket.socket(family, socket.SOCK_STREAM)
                second.settimeout(5)
                second.connect(('::1' if family == socket.AF_INET6 else '127.0.0.1', int(ready)))
                second_port = second.getsockname()[1]
                second.sendall(request)
                reply = b''
                while True:
                    chunk = second.recv(4096)
                    if not chunk: break
                    reply += chunk
                second.close()
                second_body = reply.split(b'\r\n\r\n', 1)[1].decode()
                second_expected = f'{6 if family == socket.AF_INET6 else 4}|{"::1" if family == socket.AF_INET6 else "127.0.0.1"}|{second_port}|0' + suffix
                assert second_body == second_expected, (mode, second_body, second_expected)
            code = proc.wait(timeout=5)
            assert code == 0, (mode, code, proc.stderr.read())
            print('ok', mode)
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait()
