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
port=$((30000 + $$ % 20000))
expected=$(printf 'GET /one keepalive-test text/x-test\n200 connects=1\nGET /two keepalive-test text/x-test\n200 connects=0\nGET /three keepalive-test text/x-test\n200 connects=0\n')
for build in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/http-keepalive/server.ab -o "$out/server" $build --no-cache >"$out/build.log" 2>&1 ||
        { cat "$out/build.log" >&2; exit 1; }
    for mode in noescape handler; do
        # A port nothing listens on: other tools (adb, say) hold hundreds of ports and never answer on them.
        port=$((port + 1))
        while (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do port=$((port + 1)); done
        "$out/server" "$port" "$mode" &
        pid=$!
        for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done
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
