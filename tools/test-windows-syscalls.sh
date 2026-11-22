#!/usr/bin/env bash
# The Linux system calls the Windows runtime translates (W1c, stdlib/abla/runtime/platform/windows/entry.ab):
#   - the list `__ablaRuntimeWindowsTranslated` says is exactly the set of numbers `__ablaRuntimeWindowsSyscall` tests (a call added
#     to the translation without the list, or the list without the call, fails here);
#   - a number outside the set is refused, not answered with a quiet success: a program that makes call 999 ends with status 70
#     and names the number on standard error (under Wine, skipped with a message when Wine is not installed).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
file=stdlib/abla/runtime/platform/windows/entry.ab
out=build/windows-syscalls
rm -rf "$out"
mkdir -p "$out"
fail() { echo "windows-syscalls: $1" >&2; exit 1; }
tested=$(awk '/^trusted fun __ablaRuntimeWindowsSyscall\(/ { inside = 1 } inside { print } inside && /^}/ { exit }' "$file" |
    grep -oE 'number == [0-9]+' | grep -oE '[0-9]+' | sort -n | uniq | tr '\n' ' ')
listed=$(grep -E '^trusted fun __ablaRuntimeWindowsTranslated' "$file" | grep -oE '"[0-9 ]+"' | tr -d '"' | tr ' ' '\n' | sort -n | tr '\n' ' ')
[[ -n $tested ]] || fail "no numbers found in __ablaRuntimeWindowsSyscall"
[[ $tested == "$listed" ]] || fail "__ablaRuntimeWindowsTranslated lists [$listed] but the translation tests [$tested]"
for tool in lld-link llvm-readobj; do
    command -v "$tool" > /dev/null || { echo "windows-syscalls: the list matches ($tested); the refusal is skipped ($tool is not installed)"; exit 0; }
done
"$compiler" build tests/cases/windows/refuse.ab --target x86_64-windows-hosted -o "$out/refuse.exe" --fast --no-cache > "$out/refuse.log" 2>&1 ||
    { cat "$out/refuse.log" >&2; fail "refuse.ab did not build for Windows"; }
status=0
tools/windows/wine-run.sh "$out/refuse.exe" > "$out/refuse.out" 2> "$out/refuse.err" || status=$?
if [[ $status == 125 ]]; then
    echo "windows-syscalls: the list matches ($tested); the refusal is skipped (Wine is not installed)"
    exit 0
fi
[[ $status == 70 ]] || fail "an untranslated call ended with status $status under Wine, not 70"
grep -q 'unsupported Linux system call 999' "$out/refuse.out" "$out/refuse.err" || fail "the refusal does not name the call"
echo "windows-syscalls: the translated numbers are $tested; an untranslated call is refused with status 70 and its number"
