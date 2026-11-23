#!/usr/bin/env bash
# tools/package-windows-toolchain.sh builds abla-toolchain-x86_64-windows.zip from a linked ablac.exe. With an image lld-link
# links from a small program standing in for the compiler (the real one is linked on a Windows runner), the package must
#   - hold bin/ablac.exe, share/abla/{runtime,stdlib} (with runtime/windows/imports/*.txt) and share/licenses, under one top directory
#     and nothing else, all entries stamped SOURCE_DATE_EPOCH;
#   - be byte for byte the same when built again (and under another TZ and umask);
#   - refuse an executable that imports a C runtime, a file that is not a PE image, and a sysroot without the import lists.
# Skipped with a message when lld-link, zip or unzip is missing.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
for tool in lld-link zip unzip; do
    command -v "$tool" > /dev/null || { echo "package-windows-toolchain: skipped ($tool is not installed)"; exit 0; }
done
out=build/package-windows-toolchain
rm -rf "$out"
mkdir -p "$out"
fail() { echo "package-windows-toolchain: $1" >&2; exit 1; }
"$compiler" build tools/pe-info/main.ab -o "$out/pe-info" --fast --no-cache > "$out/pe-info.log" 2>&1 || { cat "$out/pe-info.log" >&2; fail "tools/pe-info/main.ab did not build"; }
"$compiler" build tools/windows/implib.ab -o "$out/implib" --fast --no-cache > "$out/implib.log" 2>&1 || { cat "$out/implib.log" >&2; fail "tools/windows/implib.ab did not build"; }
"$out/implib" "$out/kernel32.lib" kernel32.dll x86_64 runtime/windows/imports/kernel32.txt
printf 'puts\n' > "$out/msvcrt.txt"
"$out/implib" "$out/msvcrt.lib" msvcrt.dll x86_64 "$out/msvcrt.txt"
"$compiler" build tests/cases/windows/exit7.ab --target-triple x86_64-pc-windows-msvc --object-format coff -o "$out/exit7.obj" > "$out/compile.log" 2>&1 ||
    { cat "$out/compile.log" >&2; fail "exit7.ab did not compile to a COFF object"; }
link() { local image=$1; shift; lld-link /nologo /subsystem:console /entry:abla_start /nodefaultlib /machine:x64 /brepro /fixed /highentropyva:no "/out:$image" "$@" "$out/exit7.obj" "$out/kernel32.lib" 2> "$out/link.log" || { cat "$out/link.log" >&2; fail "lld-link failed"; }; }
link "$out/ablac.exe"
link "$out/crt.exe" /include:puts "$out/msvcrt.lib"
export ABLA_PE_INFO=$PWD/$out/pe-info
package=tools/package-windows-toolchain.sh

"$package" "$out/ablac.exe" "$root" "$out/one.zip" > "$out/one.log" 2>&1 || { cat "$out/one.log" >&2; fail "the package was not built"; }
unzip -Z1 "$out/one.zip" | sort > "$out/entries.txt"
top=abla-toolchain-x86_64-windows
! grep -v "^$top/" "$out/entries.txt" > /dev/null || fail "an entry outside $top/: $(grep -v "^$top/" "$out/entries.txt" | head -3)"
for required in "$top/bin/ablac.exe" "$top/share/licenses/abla.txt" "$top/share/licenses/NOTICE-windows.txt" "$top/share/abla/stdlib/abla/io/entry.ab" \
    "$top/share/abla/runtime/windows/imports/kernel32.txt"; do
    grep -qxF "$required" "$out/entries.txt" || fail "the package lacks $required"
done
! grep -E '(^|/)\.git(/|$)|\.abla-' "$out/entries.txt" > /dev/null || fail "the package carries repository or build metadata"
! grep '/$' "$out/entries.txt" > /dev/null || fail "the zip has directory entries (they carry their own times and modes): $(grep '/$' "$out/entries.txt" | head -2)"
unzip -p "$out/one.zip" "$top/bin/ablac.exe" | cmp - "$out/ablac.exe" || fail "bin/ablac.exe is not the compiler it was given"
unzip -p "$out/one.zip" "$top/share/abla/runtime/windows/imports/kernel32.txt" | cmp - runtime/windows/imports/kernel32.txt || fail "the import list differs from the source tree's"
unzip -Z -T "$out/one.zip" | grep -oE '[0-9]{8}\.[0-9]{6}' | sort -u > "$out/stamps.txt"
[[ $(wc -l < "$out/stamps.txt") == 1 && $(cat "$out/stamps.txt") == 19800101.000000 ]] || fail "the entries are not all stamped 1980-01-01: $(cat "$out/stamps.txt")"

( umask 077; TZ=Asia/Tokyo "$package" "$out/ablac.exe" "$root" "$out/two.zip" > "$out/two.log" 2>&1 ) || { cat "$out/two.log" >&2; fail "the second package was not built"; }
cmp "$out/one.zip" "$out/two.zip" || fail "the package is not reproducible (another TZ and umask)"

if "$package" "$out/crt.exe" "$root" "$out/crt.zip" > "$out/crt.log" 2>&1; then fail "an executable importing msvcrt.dll was packaged"; fi
grep -q 'msvcrt.dll\|C runtime' "$out/crt.log" || fail "the refusal does not name the C runtime import: $(cat "$out/crt.log")"
[[ ! -e $out/crt.zip ]] || fail "a package was left behind by the refused build"
printf 'not a PE\n' > "$out/text.exe"
if "$package" "$out/text.exe" "$root" "$out/text.zip" > "$out/text.log" 2>&1; then fail "a text file was packaged as the compiler"; fi
mkdir -p "$out/thin/runtime" "$out/thin/stdlib"
cp LICENSE "$out/thin/"
if "$package" "$out/ablac.exe" "$out/thin" "$out/thin.zip" > "$out/thin.log" 2>&1; then fail "a sysroot without the import lists was packaged"; fi
echo "package-windows-toolchain: the zip has the toolchain layout, is reproducible, and refuses a compiler with a C runtime import, a non-PE file and a sysroot without import lists"
