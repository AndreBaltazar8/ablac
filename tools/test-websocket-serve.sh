#!/usr/bin/env bash
# The blocking WebSocket server (serveWebSockets, serveWebSocketOnce) runs the handler on the thread that accepts, so a client that sends nothing before the upgrade,
# trickles a frame after it, or does not read what the handler writes held every other client for ever (#1139). It now has deadlines (WebSocketServeOptions).
# tests/cases/websocket-serve/server.ab is the server on an ephemeral loopback port with deadlines of 700 ms (first byte), 1000 ms (head), 2000 ms (request),
# 1000 ms (response), 800 ms (idle read), 1500 ms (one frame) and 1000 ms (one write); the clients are bash on /dev/tcp. Checked:
#   - a connection that sends nothing, and a head sent a byte at a time, are closed by their deadlines, and a client behind them is served;
#   - after the upgrade a client that sends nothing is closed by the idle deadline, one that sends a frame a byte every 100 ms by the frame deadline (the idle deadline
#     restarts on every byte, so it does not end it), and a client that does not read what the handler pushes by the write deadline;
#   - an ordinary session works: the upgrade, a masked text frame echoed back.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$project_root/build"
t=$(mktemp -d "$project_root/build/websocket-serve.XXXXXX")
export ABLA_SYSROOT=$project_root
server=
cleanup() { [[ -z $server ]] || kill "$server" 2> /dev/null || true; rm -rf -- "$t"; }
trap cleanup EXIT
failures=0
fail() { printf 'websocket serve: %s\n' "$1" >&2; failures=$((failures + 1)); }
"$compiler" build "$project_root/tests/cases/websocket-serve/server.ab" -o "$t/server" --fast --no-cache > "$t/build.log" 2>&1 || { cat "$t/build.log" >&2; fail "the server did not build"; exit 1; }
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }
over() { awk -v v="$1" -v l="$2" 'BEGIN { exit !(v > l) }'; }
start() {
    [[ -z $server ]] || { kill "$server" 2> /dev/null || true; wait "$server" 2> /dev/null || true; }
    : > "$t/port"
    "$t/server" 700 1000 2000 1000 800 1500 1000 > "$t/port" 2> /dev/null & server=$!
    local i
    for i in $(seq 1 600); do [[ -s $t/port ]] && break; sleep 0.1; done
    port=$(head -n 1 "$t/port")
    [[ -n $port ]] || { fail "the server did not start"; exit 1; }
}
handshake() { printf 'GET %s HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' "$1"; }
# upgrade PATH: the status line of the upgrade on a new connection (a fresh one each time), or TIMEOUT
upgrade() { timeout "$2" bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; printf 'GET $1 HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' >&3; head -c 12 <&3" 2> /dev/null || echo TIMEOUT; }
closed_after() { local started; started=$(now); if timeout "$1" bash -c "cat <&$2 > /dev/null" 2> /dev/null; then since "$started"; else echo "$1+"; fi; }

# 1. A connection that sends nothing before the upgrade.
start
exec 4<> "/dev/tcp/127.0.0.1/$port"
started=$(now)
answer=$(upgrade /echo 6)
took=$(since "$started")
[[ $answer == 'HTTP/1.1 101' ]] || fail "an upgrade behind a silent connection was not answered ($answer)"
over "$took" 3 && fail "an upgrade behind a silent connection waited $took s (first-byte deadline 0.7 s)"
exec 4<&-

# 2. A head sent a byte every 100 ms.
start
exec 4<> "/dev/tcp/127.0.0.1/$port"
( for c in G E T ' ' / e c h o ' ' H T T P / 1 . 1 $'\r' $'\n' H o s t : ' ' a $'\r' $'\n' X-A: ' ' b $'\r' $'\n' X-B: ' ' b; do printf '%s' "$c" >&4 || exit 0; sleep 0.1; done ) 2> /dev/null &
dripper=$!
closed=$(closed_after 6 4)
kill "$dripper" 2> /dev/null || true
over "${closed%+}" 3.5 && fail "an upgrade head sent a byte at a time was not closed by its deadline (closed after $closed s; deadline 1 s)"
exec 4<&-

# 3. After the upgrade: nothing sent (the idle deadline), a frame sent a byte every 100 ms (the frame deadline), a client that does not read (the write deadline).
start
exec 4<> "/dev/tcp/127.0.0.1/$port"
handshake /echo >&4
started=$(now)
closed=$(closed_after 6 4)
over "${closed%+}" 3.5 && fail "an upgraded connection that sends nothing was not closed by the idle deadline (closed after $closed s; deadline 0.8 s)"
exec 4<&-
exec 4<> "/dev/tcp/127.0.0.1/$port"
handshake /echo >&4
sleep 0.3
( printf '\x82\xfe\x03\xe8\x00\x00\x00\x00' >&4; for i in $(seq 1 200); do printf 'x' >&4 || exit 0; sleep 0.1; done ) 2> /dev/null &
dripper=$!
started=$(now)
timeout 8 bash -c 'head -c 101 <&4 > /dev/null' 2> /dev/null || true
closed=$(closed_after 8 4)
kill "$dripper" 2> /dev/null || true
over "${closed%+}" 4 && fail "a frame sent a byte at a time was not closed by the frame deadline (closed after $closed s more; deadline 1.5 s from its first byte)"
exec 4<&-
exec 5<> "/dev/tcp/127.0.0.1/$port"
handshake /push >&5
started=$(now)
answer=$(upgrade /echo 12)
took=$(since "$started")
[[ $answer == 'HTTP/1.1 101' ]] || fail "an upgrade behind a client that does not read what the handler writes was not answered ($answer)"
over "$took" 6 && fail "an upgrade behind a client that does not read waited $took s (write deadline 1 s)"
exec 5<&-

# 4. An ordinary session.
start
reply=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; printf 'GET /echo HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' >&3; sleep 0.3; printf '\x81\x85\x00\x00\x00\x00hello' >&3; sleep 0.3; head -c 400 <&3 | strings | tr -d '\r\n' | grep -o 'hello' | head -n 1" 2> /dev/null || true)
[[ $reply == hello ]] || fail "an ordinary session did not echo its message ('$reply')"

[[ $failures == 0 ]] || { printf 'websocket serve: %d failure(s)\n' "$failures" >&2; exit 1; }
echo "websocket serve: a silent connection, a dripped head, an idle or dripped frame and an unread write are closed by their deadlines, and an ordinary session echoes"
