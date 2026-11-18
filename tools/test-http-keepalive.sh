#!/usr/bin/env bash
# Keep-alive on the event server: three requests on ONE connection, each answered 200 with its own headers read back
# (User-Agent and Accept, the lines a stale header-name table drops), for the region (noescape) handler and the
# ordinary one, in a fast and a release build. A 400 on the second request was the symptom of httpNameClasses being
# flattened inside the first request's region (v0.2.54 and later): the second request's lines read as malformed.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-keepalive"
mkdir -p "$out"
cd "$root"
pid=""
trap '[[ -z $pid ]] || kill -9 "$pid" 2>/dev/null || true' EXIT
# Below the kernel's ephemeral range (32768 and up, ip_local_port_range): outgoing connections of the machine's other tests
# take their source ports from there, and a port one of them holds (or holds in TIME_WAIT) cannot be bound.
port=$((20000 + $$ % 10000))
expected=$(printf 'GET /one keepalive-test text/x-test\n200 connects=1\nGET /two keepalive-test text/x-test\n200 connects=0\nGET /three keepalive-test text/x-test\n200 connects=0\n')
for build in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/http-keepalive/server.ab -o "$out/server" $build --no-cache >"$out/build.log" 2>&1 ||
        { cat "$out/build.log" >&2; exit 1; }
    for mode in noescape handler; do
        # A port nothing listens on: other tools (adb, say) hold hundreds of ports and never answer on them. The
        # server is ready when the kernel lists its socket as listening (nothing connects to it, so no request is
        # spent on a probe); a server that exits first lost the port to another process, and the next port is tried.
        started=0
        for _ in $(seq 20); do
            port=$((port + 1))
            while (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do port=$((port + 1)); done
            "$out/server" "$port" "$mode" &
            pid=$!
            hex=$(printf '%04X' "$port")
            deadline=$((SECONDS + 120))
            while kill -0 "$pid" 2>/dev/null && ((SECONDS < deadline)); do
                if awk -v want=":$hex" '$4 == "0A" && $2 ~ want "$" { found = 1 } END { exit !found }' /proc/net/tcp; then
                    started=1
                    break
                fi
                sleep 0.05
            done
            [[ $started -eq 1 ]] && break
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            pid=""
            ((SECONDS < deadline)) || break
        done
        [[ $started -eq 1 ]] || { echo "http keep-alive ($mode, build '$build'): the server never listened" >&2; exit 1; }
        url=http://127.0.0.1:$port
        status=0
        curl -s --max-time 20 -A keepalive-test -H 'Accept: text/x-test' -w '%{http_code} connects=%{num_connects}\n' \
            "$url/one" "$url/two" "$url/three" >"$out/$mode.txt" || status=$?
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pid=""
        if [[ $status -ne 0 || $(cat "$out/$mode.txt") != "$expected" ]]; then
            echo "http keep-alive ($mode, build '$build'): three requests on one connection did not all succeed (curl status $status):" >&2
            cat "$out/$mode.txt" >&2
            exit 1
        fi
    done
done
echo 'HTTP keep-alive: three requests on one connection, region and ordinary handlers, fast and release builds, headers read back on each'
