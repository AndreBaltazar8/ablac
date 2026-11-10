#!/usr/bin/env python3
"""Sequential Unix TLS echo/identity/deadline fixtures; no external service."""
import os
import socket
import ssl
import subprocess
import sys
import threading
import time
from pathlib import Path

binary, certificate, key, bundle, directory = map(os.path.abspath, sys.argv[1:])

def run(address, mode):
    result = subprocess.run([binary, address, certificate, key, bundle, mode],
                            capture_output=True, text=True, timeout=600)
    if result.returncode:
        raise AssertionError(f'{mode} ({address!r}): {result.returncode}\n{result.stdout}{result.stderr}')

def endpoint(name, abstract):
    text = f'abla-tls-{os.getpid()}-{name}'
    return '@' + text if abstract else str(Path(directory) / (name + '.sock'))

def python_peer(address, mode, require_identity=False, stall=False):
    server = socket.socket(socket.AF_UNIX)
    server.bind('\0' + address[1:] if address.startswith('@') else address)
    server.listen(2)
    server.settimeout(120)
    errors = []
    unexpected_success = []
    reject = mode in ('invalid', 'bad-host', 'bad-ca')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    if require_identity:
        context.verify_mode = ssl.CERT_REQUIRED
        context.load_verify_locations(certificate)
    def serve():
        try:
            conn, _ = server.accept()
            with conn:
                conn.settimeout(120)
                if stall:
                    conn.recv(4096)
                    # A record that never completes (its header, then its 256 bytes one at a time, 40 s in all): a
                    # per-read timeout cannot substitute for the absolute handshake deadline, and a client that
                    # honours a deadline closes long before the record would end.
                    for byte in b'\x16\x03\x03\x01\x00' + bytes(256):
                        time.sleep(.16)
                        try: conn.sendall(bytes([byte]))
                        except OSError: break
                    return
                try:
                    with context.wrap_socket(conn, server_side=True) as tls:
                        if reject:
                            # TLS 1.3 rejection can arrive after the server's
                            # handshake; an application read must still fail.
                            if tls.recv(32): unexpected_success.append(mode)
                            return
                        if require_identity and not tls.getpeercert():
                            raise AssertionError('client identity was not presented')
                        if tls.recv(32) != b'hello': raise AssertionError('missing echo request')
                        tls.sendall(b'world')
                except ssl.SSLError:
                    if not reject: raise
        except BaseException as exc:
            errors.append(exc)
        finally:
            server.close()
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        run(address, mode)
    finally:
        thread.join(120)
        server.close()
        if not address.startswith('@'): Path(address).unlink(missing_ok=True)
    if thread.is_alive(): raise AssertionError(f'peer outlived {mode}')
    if errors: raise AssertionError(f'peer {mode}: {errors}')
    if unexpected_success: raise AssertionError(f'invalid client succeeded: {mode}')

for abstract in (False, True) if sys.platform.startswith('linux') else (False,):
    prefix = 'abstract' if abstract else 'path'
    for mode in ('echo', 'inherited', 'server-deadline'):
        run(endpoint(prefix + '-' + mode, abstract), mode)
    for mode in ('plain', 'pem', 'p12', 'invalid', 'bad-host', 'bad-ca'):
        python_peer(endpoint(prefix + '-' + mode, abstract), mode,
                    require_identity=mode in ('pem', 'p12', 'invalid'))
    for kind in ('plain', 'pem', 'p12'):
        python_peer(endpoint(prefix + '-deadline-' + kind, abstract),
                    'deadline-' + kind, stall=True)
for mode in ('tcp', 'tcp-identity'):
    run('unused', mode)
print('TLS upgrades: Unix path/abstract echo, mTLS PEM/P12, rejection, deadlines, timeout inheritance and TCP named calls passed')
