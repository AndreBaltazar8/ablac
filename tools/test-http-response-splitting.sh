#!/usr/bin/env bash
# Response splitting (#1139 area 4, round 8): a response header whose name is not a token, or whose value has a CR, LF or NUL, is never written as
# given; every server path sends a plain 500 in its place (tests/cases/http-response-splitting: main.ab in process, servers.ab on the running event
# and HTTPS servers). The refusals' log lines go to standard error and are not checked here.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http-response-splitting
mkdir -p "$out"
for name in main servers; do
    "$compiler" build "tests/cases/http-response-splitting/$name.ab" -o "$out/$name" --no-cache > "$out/$name.build.log" 2>&1 ||
        { cat "$out/$name.build.log" >&2; exit 1; }
    timeout 120 "$out/$name" > "$out/$name.out" 2> "$out/$name.err" || { cat -v "$out/$name.out" >&2; echo "response splitting: $name failed" >&2; exit 1; }
    cat "$out/$name.out"
done
