#!/usr/bin/env bash
# Held native O1: artifact identity, exact ELF section cutoff and cache modes.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Linux ]]; then
    echo 'held O1: Linux ELF path only'
    exit 0
fi
compiler=${1:-$root/build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
work=$(mktemp -d "$root/build/held-o1-XXXXXX")
cache="$work/cache"
source="$work/main.ab"
output="$work/program"
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root} ABLA_CACHE_DIR="$cache" ABLA_COMPILER_MEMORY_TRACE=1
unset ABLA_KEEP_LLVM_TEXT ABLA_LLVM_OUT_OF_PROCESS
failed() { echo "held O1: artifacts and logs: $work" >&2; }
trap 'if [[ $? -ne 0 ]]; then failed; fi' EXIT
fail() { echo "held O1: $1" >&2; exit 1; }

# build LABEL [SETTING=VALUE]... -- [FLAG]...: an --o1 build in $work; its stderr is $work/LABEL.err.
build() {
    local label=$1 settings=() flags=()
    shift
    while [[ $# -gt 0 && $1 != -- ]]; do settings+=("$1"); shift; done
    [[ $# -eq 0 ]] || shift
    flags=("$@")
    (cd "$work" && env ${settings[@]+"${settings[@]}"} "$compiler" build "$source" -o "$output" --o1 \
        ${flags[@]+"${flags[@]}"} > "$label.out" 2> "$label.err") \
        || { cat "$work/$label.err" >&2; fail "$label did not build"; }
}
lowered() { grep -qF frontend.lowering.begin "$work/$1.err"; }
run() {
    local status=0
    (cd "$work" && "$output") || status=$?
    [[ $status -eq $1 ]] || fail "the program returned $status, expected $1"
}
text() { echo "$output.ll"; }
same() { cmp -s "$output" "$1" || fail "$2"; }

# Taking a function's address demands its boxed ELF wrapper and its section.
printf '%s\n' 'fun twice(value: int): int = value * 2' \
    'val callback: (int) -> int = twice' 'fun main: int = callback(21)' > "$source"
build cold
lowered cold || fail 'the cold build did not lower'
[[ ! -e $(text) ]] || fail 'the cold build left LLVM text'
run 42
cp "$output" "$work/cold.bin"
members=("$cache"/native-*-inprocess-o1-held-o1-single-v1-*.o)
[[ ${#members[@]} -eq 1 && -e ${members[0]} ]] || fail "expected one held object, found ${#members[@]}"
printf 'held-o1-cache-marker\n' > "$(text)"
build warm
! lowered warm || fail 'the warm build lowered again'
[[ $(cat "$(text)") == held-o1-cache-marker ]] || fail 'the warm build touched the LLVM text'
same "$work/cold.bin" 'the warm artifact differs'
# A frontend/cache record without its object is a miss, not a stale hit.
mv "${members[0]}" "${members[0]}.missing"
build missing-object
lowered missing-object || fail 'a missing object was a hit'
same "$work/cold.bin" 'the rebuilt artifact differs'
[[ ! -e $(text) ]] || fail 'the rebuild left LLVM text'
sed 's/callback(21)/callback(22)/' "$source" > "$source.new" && mv "$source.new" "$source"
build edited
lowered edited || fail 'an edited source was a hit'
run 44
cp "$output" "$work/held.bin"
build keep-text ABLA_KEEP_LLVM_TEXT=1
lowered keep-text || fail 'keep-text did not lower'
[[ -f $(text) ]] || fail 'keep-text left no LLVM text'
run 44
cp "$output" "$work/fallback.bin"
build held-after-text
! lowered held-after-text || fail 'the held build after text lowered again'
same "$work/held.bin" 'the held artifact changed after the text build'
# Both fallback requests use the same textual emitter and its own cache entry.
build out-of-process ABLA_LLVM_OUT_OF_PROCESS=1
same "$work/fallback.bin" 'the out-of-process artifact differs from the text fallback'
# The existing small text-cache path partitions boxed wrappers. Compare
# bytes without that independent layout choice, then check debug as well.
build small-held -- --no-cache
cp "$output" "$work/small.bin"
build small-text ABLA_KEEP_LLVM_TEXT=1 -- --no-cache
same "$work/small.bin" 'the small text artifact differs'
build debug-held -- -g --no-cache
cp "$output" "$work/debug.bin"
build debug-text ABLA_KEEP_LLVM_TEXT=1 -- -g --no-cache
same "$work/debug.bin" 'the debug text artifact differs'
# A large constant defeats instruction-only size estimates: keep the exact
# old section cutoff even when most printed bytes are in global data.
{
    printf 'val content = "'
    head -c 4194305 /dev/zero | tr '\0' a
    printf '"\n'
    printf '%s\n' 'fun twice(value: int): int = value * 2' 'val callback: (int) -> int = twice' \
        'fun main: int = if (content.size == 4194305) callback(21) else 1'
} > "$source"
build large-held -- --no-cache
run 42
cp "$output" "$work/large.bin"
build large-text ABLA_KEEP_LLVM_TEXT=1 -- --no-cache
same "$work/large.bin" 'the large text artifact differs'
trap - EXIT
rm -rf "$work"
echo 'held O1: exact sections, warm/missing/edited caches, text/debug fallbacks passed'
