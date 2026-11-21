#!/usr/bin/env bash
# The Windows target's link lane on Linux (W1a, docs/design/windows-target.md): an Abla program cross-compiled to a COFF object
# for x86_64-pc-windows-msvc, an import library for kernel32 written by tools/windows/implib.ab (src/coff_import.ab: no SDK,
# no llvm-dlltool), and an executable linked by lld-link, which must
#   - be a PE32+ console image whose entry point is the program's abla_start;
#   - be byte for byte the same when linked again (/brepro);
#   - import only what tools/windows-imports-allowlist.txt allows, and no C runtime under any name;
#   - run and exit with status 7 under Wine, when Wine is installed (skipped with a message when not).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/windows-link
rm -rf "$out"
mkdir -p "$out"
fail() { echo "windows-link: $1" >&2; exit 1; }
for tool in lld-link llvm-readobj; do
    command -v "$tool" > /dev/null || { echo "windows-link: skipped ($tool is not installed)"; exit 0; }
done
"$compiler" build tools/windows/implib.ab -o "$out/implib" --fast --no-cache > "$out/implib.log" 2>&1 || { cat "$out/implib.log" >&2; fail "tools/windows/implib.ab did not build"; }
"$out/implib" "$out/kernel32.lib" kernel32.dll x86_64 runtime/windows/imports/kernel32.txt || fail "the import library was not written"
"$out/implib" "$out/kernel32-again.lib" kernel32.dll x86_64 runtime/windows/imports/kernel32.txt
cmp "$out/kernel32.lib" "$out/kernel32-again.lib" || fail "the import library is not reproducible"
"$compiler" build tests/cases/windows/exit7.ab --target-triple x86_64-pc-windows-msvc --object-format coff -o "$out/exit7.obj" > "$out/compile.log" 2>&1 ||
    { cat "$out/compile.log" >&2; fail "exit7.ab did not compile to a COFF object"; }
link() { lld-link /nologo /subsystem:console /entry:abla_start /nodefaultlib /machine:x64 /brepro "/out:$1" "$out/exit7.obj" "$out/kernel32.lib"; }
link "$out/exit7.exe" 2> "$out/link.log" || { cat "$out/link.log" >&2; fail "lld-link failed"; }
link "$out/exit7-again.exe" 2> "$out/link.log"
cmp "$out/exit7.exe" "$out/exit7-again.exe" || fail "the executable is not reproducible (/brepro)"
headers=$(llvm-readobj --file-headers "$out/exit7.exe")
grep -q 'Format: COFF-x86-64' <<< "$headers" || fail "not a PE x86-64 image"
grep -q 'Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI' <<< "$headers" || fail "not a console image"
entry=$(awk '/AddressOfEntryPoint/ { print $2 }' <<< "$headers")
[[ -n $entry && $entry != 0x0 ]] || fail "no entry point"
imports=$(llvm-readobj --coff-imports "$out/exit7.exe" | awk '/^ *Name:/ { dll = $2 } /^ *Symbol:/ { print dll, $2 }')
grep -qiE 'msvcrt|ucrtbase|vcruntime|api-ms-win-crt' <<< "$imports" && fail "a C runtime import: $imports"
allowed=$(grep -v '^#' tools/windows-imports-allowlist.txt | grep -v '^$' || true)
while read -r dll function; do
    [[ -z $dll ]] || grep -qxF "$dll $function" <<< "$allowed" || fail "import not in tools/windows-imports-allowlist.txt: $dll $function"
done <<< "$imports"
[[ -n $imports ]] || fail "the program imports nothing (ExitProcess expected)"
if command -v wine > /dev/null; then
    status=0
    WINEDEBUG=-all wine "$out/exit7.exe" > /dev/null 2>&1 || status=$?
    [[ $status == 7 ]] || fail "under Wine the program exited with $status, not 7"
    ran='ran under Wine (exit 7)'
else
    ran='Wine not installed, not run'
fi
echo "windows-link: COFF object, import library from names, lld-link (reproducible), PE32+ console, imports within the allowlist and no C runtime; $ran"
