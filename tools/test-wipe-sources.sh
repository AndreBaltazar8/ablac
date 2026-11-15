#!/usr/bin/env bash
# Wiping a string that shares its bytes (see the rule above cryptoOwnedCopy in stdlib/abla/crypto/entry.ab): a slice is a view of its parent and a
# long concatenation a rope over its parts, so a wipe of one zeroes the other and a wipe of a slice leaves the rest of the parent. Two
# structural checks over the standard library, which no test of a single site can give:
#  1. every string is wiped through one function, cryptoWipeString (tlsWipe is its alias): nothing else writes zeros through
#     ablaUnsafeStringAddress, so the rule has one place to be kept;
#  2. the argument of a wipe is a name or a field, never a slice or a concatenation made on the spot (those are views and ropes by construction).
# A line that must be exempt carries `wipe-ok` and a reason.
set -uo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
status=0
# 1. A function that gets a string's address and stores through a volatile pointer is a string wipe of its own.
while IFS= read -r file; do
    awk -v file="$file" '
        /^[[:space:]]*(private |@noinline |@inline |trusted |export )*fun / { name = $0; has_address = 0; has_store = 0; start = NR }
        /ablaUnsafeStringAddress\(/ { has_address = 1 }
        /ablaUnsafeVolatileStoreU8\(/ { has_store = 1 }
        /^}/ { if (has_address && has_store && file != "stdlib/abla/crypto/entry.ab") { print file ":" start ": a string wipe of its own (use cryptoWipeString): " name; found = 1 } has_address = 0; has_store = 0 }
        END { exit found ? 1 : 0 }
    ' "$file" || status=1
done < <(grep -rl "ablaUnsafeVolatileStoreU8(" stdlib --include=*.ab)
# 2. The argument of a string wipe.
if grep -rnE '(tlsWipe|cryptoWipeString)\(.*(\.slice\(| \+ )' stdlib --include=*.ab | grep -v 'wipe-ok'; then
    echo "test-wipe-sources: a string wipe of a slice or a concatenation (a view or a rope: copy it with cryptoOwnedCopy first)" >&2
    status=1
fi
[[ $status -eq 0 ]] && echo "wipe sources ok: one string wipe, no wipe of a slice or a concatenation"
exit $status
