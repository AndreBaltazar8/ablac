#!/usr/bin/env bash
# Regression cases from the review of the HTTP/2 server (tests/cases/http2/review.ab), in process against H2Server.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http2-review
mkdir -p "$out"
"$compiler" build tests/cases/http2/review.ab -o "$out/review" --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
"$out/review"
