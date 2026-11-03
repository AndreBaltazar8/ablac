#!/usr/bin/env bash
# SIGTERM must wake idle HTTP/WebSocket readiness loops, not wait for their
# one-second poll timeout. Wait for epoll before timing, excluding startup.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Linux ]]; then
    echo 'event shutdown: skipped outside Linux'
    exit 0
fi
out="$root/build/event-shutdown"
mkdir -p "$out"
"$compiler" build "$root/tests/cases/bootstrap/event-shutdown.ab" \
    -o "$out/program" --fast --no-cache
python3 - "$out/program" <<'PY'
import pathlib, select, signal, socket, subprocess, sys, time
for mode in ['http', 'websocket']:
    for trial in range(2):
        p = subprocess.Popen([sys.argv[1], mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            if not select.select([p.stdout], [], [], 10)[0]:
                raise SystemExit(f'{mode}: no listening port')
            port = int(p.stdout.readline())
            # Give the loop a socket event, then observe it waiting again so
            # the old timeout has almost its full second left.
            with socket.create_connection(('127.0.0.1', port), timeout=2):
                pass
            deadline = time.monotonic() + 5
            waiting = False
            while time.monotonic() < deadline and p.poll() is None:
                state = pathlib.Path(f'/proc/{p.pid}/wchan').read_text()
                if 'epoll' in state or 'ep_poll' in state:
                    waiting = True
                    break
                time.sleep(.001)
            if not waiting:
                raise SystemExit(f'{mode}: never entered epoll wait')
            began = time.monotonic()
            p.send_signal(signal.SIGTERM)
            try:
                status = p.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                raise SystemExit(f'{mode}: SIGTERM did not wake the idle server within 500ms')
            elapsed = time.monotonic() - began
            if status != 42:
                raise SystemExit(f'{mode}: shutdown status {status}, expected 42')
            print(f'{mode}: idle SIGTERM shutdown {elapsed * 1000:.1f}ms')
        finally:
            if p.poll() is None:
                p.kill()
            p.wait()
PY
