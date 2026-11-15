#!/usr/bin/env bash
# The memory and C-runtime routines a macOS executable defines itself (#811, hidden module
# assembly: memcpy, memmove, memset, memcmp, bcmp, strlen, strcmp, memchr, bzero): the program of
# tests/cases/libc-memory-routines checks them against a byte formula, and the executable must not
# import any of them from libSystem; a float `%` must match libSystem's fmod (tests/cases/darwin-float-remainder). Darwin only (Linux has tools/test-libc-memory-routines.sh).
# Usage: tools/test-darwin-routines.sh [compiler]
set -euo pipefail
if [[ $(uname -s) != Darwin ]]; then
    echo 'darwin routines: Darwin only'
    exit 0
fi
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/darwin-routines
rm -rf "$out"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/libc-memory-routines/main.ab -o "$out/$mode" "${flags[@]}"
    # Outside a command substitution, so a failure shows its output and how the program ended.
    status=0
    "$out/$mode" > "$out/$mode.out" 2> "$out/$mode.err" || status=$?
    actual=$(tail -n 1 "$out/$mode.out")
    if [[ $status -ne 0 || $actual != 'libc memory routines: '*' checks agree' ]]; then
        printf 'darwin routines (%s): exit status %s (128 + n is signal n)\n' "$mode" "$status" >&2
        head -n 40 "$out/$mode.out" >&2
        head -n 10 "$out/$mode.err" >&2
        exit 1
    fi
    imported=$(nm -u "$out/$mode" | awk '{print $NF}' | grep -xE '_(memcpy|memmove|memset|memcmp|bcmp|strlen|strcmp|memchr|bzero|__bzero)' || true)
    if [[ -n $imported ]]; then
        printf 'darwin routines (%s): imported from libSystem: %s\n' "$mode" "$imported" >&2
        exit 1
    fi
done
recovered=$actual
# A float `%` is the runtime's remainder: the same bits as libSystem's fmod and fmodf, which the program calls
# itself to compare (the libSystem imports guard checks that an ordinary program imports neither).
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/darwin-float-remainder/main.ab -o "$out/remainder-$mode" "${flags[@]}"
    status=0
    remainder=$("$out/remainder-$mode") || status=$?
    [[ $status == 42 ]] || {
        printf 'darwin routines (remainder, %s): exit status %s: %s\n' "$mode" "$status" "$remainder" >&2; exit 1; }
done
echo "$recovered; $(tail -n 1 <<< "$remainder") (release and --fast), none imported"
