#!/usr/bin/env bash
# Sizes that wrap (#1139 area 7): a string longer than 2^62 bytes (a rope names a length without holding the bytes, so
# doubling a string 62 times makes one with no allocation), a filledArray count whose byte size wraps, a ByteBuffer whose
# count wraps. Each must panic with its reason (exit 101); before the checks a wrapped total sized a buffer that the whole
# rope or array was then written into, a heap overwrite from safe code.
set -euo pipefail
ulimit -c 0

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/size-overflow"
out="$project_root/build/size-overflow"
mkdir -p "$out"
fail() { echo "size overflow: $*" >&2; exit 1; }

"$compiler" build "$cases/main.ab" -o "$out/main"
expect_panic() { # case message-fragment
    local status
    set +e
    "$out/main" "$1" > "$out/$1.out" 2> "$out/$1.err"
    status=$?
    set -e
    [[ $status -eq 101 ]] || fail "$1 exited $status (not a panic): $(head -c 200 "$out/$1.err")"
    grep -Eq -- "^panic: $2" "$out/$1.err" || fail "$1: $(head -c 200 "$out/$1.err")"
}
expect_panic concat 'string too long'
expect_panic concat-sum 'string too long'
expect_panic concat4 'string too long'
expect_panic repeat 'string too long'
expect_panic filled 'filledArray size too large \(2305843009213693952\)'
expect_panic filled-string 'filledArray size too large'
expect_panic filled-max 'filledArray size too large \(9223372036854775807\)'
# Two chunks of 2^62 bytes: the second is not appended (the count would wrap), so the join is of 2^62 bytes, which is an
# allocation that fails (a panic), not a copy past a buffer.
expect_panic bytes-chunks '(out of memory|memory limit exceeded)'
# appendFixed with a decimals past what a buffer holds appends nothing: the later append lands where it should.
"$out/main" bytes-fixed > "$out/bytes-fixed.out" || fail "bytes-fixed failed"
[[ $(cat "$out/bytes-fixed.out") == 5 ]] || fail "bytes-fixed: $(cat "$out/bytes-fixed.out")"
"$out/main" bytes-fixed-ok > "$out/bytes-fixed-ok.out" || fail "appendFixed with a few decimals fails"
[[ $(cat "$out/bytes-fixed-ok.out") == '0.00000000000000000005-0.25' ]] || fail "appendFixed: $(cat "$out/bytes-fixed-ok.out")"
"$out/main" fine > "$out/fine.out" || fail "a string of 2^61 bytes is refused"
[[ $(cat "$out/fine.out") == 2305843009213693952 ]] || fail "the length of a 2^61 byte string: $(cat "$out/fine.out")"
echo "size overflow: strings past 2^62 bytes and filled arrays whose size wraps, byte buffers whose count wraps panic"
