#!/usr/bin/env bash
# A cross --fast build gives the inliner ABLA_FAST_INLINE_THRESHOLD, so another value is
# another object: the whole-build cache must not hand the first value's object to the
# second. Two values build through one cache directory and each must equal the same value
# built without a cache; a repeat of one value must still hit the cache.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/fast-inline-cache"
rm -rf "$output_directory"
mkdir -p "$output_directory"
source="$project_root/tests/cases/wasm-gc/gc.ab"

build() { # threshold output [cache directory]
    local threshold=$1 output=$2 cache=${3:-}
    local flags=(--fast)
    [[ -n $cache ]] || flags+=(--no-cache)
    (cd "$project_root" &&
        ABLA_FAST_INLINE_THRESHOLD=$threshold ${cache:+ABLA_CACHE_DIR=$cache} \
        "$compiler" build "$source" --target-triple wasm32-unknown-unknown \
        --object-format wasm --emit object "${flags[@]}" -o "$output")
}

build 100 "$output_directory/plain-100.o"
build 1000 "$output_directory/plain-1000.o"
if cmp -s "$output_directory/plain-100.o" "$output_directory/plain-1000.o"; then
    echo "fast-inline-cache: the threshold does not change the object, the test proves nothing" >&2
    exit 1
fi

cache="$output_directory/cache"
build 100 "$output_directory/cached-100.o" "$cache"
build 1000 "$output_directory/cached-1000.o" "$cache"
cmp -s "$output_directory/plain-100.o" "$output_directory/cached-100.o" ||
    { echo "fast-inline-cache: the cached threshold-100 object differs" >&2; exit 1; }
cmp -s "$output_directory/plain-1000.o" "$output_directory/cached-1000.o" ||
    { echo "fast-inline-cache: threshold 1000 got another threshold's cached object" >&2; exit 1; }

# The same value again is a hit: no new entry, the same object.
before=$(find "$cache" -type f | wc -l)
build 1000 "$output_directory/again-1000.o" "$cache"
after=$(find "$cache" -type f | wc -l)
[[ $before -eq $after ]] ||
    { echo "fast-inline-cache: a repeat of one threshold missed the cache ($before to $after files)" >&2; exit 1; }
cmp -s "$output_directory/plain-1000.o" "$output_directory/again-1000.o" ||
    { echo "fast-inline-cache: the repeated threshold-1000 object differs" >&2; exit 1; }
echo "fast inline cache: each threshold gets its own object, a repeat hits the cache"
