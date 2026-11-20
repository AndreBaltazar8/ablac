#!/usr/bin/env bash
# The gzip decoder against the one before its fast path (tests/cases/gzip-inflate-diff/old-gzip.ab): the same data, errors and stream chunks over gzip files made by the system gzip at several
# levels from files of several kinds and by our encoder, and over damaged copies (flipped bits, truncations, trailing bytes, output limits). Usage: tools/test-gzip-inflate-diff.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/gzip-inflate-diff
rm -rf "$out"
mkdir -p "$out/files"
awk 'BEGIN { for (i = 0; i < 20000; i++) printf "{\"id\":%d,\"name\":\"Item number %d\",\"price\":%d.5,\"tags\":[\"a\",\"b\"],\"ok\":%s}\n", i, i, i % 977, (i % 3 == 0 ? "true" : "false") }' > "$out/json.txt"
head -c 300000 /dev/urandom > "$out/random.bin"
cat tests/cases/gzip-inflate/fixtures/raw stdlib/abla/http/entry.ab stdlib/abla/json/entry.ab > "$out/source.txt"
: > "$out/empty.txt"
printf 'a' > "$out/one.txt"
awk 'BEGIN { for (i = 0; i < 90000; i++) printf "ab" }' > "$out/runs.txt"
for name in json.txt random.bin source.txt empty.txt one.txt runs.txt; do
    for level in 1 6 9; do gzip -n -"$level" -c "$out/$name" > "$out/files/$name.$level.gz"; done
done
gzip -c "$out/source.txt" > "$out/files/named.gz"
"$compiler" build tests/cases/gzip-inflate-diff/main.ab -o "$out/test" --no-cache
result=$(ABLA_MAX_SECONDS=1200 "$root/tools/run-limited.sh" "$out/test" "$out/files") || { echo "gzip-inflate-diff: $result" >&2; exit 1; }
[[ $result == 'gzip-inflate-diff ok'* ]] || { echo "gzip-inflate-diff: $result" >&2; exit 1; }
echo "ok   $result"
