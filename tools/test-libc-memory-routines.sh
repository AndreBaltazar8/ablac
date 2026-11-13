#!/usr/bin/env bash
# The memory and string routines an x86-64 Linux executable defines itself
# (#806): tests/cases/libc-memory-routines checks memcpy, memmove, memset,
# memcmp, bcmp and strlen against a byte formula, release and --fast; each
# build must define every routine locally and import none of them.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo 'libc memory routines: x86-64 Linux only (macOS keeps libSystem)'
    exit 0
fi
out=build/libc-memory-routines
rm -rf "$out"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/libc-memory-routines/main.ab -o "$out/$mode" "${flags[@]}"
    actual=$("$out/$mode")
    [[ $actual == 'libc memory routines: '*' checks agree' ]] || {
        printf 'libc memory routines (%s): %s\n' "$mode" "$actual" >&2; exit 1; }
    # The symbol lists go to files first: `nm | grep -q` under pipefail fails when grep leaves early and nm dies of SIGPIPE,
    # which a --fast binary's long list makes happen from time to time (a flake under load).
    nm -D --undefined-only "$out/$mode" 2> /dev/null | awk '{print $NF}' | sed 's/@.*//' > "$out/$mode.imports" || true
    nm "$out/$mode" > "$out/$mode.symbols"
    for routine in memcpy memmove memset memcmp bcmp strlen; do
        if grep -qx "$routine" "$out/$mode.imports"; then
            echo "libc memory routines ($mode): $routine is imported" >&2; exit 1
        fi
        grep -qE " t $routine\$" "$out/$mode.symbols" || {
            echo "libc memory routines ($mode): $routine is not a local definition" >&2; exit 1; }
    done
done
echo "$actual (release and --fast), none imported"
