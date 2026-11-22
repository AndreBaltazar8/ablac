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
tested=$(grep -oE 'number == [0-9]+' "$file" | grep -oE '[0-9]+' | sort -n | uniq | tr '\n' ' ')
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

# What the compiler asks before it reaches LLVM (self.ab): the stack limit is the 8 MiB the image is linked with, the descriptor
# limit the table's 4096, the affinity mask 8 bytes with a CPU in it, and /proc/self/exe the program itself ("/" for "\"). And
# what it links: a float `%` (the runtime's remainder: no fmod to import), malloc_trim (0) and pthread_key_create (ENOSYS).
"$compiler" build tests/cases/windows/self.ab --target x86_64-windows-hosted -o "$out/self.exe" --fast --no-cache > "$out/self.log" 2>&1 ||
    { cat "$out/self.log" >&2; fail "self.ab did not build for Windows"; }
status=0
tools/windows/wine-run.sh "$out/self.exe" > "$out/self.out" 2> "$out/self.err" || status=$?
[[ $status == 0 ]] || fail "self.exe exited $status: $(head -3 "$out/self.err")"
expect() { grep -qxE "$1" "$out/self.out" || fail "self.exe printed no line matching '$1': $(cat "$out/self.out" "$out/self.err")"; }
expect 'remainder 1\.5'
expect 'trim 0 key 38'
expect 'fchmod 0:292 0:420'
expect 'null true 0'
expect 'stack 8388608 8388608'
expect 'descriptors 4096'
expect 'affinity 8 bytes, some CPUs'
expect 'image [A-Za-z]:/([^\\]*/)?self\.exe'
expect 'image exists true'
# The unwind-free jump pair (jump.ab): abla_setjmp returns 0 first, abla_longjmp from twenty frames down returns 7 to it.
"$compiler" build tests/cases/windows/jump.ab --target x86_64-windows-hosted -o "$out/jump.exe" --fast --no-cache > "$out/jump.log" 2>&1 ||
    { cat "$out/jump.log" >&2; fail "jump.ab did not build for Windows"; }
status=0
tools/windows/wine-run.sh "$out/jump.exe" > "$out/jump.out" 2> "$out/jump.err" || status=$?
[[ $status == 0 ]] || fail "jump.exe exited $status: $(head -3 "$out/jump.err")"
[[ "$(cat "$out/jump.out")" == $'armed\njumped 7' ]] || fail "jump.exe printed: $(cat "$out/jump.out" "$out/jump.err")"
echo "windows-syscalls: the translated numbers are $tested; an untranslated call is refused with status 70 and its number; a program reads its limits, CPUs and own path; abla_setjmp and abla_longjmp jump back from a deeper frame"
