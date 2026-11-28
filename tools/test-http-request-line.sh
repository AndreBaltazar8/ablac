#!/usr/bin/env bash
# The request line the HTTP/1 servers accept: the event servers and the blocking reader (serveHttp) refuse an empty or non-token method,
# no version, a bad version or a space in the target; fast and release builds, with and without GC stress.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-request-line"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/http-request-line/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" || status=$?
        [[ $status -eq 42 ]] || { echo "http request line: status $status (mode '$mode', stress $stress)" >&2; exit 1; }
    done
done
echo "HTTP request line: a request line that is not method SP target SP HTTP/1.x with a token method is refused by the shared check and the blocking reader, and a header end past the input is refused before the line is read"
