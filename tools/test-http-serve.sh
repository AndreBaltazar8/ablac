#!/usr/bin/env bash
# The blocking HTTP server (serveHttp, serveHttpOnListener, serveHttpOnce) reads one connection at a time, so a connection that sends nothing, sends a byte now
# and then, or does not read its response held the whole server for ever (#1139: abla.dev runs it). It now has deadlines (HttpServeOptions) and reads in time
# proportional to the bytes received. tests/cases/http-serve/server.ab is the server on an ephemeral loopback port with deadlines of 700 ms (first byte), 1000 ms
# (head), 2000 ms (request) and 1000 ms (response); the clients are bash on /dev/tcp. Checked:
#   - a connection that sends nothing is closed by the first-byte deadline, and a request sent meanwhile is answered right after it;
#   - a head, a body of known length and a chunked body each sent a byte every 100 ms are closed by their deadline, with no answer;
#   - a client that does not read a 24 MB response does not hold the server past the response deadline;
#   - a chunked request sent in pieces that split its size lines and its data, with an extension and trailers, is decoded and answered, and an ordinary request is
#     answered at once;
#   - the server's CPU time for a chunked body of 80,000 one-byte chunks sent one at a time stays small (the body used to be framed again at every read).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$project_root/build"
t=$(mktemp -d "$project_root/build/http-serve.XXXXXX")
export ABLA_SYSROOT=$project_root
server=
cleanup() { [[ -z $server ]] || kill "$server" 2> /dev/null || true; rm -rf -- "$t"; }
trap cleanup EXIT
failures=0
fail() { printf 'http serve: %s\n' "$1" >&2; failures=$((failures + 1)); }
"$compiler" build "$project_root/tests/cases/http-serve/server.ab" -o "$t/server" --fast --no-cache > "$t/build.log" 2>&1 || { cat "$t/build.log" >&2; fail "the server did not build"; exit 1; }
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }
over() { awk -v v="$1" -v l="$2" 'BEGIN { exit !(v > l) }'; }
start() { # start FIRST HEAD REQUEST RESPONSE
    [[ -z $server ]] || { kill "$server" 2> /dev/null || true; wait "$server" 2> /dev/null || true; }
    : > "$t/port"
    "$t/server" "$@" > "$t/port" 2> /dev/null & server=$!
    local i
    for i in $(seq 1 600); do [[ -s $t/port ]] && break; sleep 0.1; done
    port=$(head -n 1 "$t/port")
    [[ -n $port ]] || { fail "the server did not start"; exit 1; }
}
cpu() { awk '{ printf "%.2f", ($14 + $15) / 100 }' "/proc/$server/stat"; }
# get SECONDS: one GET / with a limit; the status line, or TIMEOUT
get() { timeout "$1" bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; printf 'GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n' >&3; head -c 12 <&3" 2> /dev/null || echo TIMEOUT; }
# closed_after SECONDS FD: how long until the server closes the descriptor (read returns EOF), or more than SECONDS
closed_after() { local started; started=$(now); if timeout "$1" bash -c "cat <&$2 > /dev/null" 2> /dev/null; then since "$started"; else echo "$1+"; fi; }

# 1. A connection that sends nothing.
start 700 1000 2000 1000
exec 4<> "/dev/tcp/127.0.0.1/$port"
started=$(now)
answer=$(get 6)
took=$(since "$started")
[[ $answer == 'HTTP/1.1 200' ]] || fail "a request behind a silent connection was not answered ($answer)"
over "$took" 3 && fail "a request behind a silent connection waited $took s (first-byte deadline 0.7 s)"
exec 4<&-

# 2. A head sent a byte every 100 ms.
start 700 1000 2000 1000
exec 4<> "/dev/tcp/127.0.0.1/$port"
started=$(now)
( for c in G E T ' ' / ' ' H T T P / 1 . 1 $'\r' $'\n' H o s t : ' ' a $'\r' $'\n' X-A: ' ' b $'\r' $'\n' X-B: ' ' b; do printf '%s' "$c" >&4 || exit 0; sleep 0.1; done ) 2> /dev/null &
dripper=$!
closed=$(closed_after 6 4)
kill "$dripper" 2> /dev/null || true
over "${closed%+}" 3.5 && fail "a head sent a byte at a time was not closed by its deadline (closed after $closed s; deadline 1 s)"
exec 4<&-

# 3. A body of known length sent a byte every 100 ms: the request deadline (2 s), not the head deadline (the head is complete).
start 700 1000 2000 1000
exec 4<> "/dev/tcp/127.0.0.1/$port"
printf 'POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 1000\r\n\r\n' >&4
started=$(now)
( for i in $(seq 1 100); do printf 'x' >&4 || exit 0; sleep 0.1; done ) 2> /dev/null &
dripper=$!
closed=$(closed_after 8 4)
kill "$dripper" 2> /dev/null || true
over "${closed%+}" 4 && fail "a body of known length sent a byte at a time was not closed by the request deadline (closed after $closed s; deadline 2 s)"
over 1.5 "${closed%+}" && fail "a body whose head was complete was closed after $closed s, before the request deadline (2 s)"
exec 4<&-

# 4. A chunked body sent a byte every 100 ms.
start 700 1000 2000 1000
exec 4<> "/dev/tcp/127.0.0.1/$port"
printf 'POST /echo HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n' >&4
( for i in $(seq 1 100); do printf '1\r\nx\r\n' >&4 || exit 0; sleep 0.1; done ) 2> /dev/null &
dripper=$!
closed=$(closed_after 8 4)
kill "$dripper" 2> /dev/null || true
over "${closed%+}" 4 && fail "a chunked body sent a chunk at a time was not closed by the request deadline (closed after $closed s)"
exec 4<&-

# 5. A client that asks for 24 MB and does not read.
start 700 1000 2000 1000
exec 5<> "/dev/tcp/127.0.0.1/$port"
printf 'GET /big HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n' >&5
started=$(now)
answer=$(get 8)
took=$(since "$started")
[[ $answer == 'HTTP/1.1 200' ]] || fail "a request behind a client that does not read its response was not answered ($answer)"
over "$took" 4 && fail "a request behind a client that does not read its response waited $took s (response deadline 1 s)"
exec 5<&-

# 6. Ordinary and awkward requests are answered.
start 700 1000 2000 1000
[[ $(get 3) == 'HTTP/1.1 200' ]] || fail "an ordinary request was not answered"
chunked() { # chunked PIECE...: a chunked POST sent in the given pieces, 50 ms apart; prints the body of the answer
    exec 4<> "/dev/tcp/127.0.0.1/$port"
    printf 'POST /echo HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n' >&4
    local piece
    for piece in "$@"; do printf '%b' "$piece" >&4; sleep 0.05; done
    timeout 5 cat <&4 2> /dev/null | tail -n 1 || true
    exec 4<&-
}
body=$(chunked '5\r' '\nhel' 'lo\r\n0' 'a;ext=1\r\n0123' '456789\r\n0\r' '\nTrailer: v\r\n\r\n')
[[ $body == 15 ]] || fail "a chunked request split in awkward pieces was decoded as '$body' bytes, not 15"
body=$(chunked '10\r\n0123456789ab' 'cdef\r\n0\r\n\r\n')
[[ $body == 16 ]] || fail "a chunk sent in two pieces was decoded as '$body' bytes, not 16"
body=$(chunked 'zz\r\n0\r\n\r\n')
[[ $body != 2 ]] || fail "an invalid chunk size was accepted"
start 700 1000 2000 1000
[[ $(get 3) == 'HTTP/1.1 200' ]] || fail "the server did not survive the refused requests"

# 7. A chunked body of 80,000 one-byte chunks, one write each: the server's CPU time stays small.
start 0 0 0 0
before=$(cpu)
exec 4<> "/dev/tcp/127.0.0.1/$port"
printf 'POST /echo HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n' >&4
for ((i = 0; i < 80000; i++)); do printf '1\r\nx\r\n' >&4; done
printf '0\r\n\r\n' >&4
answer=$(timeout 60 cat <&4 2> /dev/null | tail -n 1 || true)
exec 4<&-
used=$(awk -v a="$(cpu)" -v b="$before" 'BEGIN { printf "%.2f", a - b }')
printf "http serve: server CPU for 80,000 one-byte chunks sent one at a time: %s s\n" "$used"
[[ $answer == 80000 ]] || fail "80,000 one-byte chunks were decoded as '$answer' bytes"
over "$used" 1.5 && fail "the server used $used s of CPU for 80,000 one-byte chunks sent one at a time (it should be a fraction of a second)"

[[ $failures == 0 ]] || { printf 'http serve: %d failure(s)\n' "$failures" >&2; exit 1; }
echo "http serve: a silent connection, a dripped head or body and an unread response are closed by their deadlines, awkward chunked requests are decoded, and the work is proportional to the bytes"
