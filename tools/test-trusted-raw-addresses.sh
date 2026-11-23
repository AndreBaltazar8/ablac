#!/usr/bin/env bash
# The trusted contract (docs/language.md, "Trusted native implementations") puts the safety argument inside a `trusted` function, so its callers stay
# safe for any arguments. A public `trusted fun` that takes a raw address as an integer cannot make that argument: safe code can import and call it
# (`aesWipe(16, 8)` compiles and writes to address 16; #1139 area 7). There are about a hundred of them, used by the library's own modules. This test lists
# every `trusted fun` outside abla/unsafe, abla/runtime and abla/sys with an integer parameter named like an address, a pointer or a work area, and
# compares the list with tools/trusted-raw-addresses.txt: a new one fails (take the address as a NativeBuffer or a pointer type, or keep the function
# private to the code that needs it, or, if it cannot be avoided, add it to the list and say why in the commit); one that was removed or fixed must be
# removed from the list. The list can only shrink.
# Usage: tools/test-trusted-raw-addresses.sh        (regenerate the list: tools/test-trusted-raw-addresses.sh --update)
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
list=tools/trusted-raw-addresses.txt
out=build/trusted-raw-addresses
mkdir -p "$out"
names='address|pointer|ptr|memory|handle|work|out|input|output|table|buffer|src|dst|source|destination|f|m|a|b|p|q|base|state|key|curve'
export LC_ALL=C
grep -rEn "^trusted fun [A-Za-z0-9_.]+\(.*\b($names): int\b" stdlib --include='*.ab' \
    --exclude-dir=unsafe --exclude-dir=runtime --exclude-dir=sys |
    sed -E 's|^stdlib/([^:]+):[0-9]+:trusted fun ([A-Za-z0-9_.]+)\(.*|\1 \2|' | sort -u > "$out/current.txt"
if [[ ${1:-} == --update ]]; then
    cp "$out/current.txt" "$list"
    echo "trusted raw addresses: $(wc -l < "$list") entries written to $list"
    exit 0
fi
sort -c "$list"
comm -13 "$list" "$out/current.txt" > "$out/new.txt"
comm -23 "$list" "$out/current.txt" > "$out/resolved.txt"
if [[ -s $out/new.txt ]]; then
    echo "trusted raw addresses: a public trusted function that takes a raw address (see the comment of this script):" >&2
    cat "$out/new.txt" >&2
    exit 1
fi
if [[ -s $out/resolved.txt ]]; then
    echo "trusted raw addresses: remove these resolved entries from $list:" >&2
    cat "$out/resolved.txt" >&2
    exit 1
fi
echo "trusted raw addresses: $(wc -l < "$list") public trusted functions take a raw address (the list can only shrink)"
