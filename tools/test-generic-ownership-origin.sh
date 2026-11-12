#!/usr/bin/env bash
# Put a deliberately invalid generic in an isolated stdlib copy: regression
# coverage for diagnostics must not require shipping a broken public helper.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
cases="$root/tests/cases/generic-ownership-origin"
out="$root/build/generic-ownership-origin"
sysroot="$out/sysroot"
fail() { echo "generic ownership: $1" >&2; exit 1; }
rm -rf "$sysroot"
mkdir -p "$sysroot"
cp -a "$root/stdlib" "$sysroot/stdlib"
helper="$sysroot/stdlib/abla/array/ownership-probe/entry.ab"
mkdir -p "$(dirname "$helper")"
cp "$cases/helper.ab" "$helper"
type_helper="$sysroot/stdlib/abla/array/ownership-type-error/entry.ab"
mkdir -p "$(dirname "$type_helper")"
cp "$cases/helper-type-error.ab" "$type_helper"
export ABLA_SYSROOT="$sysroot" ABLA_CACHE_DIR="$out/cache"

# build NAME [SUFFIX]: build a case; stdout and stderr go to $out/NAME+SUFFIX.{out,err};
# the build's exit status is left in $build_status.
build() {
    build_status=0
    "$compiler" build "$cases/$1.ab" -o "$out/program" --fast --no-cache \
        > "$out/$1${2:-}.out" 2> "$out/$1${2:-}.err" || build_status=$?
}
# offset_of FILE TEXT: byte offset of the first occurrence, or nothing.
offset_of() { grep -boaF -e "$2" "$1" | head -n 1 | cut -d: -f1 || true; }

for entry in 'single|xs.invalidPop()|0' 'shared|xs.invalidPop()|2' 'shared-two|xs.invalidPop()|1' \
             'nested|xs.nestedPop()|0' 'mixed|xs.nestedPop()|2' 'cyclic|xs.cyclicPop(false)|0'; do
    IFS='|' read -r name call others <<< "$entry"
    source="$cases/$name.ab"
    build "$name"
    [[ $build_status -ne 0 ]] || fail "$name: invalid ownership accepted"
    begin=$(offset_of "$source" "$call")
    [[ -n $begin ]] || fail "$name: no call $call in the source"
    expected="source[semantic]:$source:$begin:$((begin + ${#call}))"
    # Split the diagnostics into blocks at each line starting `error[`.
    rm -f "$out/block."*
    awk -v dir="$out" '/^error\[/ { n++ } n > 0 { print > (dir "/block." n) }' "$out/$name.err"
    found=0
    for block in "$out"/block.*; do
        [[ -e $block ]] || continue
        head -n 1 "$block" | grep -qF ': ownership.' || continue
        found=1
        grep -qF -e "$expected" "$block" || { cat "$block" >&2; fail "$name: the caller site is missing: $expected"; }
        grep -qF -e "source[generic-helper]:$helper:" "$block" || fail "$name: no generic-helper source"
        [[ $(offset_of "$block" "$expected") -lt $(offset_of "$block" 'source[generic-helper]') ]] \
            || fail "$name: the helper came before the caller"
        grep -qF 'context[generic-instance]:' "$block" || fail "$name: no generic-instance context"
        grep -qF 'note: ownership error in this generic helper' "$block" || fail "$name: no helper note"
        if [[ $others -gt 0 ]]; then
            grep -qF "and $others other call site" "$block" || fail "$name: not 'and $others other call site'"
        else
            ! grep -qF 'other call site' "$block" || fail "$name: an unexpected 'other call site'"
        fi
    done
    [[ $found -eq 1 ]] || fail "$name: no ownership diagnostic: $(cat "$out/$name.err")"
    build "$name" -repeat
    cmp -s "$out/$name.err" "$out/$name-repeat.err" || fail "$name: unstable source order/count"
done

build plain
plain_source="$cases/plain.ab"
[[ $build_status -ne 0 ]] && grep -qF 'ownership.place-move-required' "$out/plain.err" || fail 'plain: no move diagnostic'
grep -qF "source[semantic]:$plain_source:" "$out/plain.err" || fail 'plain: no caller source'
! grep -qF 'generic-helper' "$out/plain.err" && ! grep -qF 'other call site' "$out/plain.err" || fail 'plain: helper text leaked'
build type-error
[[ $build_status -ne 0 ]] || fail 'bad generic definition accepted'
grep -qF "source[semantic]:$type_helper:" "$out/type-error.err" || fail "type-error: no source in the helper"
! grep -qF 'generic-helper' "$out/type-error.err" || fail 'type-error: helper note on an ordinary error'
build valid
[[ $build_status -eq 0 ]] || { cat "$out/valid.err" >&2; fail 'valid case failed to build'; }
status=0
(cd "$out" && ./program) || status=$?
[[ $status -eq 42 ]] || fail "valid program returned $status"
echo 'generic ownership: caller first, helper note, shared source order, nested/cyclic origins, other errors unchanged'
