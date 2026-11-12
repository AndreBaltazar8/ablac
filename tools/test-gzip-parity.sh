#!/usr/bin/env bash
# Use the gzip-inflate corpus (its committed fixtures) from a separate output directory so this
# test can run concurrently with the unchanged test-gzip-inflate.sh suite.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out=build/gzip-parity
mkdir -p "$out"
"$compiler" build tests/cases/gzip-stream/parity.ab -o "$out/check" --fast --no-cache
"$compiler" build tests/cases/gzip-stream/record.ab -o "$out/record" --fast --no-cache
fixtures=tests/cases/gzip-inflate/fixtures
tools/verify-fixture-manifest.sh "$fixtures"
: > "$out/empty"
printf hello > "$out/optional.raw"
awk 'BEGIN { for (i = 0; i < 130000; i++) print "large compressed input 0123456789" }' > "$out/large"
for level in 0 1 6 9; do "$out/check" "$fixtures/raw" "$fixtures/level$level.gz"; done
for level in 1 6 9; do
    gzip -n -"$level" -c "$fixtures/raw" > "$out/system-$level.gz"
    "$out/check" "$fixtures/raw" "$out/system-$level.gz"
done
gzip -n -6 -c "$out/large" > "$out/large.gz"
"$out/check" "$out/large" "$out/large.gz"
"$out/check" "$out/empty" "$fixtures/empty.gz"
"$out/check" "$out/optional.raw" "$fixtures/optional.gz"
for input in "$fixtures"/bad-*; do "$out/check" "$fixtures/raw" "$input" invalid; done
tools/verify-fixture-manifest.sh tests/cases/gzip-stream/fixtures
"$out/record" tests/cases/gzip-stream/fixtures/mutations.gz > "$out/mutations.actual"
gzip -dc tests/cases/gzip-stream/fixtures/mutations.expected.gz > "$out/mutations.expected"
cmp "$out/mutations.expected" "$out/mutations.actual"
printf '%s\n' 'gzip-parity: corpus and old-decoder mutation transcript pass'
