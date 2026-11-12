#!/usr/bin/env bash
# _setjmp and _longjmp as an x86-64 Linux executable defines them itself
# (#806, glibc's jmp_buf format): tests/cases/libc-jump-routines retries a
# transaction from three frames down, with callee-saved registers holding known
# values in each; each build must define both locally and import neither.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo 'libc jump routines: x86-64 Linux only (macOS keeps libSystem)'
    exit 0
fi
out=build/libc-jump-routines
rm -rf "$out"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/libc-jump-routines/main.ab -o "$out/$mode" "${flags[@]}"
    status=0
    actual=$("$out/$mode") || status=$?
    [[ $status == 42 && $actual == 'libc jump routines: 50 of 50 rounds agree' ]] || {
        printf 'libc jump routines (%s): status %s: %s\n' "$mode" "$status" "$actual" >&2; exit 1; }
    for routine in _setjmp _longjmp; do
        if nm -D --undefined-only "$out/$mode" | awk '{print $NF}' | sed 's/@.*//' | grep -qx "$routine"; then
            echo "libc jump routines ($mode): $routine is imported" >&2; exit 1
        fi
        nm "$out/$mode" | grep -qE " t $routine\$" || {
            echo "libc jump routines ($mode): $routine is not a local definition" >&2; exit 1; }
    done
done
echo "$actual (release and --fast), none imported"
