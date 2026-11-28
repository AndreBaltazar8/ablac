#!/usr/bin/env bash
# The C library of the Windows compiler linked without Microsoft's (src/static_libc/windows, decision #163; the ablac-crt-candidate
# link), run under Wine:
#   - tests/cases/windows/libc/scan.ab: __stdio_common_vsscanf (sscanf, sscanf_s, and _snscanf's count) over scan-cases.txt, every
#     destination a zone of 0xAA, against scan-expected.txt. Each sscanf line is what glibc's sscanf gives for the same format and text
#     (the text cut to the count): 19 written by hand, then 400 of a random set (formats of %d %i %u %x %o %s %c %[ %n, widths, * and
#     hh h ll; texts of digits, hexadecimal letters, signs and separators) on which glibc and this library agree; the sscanf_s lines
#     check each destination's room (nothing written past it, the destination emptied when the text does not fit). A "0x" prefix is
#     taken only with a hexadecimal digit after it inside the count and the width: before, the look-ahead read the byte past a count;
#   - tests/cases/windows/libc/print.ab: __stdio_common_vsprintf (C's snprintf, _vsnprintf and its legacy NUL) for counts 0 to 12,
#     snprintf(NULL, 0), sprintf and sprintf_s, against print-expected.txt: nothing at or past the count is written;
#   - tests/cases/windows/libc/cookie.cpp, linked with tools/windows/static-compiler/crt-free-start.cpp: start-up keeps the /GS cookie
#     the loader seeded (before, it replaced it with one made from the time, the counters and the ids). This needs clang-cl and the
#     Windows SDK and CRT headers and kernel32.lib (ABLA_WINDOWS_SDK: a directory in xwin's splat layout, by default ~/.cache/xwin/splat;
#     docs/design/windows-crt-free-compiler.md, decision #164); without them it is skipped with a message.
# Without lld-link, or without Wine (tools/windows/wine-run.sh), the runs are skipped with a message.
#
#   tools/test-windows-libc.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
cases=tests/cases/windows/libc
out=build/windows-libc
rm -rf "$out"
mkdir -p "$out"
fail() { echo "windows-libc: $1" >&2; exit 1; }
command -v lld-link > /dev/null || { echo "windows-libc: skipped (lld-link is not installed)"; exit 0; }
ran=()
skipped=()
for name in scan print; do
    "$compiler" build "$cases/$name.ab" --target x86_64-windows --fast --no-cache -o "$out/$name.exe" > "$out/$name.log" 2>&1 ||
        { cat "$out/$name.log" >&2; fail "$name.ab did not build for Windows"; }
    cp "$cases/$name-cases.txt" "$out/" 2> /dev/null || true
    status=0
    (cd "$out" && "$root/tools/windows/wine-run.sh" "$name.exe" > "$name.out" 2> "$name.err") || status=$?
    if [[ $status == 125 ]]; then
        skipped+=("$name (no Wine)")
        continue
    fi
    [[ $status == 0 ]] || { cat "$out/$name.err" >&2; fail "$name.exe exited $status"; }
    # Wine's own lines (D-Bus and the like) go to standard error; the program's are the only ones on standard output.
    diff -u "$cases/$name-expected.txt" "$out/$name.out" > "$out/$name.diff" ||
        { head -40 "$out/$name.diff" >&2; fail "$name.exe printed other than $cases/$name-expected.txt"; }
    ran+=("$name ($(wc -l < "$out/$name.out") lines)")
done
sdk=${ABLA_WINDOWS_SDK:-$HOME/.cache/xwin/splat}
if ! command -v clang-cl > /dev/null; then
    skipped+=("cookie (no clang-cl)")
elif [[ ! -f $sdk/sdk/lib/um/x86_64/kernel32.lib || ! -d $sdk/sdk/include/um ]]; then
    skipped+=("cookie (no Windows SDK at $sdk: set ABLA_WINDOWS_SDK)")
else
    includes=(-imsvc "$sdk/crt/include" -imsvc "$sdk/sdk/include/ucrt" -imsvc "$sdk/sdk/include/um" -imsvc "$sdk/sdk/include/shared")
    for source in tools/windows/static-compiler/crt-free-start.cpp "$cases/cookie.cpp"; do
        clang-cl /nologo /c /O2 /GS- /Zl --target=x86_64-pc-windows-msvc "${includes[@]}" "$source" \
            "/Fo$out/$(basename "$source" .cpp).obj" > "$out/cookie-build.log" 2>&1 ||
            { cat "$out/cookie-build.log" >&2; fail "$source did not compile"; }
    done
    lld-link /nologo "/out:$out/cookie.exe" /entry:wmainCRTStartup /subsystem:console /nodefaultlib "$out/crt-free-start.obj" \
        "$out/cookie.obj" "$sdk/sdk/lib/um/x86_64/kernel32.lib" > "$out/cookie-link.log" 2>&1 ||
        { cat "$out/cookie-link.log" >&2; fail "cookie.exe did not link"; }
    status=0
    (cd "$out" && "$root/tools/windows/wine-run.sh" cookie.exe > cookie.out 2> cookie.err) || status=$?
    if [[ $status == 125 ]]; then
        skipped+=("cookie (no Wine)")
    else
        [[ $status == 0 ]] || { cat "$out/cookie.out" >&2; fail "cookie.exe exited $status (1: start-up replaced the loader's cookie)"; }
        ran+=("cookie")
    fi
fi
echo "windows-libc: ran ${ran[*]:-nothing}${skipped:+; skipped ${skipped[*]}}"
