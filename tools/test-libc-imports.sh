#!/usr/bin/env bash
# Lists the dynamic imports of small hosted programs (built release and --fast)
# and of the compiler itself, and fails on any import that
# tools/libc-imports-allowlist.txt does not hold (#806: Abla should not
# require libc). The list is today's set and may only shrink: remove a line
# when its import goes away. Each line is "<subject> <symbol>"; the subject is
# a program and mode such as hello.release, or "compiler"; a needed shared
# library is listed as needed:<soname>. The compiler's libLLVM C API calls
# (versioned LLVM_*) are left out; its libraries are not.
# A program without a C library imports nothing at all: it is a static
# executable (checked below). Linux only: a macOS program keeps libSystem.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
# The list was taken with ABLA_DEBUG and ABLA_TEST_FAST_BUILDS unset (--fast
# builds carry debug information; release builds are release). The suite
# sets ABLA_DEBUG=0, under which a --fast build's FastISel also calls memset,
# and may set ABLA_TEST_FAST_BUILDS=1, which makes every build --fast. Build
# the same way whoever runs it.
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux ]]; then
    echo 'libc imports: Linux only (macOS keeps libSystem)'
    exit 0
fi
allow=tools/libc-imports-allowlist.txt
[[ -f $allow ]] || { echo "libc imports: missing $allow" >&2; exit 1; }
if ! sort -cu "$allow"; then
    echo "libc imports: $allow must be sorted and unique" >&2
    exit 1
fi
nm=$(command -v nm || command -v llvm-nm || true)
[[ -n $nm ]] || { echo 'libc imports: nm or llvm-nm is needed' >&2; exit 1; }
out=build/libc-imports
rm -rf "$out"
mkdir -p "$out"
imports() { # subject binary
    local subject=$1 binary=$2
    readelf -d "$binary" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/needed:\1/p' |
        sed "s/^/$subject /"
    "$nm" -D --undefined-only --with-symbol-versions "$binary" |
        awk -v subject="$subject" '{ symbol = $NF
            if (symbol ~ /@LLVM_/) next
            sub(/@.*/, "", symbol)
            if (symbol != "") print subject " " symbol }'
}
actual=$out/actual.txt
: >"$actual"
for program in tests/cases/libc-imports/*.ab; do
    name=$(basename "$program" .ab)
    for mode in release fast; do
        flags=(--no-cache)
        [[ $mode == fast ]] && flags+=(--fast)
        if ! "$compiler" build "$program" -o "$out/$name.$mode" "${flags[@]}" >"$out/$name.$mode.log" 2>&1; then
            echo "libc imports: $program ($mode) did not build:" >&2
            tail -n 20 "$out/$name.$mode.log" >&2
            exit 1
        fi
        imports "$name.$mode" "$out/$name.$mode" >>"$actual"
    done
done
# An x86-64 Linux program links no libc unless it brings a C library (#806): its
# release and --fast builds have no interpreter, no dynamic section and no undefined
# symbol. tools/libc-imports-static-pending.txt names the programs that still link
# libc, each for a reason the file gives; it only shrinks, and a program on it that
# no longer links libc must be taken off.
pending=tools/libc-imports-static-pending.txt
[[ -f $pending ]] || { echo "libc imports: missing $pending" >&2; exit 1; }
for program in tests/cases/libc-imports/*.ab; do
    name=$(basename "$program" .ab)
    for mode in release fast; do
        binary=$out/$name.$mode
        static=1
        if readelf -lW "$binary" | grep -q INTERP || readelf -dW "$binary" 2>/dev/null | grep -q NEEDED ||
            [[ -n $("$nm" --undefined-only "$binary" 2>/dev/null) ]]; then
            static=0
        fi
        if grep -qx "$name" "$pending"; then
            if [[ $static == 1 ]]; then
                echo "libc imports: $name.$mode links no libc now, remove $name from $pending" >&2
                exit 1
            fi
        elif [[ $static == 0 ]]; then
            echo "libc imports: $name.$mode links libc (it should not):" >&2
            "$compiler" build "$program" -o "$out/$name.verbose" --no-cache --verbose 2>&1 | grep '^note:' >&2 || true
            exit 1
        fi
    done
done
# A program that imports abla/http without a TLS connection links no OpenSSL.
if ! "$compiler" build tests/cases/libc-imports-http/main.ab -o "$out/http-plain" --no-cache >"$out/http-plain.log" 2>&1; then
    echo "libc imports: tests/cases/libc-imports-http did not build:" >&2
    tail -n 20 "$out/http-plain.log" >&2
    exit 1
fi
if readelf -d "$out/http-plain" | grep -Eq 'NEEDED.*(libssl|libcrypto)'; then
    echo "libc imports: a program that opens no TLS connection links OpenSSL" >&2
    exit 1
fi
binary=$compiler
[[ -f $compiler.bin ]] && binary=$compiler.bin
if ! readelf -h "$binary" >/dev/null 2>&1; then
    echo "libc imports: $binary is not an ELF file (pass the compiler binary)" >&2
    exit 1
fi
imports compiler "$binary" >>"$actual"
sort -u -o "$actual" "$actual"
# Every subject must report its libraries: an empty listing would pass vacuously. (A static program, checked
# above, has none to report.)
for subject in $(for program in tests/cases/libc-imports/*.ab; do
    name=$(basename "$program" .ab); echo "$name.release $name.fast"; done) compiler; do
    if [[ $subject != compiler ]] && ! readelf -lW "$out/$subject" | grep -q INTERP &&
        ! readelf -dW "$out/$subject" 2>/dev/null | grep -q NEEDED &&
        [[ -z $("$nm" --undefined-only "$out/$subject" 2>/dev/null) ]]; then
        continue
    fi
    if ! grep -q "^$subject needed:" "$actual"; then
        echo "libc imports: no imports listed for $subject (is readelf working?)" >&2
        exit 1
    fi
done
unexpected=$(comm -23 "$actual" "$allow")
if [[ -n $unexpected ]]; then
    printf 'libc imports: new imports are not allowed (#806):\n%s\n' "$unexpected" >&2
    exit 1
fi
gone=$(comm -13 "$actual" "$allow")
if [[ -n $gone ]]; then
    printf 'libc imports: no longer imported, remove from %s:\n%s\n' "$allow" "$gone"
fi
printf 'libc imports: %d imports, all within the allowed list\n' "$(wc -l <"$actual")"
