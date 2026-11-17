#!/usr/bin/env bash
# padStart and padEnd pad to a byte count with whole code points of the pad: valid UTF-8 in, valid UTF-8 out (it was cut
# in the middle of a code point), at run time and under `#`, in a fast and a release build.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/text-padding
rm -rf "$out"
mkdir -p "$out"
expected=$(cat <<'TEXT'
ascii xyxab|5|true abxyx|5|true 007|3|true
two-byte é|2|true éé|4|true abé|4|true
three-byte 日ab|5|true 日日ab|8|true ab|2|true
four-byte 😀|4|true a|1|true a😀|5|true
mixed aé日a|7|true aé日|6|true aé日aé|9|true
none abc|3|true abc|3|true ab|2|true ab|2|true
empty pad ab|2|true |0|true
bad pad bytes 3 3 3
unchanged héllo|6|true héllo|6|true hélloé|8|true
TEXT
)
for variant in fast release; do
    flags=(--fast)
    [[ $variant == fast ]] || flags=()
    "$compiler" build tests/cases/text-padding/main.ab -o "$out/main-$variant" ${flags[@]+"${flags[@]}"} --no-cache
    got=$("$out/main-$variant")
    [[ $got == "$expected" ]] || { echo "text padding ($variant) printed:" >&2; echo "$got" >&2; echo "expected:" >&2; echo "$expected" >&2; exit 1; }
done
echo "text padding: padStart and padEnd keep valid UTF-8 valid, at run time and under #"
