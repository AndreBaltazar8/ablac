#!/usr/bin/env bash
# The trusted contract (docs/language.md, "Trusted native implementations") puts the safety argument inside a `trusted` function, so its callers stay
# safe for any arguments. A public `trusted fun` that takes a raw address as an integer cannot make that argument: safe code could import and call it
# (`aesWipe(16, 8)` wrote to address 16; #1139 area 7). The standard library therefore keeps such functions out of its public modules: `private`
# when nothing outside the file calls them, and else in a file of the module that is not its entry (`// public: none`, docs/language.md: a name
# from such a file is internal, no import makes it visible, and the error names the public surface). This test lists every `trusted fun` in an
# ENTRY file of the library (outside abla/unsafe, abla/runtime and abla/sys) with an integer parameter named like an address, a pointer or a work
# area, and compares the list with tools/trusted-raw-addresses.txt, the named exceptions: a new public one fails (take the address as a NativeBuffer
# or a pointer type, make the function private, or move it to an internal file of its module), and so does an exception that is gone.
# Exceptions (each needs its reason here):
#   bnDecode, bnEncode, bnEqual, bnLessPublic, bnRelease (abla/crypto/bignum): the big-number engine works on raw work areas. No checked form
#       exists yet (a BigNumber type is for André to decide) and abla-blockchain's wallet uses it; the module's header says it is not a safe API.
#   tlsControlInt, tlsControlPointer, tlsCloseHandle (abla/tls/hosted): read a field of, or close, the control block a TLS connection's `handle` names. NovaKind and
#       abla-postgres, abla-s3 and the crew plugin call them with the handle of a connection of their own; a checked form would need a registry of live handles.
#   ablaCtBridgeArgHandle (abla/compiler/bridge): `handle` indexes the compiler's table of compile-time objects, and the host refuses one that
#       is not in it (tests/cases/ct-bridge/invalid-arguments.ab): it is no address.
# Usage: tools/test-trusted-raw-addresses.sh        (regenerate the list: tools/test-trusted-raw-addresses.sh --update)
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
list=tools/trusted-raw-addresses.txt
out=build/trusted-raw-addresses
mkdir -p "$out"
names='address|pointer|ptr|memory|handle|work|out|input|output|table|buffer|src|dst|source|destination|f|m|a|b|p|q|base|state|key|curve'
export LC_ALL=C
grep -rEn "^trusted fun [A-Za-z0-9_.]+\(.*\b($names): int\b" stdlib --include='entry.ab' \
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
    echo "trusted raw addresses: a public trusted function that takes a raw address in an entry file (see the comment of this script):" >&2
    cat "$out/new.txt" >&2
    exit 1
fi
if [[ -s $out/resolved.txt ]]; then
    echo "trusted raw addresses: remove these resolved entries from $list:" >&2
    cat "$out/resolved.txt" >&2
    exit 1
fi
echo "trusted raw addresses: $(wc -l < "$list") named exceptions, no other public trusted function of an entry file takes a raw address"
