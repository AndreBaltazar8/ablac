#!/usr/bin/env bash
# tools/pe-info/main.ab reads a Windows executable's machine, subsystem and imports from the PE file itself. Against images
# lld-link links from a program compiled for x86_64-pc-windows-msvc (as tools/test-windows-link.sh does) it must
#   - print the machine, the subsystem and exactly the imports llvm-readobj lists;
#   - refuse (exit 1, naming the DLL) with --no-crt an image that imports msvcrt.dll (linked with /include:puts against a
#     generated import library), and accept the program that imports kernel32 only;
#   - refuse a DLL named by --forbid, case-insensitively;
#   - refuse a file that is not a PE image, and a truncated one.
# Skipped with a message when lld-link or llvm-readobj is not installed.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
for tool in lld-link llvm-readobj; do
    command -v "$tool" > /dev/null || { echo "pe-info: skipped ($tool is not installed)"; exit 0; }
done
out=build/pe-info
rm -rf "$out"
mkdir -p "$out"
fail() { echo "pe-info: $1" >&2; exit 1; }
"$compiler" build tools/pe-info/main.ab -o "$out/pe-info" --fast --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; fail "tools/pe-info/main.ab did not build"; }
"$compiler" build tools/windows/implib.ab -o "$out/implib" --fast --no-cache > "$out/implib.log" 2>&1 || { cat "$out/implib.log" >&2; fail "tools/windows/implib.ab did not build"; }
"$out/implib" "$out/kernel32.lib" kernel32.dll x86_64 runtime/windows/imports/kernel32.txt
printf 'puts\n' > "$out/msvcrt.txt"
"$out/implib" "$out/msvcrt.lib" msvcrt.dll x86_64 "$out/msvcrt.txt"
"$compiler" build tests/cases/windows/exit7.ab --target-triple x86_64-pc-windows-msvc --object-format coff -o "$out/exit7.obj" > "$out/compile.log" 2>&1 ||
    { cat "$out/compile.log" >&2; fail "exit7.ab did not compile to a COFF object"; }
link() { local image=$1; shift; lld-link /nologo /subsystem:console /entry:abla_start /nodefaultlib /machine:x64 /brepro /fixed /highentropyva:no "/out:$image" "$@" "$out/exit7.obj" "$out/kernel32.lib" 2> "$out/link.log" || { cat "$out/link.log" >&2; fail "lld-link failed"; }; }
link "$out/plain.exe"
link "$out/crt.exe" /include:puts "$out/msvcrt.lib"

"$out/pe-info" "$out/plain.exe" > "$out/plain.txt" || fail "pe-info failed on a plain image"
grep -qx 'machine x86_64' "$out/plain.txt" || fail "wrong machine: $(cat "$out/plain.txt")"
grep -qx 'subsystem console' "$out/plain.txt" || fail "wrong subsystem: $(cat "$out/plain.txt")"
llvm-readobj --coff-imports "$out/plain.exe" | awk '/^ *Name:/ { dll = $2 } /^ *Symbol:/ { print "import " dll, $2 }' | sort > "$out/expected-imports.txt"
grep '^import ' "$out/plain.txt" | sort > "$out/actual-imports.txt"
[[ -s $out/expected-imports.txt ]] || fail "llvm-readobj found no imports in the fixture"
diff "$out/expected-imports.txt" "$out/actual-imports.txt" || fail "the imports differ from llvm-readobj's"
"$out/pe-info" "$out/plain.exe" --no-crt > /dev/null || fail "--no-crt refused a kernel32-only image"
"$out/pe-info" "$out/crt.exe" > "$out/crt.txt" || fail "pe-info failed on the msvcrt image"
grep -qx 'import msvcrt.dll puts' "$out/crt.txt" || fail "the msvcrt import is not listed"
if "$out/pe-info" "$out/crt.exe" --no-crt > /dev/null 2> "$out/crt.err"; then fail "--no-crt accepted an image importing msvcrt.dll"; fi
grep -q 'msvcrt.dll' "$out/crt.err" || fail "the refusal does not name msvcrt.dll"
if "$out/pe-info" "$out/plain.exe" --forbid KERNEL32.DLL > /dev/null 2> "$out/forbid.err"; then fail "--forbid accepted an import of the forbidden DLL"; fi
grep -qi 'kernel32.dll' "$out/forbid.err" || fail "the --forbid refusal does not name the DLL"
"$out/pe-info" "$out/plain.exe" --forbid user32.dll > /dev/null || fail "--forbid refused an image that does not import the DLL"
printf 'not a PE\n' > "$out/text.exe"
if "$out/pe-info" "$out/text.exe" > /dev/null 2>&1; then fail "a text file was accepted"; fi
head -c 100 "$out/plain.exe" > "$out/cut.exe"
if "$out/pe-info" "$out/cut.exe" > /dev/null 2>&1; then fail "a truncated image was accepted"; fi
{ printf 'MZ'; head -c 58 /dev/zero; printf '\100\000\000\000'; head -c 200 /dev/zero | tr '\0' 'X'; } > "$out/mz.exe"
if "$out/pe-info" "$out/mz.exe" > /dev/null 2>&1; then fail "an MZ file without the PE signature was accepted"; fi
echo "pe-info: machine, subsystem and imports match llvm-readobj; --no-crt and --forbid refuse as they should; non-PE input is refused"
