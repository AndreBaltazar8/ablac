#!/usr/bin/env bash
# The memory and C-runtime routines a macOS executable defines itself (#811, hidden module assembly:
# memcpy, memmove, memset, memcmp, bcmp, strlen, strcmp, memchr, bzero, _setjmp, _longjmp) and its float
# remainder: tests/cases/libc-memory-routines checks the memory routines against a byte formula,
# tests/cases/libc-jump-routines the jump routines, tests/cases/darwin-float-remainder a float `%` against
# libSystem's fmod and fmodf, and the executables must not import the routines from libSystem.
# Darwin only (Linux has tools/test-libc-memory-routines.sh and tools/test-libc-jump-routines.sh).
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
    # Chained fixups (#811 G5): dyld binds the imports at load, no lazy stubs, no dyld_stub_binder.
    if ! otool -l "$out/$mode" | grep -q LC_DYLD_CHAINED_FIXUPS; then
        printf 'darwin routines (%s): no LC_DYLD_CHAINED_FIXUPS load command\n' "$mode" >&2
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
# _setjmp and _longjmp too (C names; __setjmp and __longjmp in Mach-O): tests/cases/libc-jump-routines retries a transaction
# from three frames down with callee-saved registers live in each, and neither may be imported.
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/libc-jump-routines/main.ab -o "$out/jump-$mode" "${flags[@]}"
    status=0
    actual=$("$out/jump-$mode") || status=$?
    [[ $status == 42 && $actual == 'libc jump routines: 50 of 50 rounds agree' ]] || {
        printf 'darwin routines (jump, %s): exit status %s (128 + n is signal n): %s\n' "$mode" "$status" "$actual" >&2; exit 1; }
    for routine in __setjmp __longjmp; do
        if nm -u "$out/jump-$mode" | awk '{print $NF}' | grep -x "$routine" >/dev/null; then
            echo "darwin routines (jump, $mode): $routine is imported from libSystem" >&2; exit 1
        fi
    done
done
echo "$recovered; $(tail -n 1 <<< "$remainder"); $actual (release and --fast), none imported"
