#!/usr/bin/env bash
# #811: a shared and a static library of the aarch64-linux cross target (`--target aarch64-linux --emit shared-library` and
# `static-library`) bring their own system calls, heap, memory and jump routines, as an aarch64 Android library does, and
# take from the C library of the process that loads them only the pthread functions of the threads they start.
# Checks, on tests/cases/aarch64-linux-library (release and --fast):
#   - the shared library is an AArch64 ELF with no DT_NEEDED and no PT_INTERP, whose undefined dynamic symbols are only
#     pthread_create and pthread_join, and whose relocations are of the kinds a C library's loader applies;
#   - the static library's object leaves undefined only those two too (no malloc, write, memmove, _longjmp, ...);
#   - with ABLA_AARCH64_GLIBC (an AArch64 glibc's lib directory: shell.nix sets it) and an AArch64 runner
#     (tools/aarch64-test-runner.sh), a glibc host (host.c) loads the shared library by dlopen, and another links the static
#     one, and both print the exports' results and the library's own output. Without them the run is reported skipped.
# A control (a library that calls malloc through extern:"c") must fail the symbol check.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $compiler == /* || $compiler != */* ]] || compiler=$root/$compiler
case_dir=tests/cases/aarch64-linux-library
out=$(mktemp -d "${TMPDIR:-/tmp}/abla-aarch64-library.XXXXXX")
trap 'rm -rf "$out"' EXIT
readelf=$(command -v llvm-readelf || command -v readelf || true)
nm=$(command -v llvm-nm || command -v nm || true)
if [[ -z $readelf || -z $nm ]]; then
    echo 'aarch64 library: readelf or nm missing' >&2
    exit 1
fi
allowed='pthread_create
pthread_join'
fail() {
    echo "aarch64 library: $*" >&2
    exit 1
}
# The undefined symbols of a shared library's dynamic table or of an archive, one per line, sorted.
undefined_dynamic() { "$nm" -D --undefined-only "$1" | awk '{ print $NF }' | sed 's/@.*//' | sort -u; }
undefined_archive() { "$nm" --undefined-only "$1" | awk 'NF == 2 && $1 == "U" { print $2 }' | sort -u; }
check_symbols() { # LABEL FILE-WITH-SYMBOLS
    local extra
    extra=$(grep -vxF -f <(printf '%s\n' "$allowed") "$2" || true)
    [[ -z $extra ]] || fail "$1 leaves undefined: $(printf '%s' "$extra" | tr '\n' ' ')"
}

source "$root/tools/aarch64-test-runner.sh"
glibc=${ABLA_AARCH64_GLIBC:-}
run=0
if [[ -n $glibc && -e $glibc/ld-linux-aarch64.so.1 ]] && aarch64_runner_available; then run=1; fi
expected="library: 20 keys
answer 300
library: thread 60
threaded 60"
# A glibc host for the target: the C file, linked with only the target glibc's runtime files and no C development files.
link_host() { # OUTPUT [EXTRA...]
    local output=$1
    shift
    clang --target=aarch64-unknown-linux-gnu -O1 -fuse-ld=lld -nostdlib -o "$output" \
        "$glibc/crt1.o" "$glibc/crti.o" "$@" "$glibc/libc.so.6" "$glibc/ld-linux-aarch64.so.1" "$glibc/crtn.o" \
        -Wl,--dynamic-linker="$glibc/ld-linux-aarch64.so.1" -Wl,-rpath,"$glibc"
}

for mode in release fast; do
    flags=()
    [[ $mode == fast ]] && flags=(--fast)
    library=$out/libabla_app-$mode.so
    archive=$out/libabla_app-$mode.a
    "$compiler" build "$case_dir/main.ab" --target aarch64-linux --emit shared-library "${flags[@]}" --no-cache \
        -o "$library" > "$out/build-so-$mode.log" 2>&1 || { cat "$out/build-so-$mode.log" >&2; fail "$mode shared library does not build"; }
    "$compiler" build "$case_dir/main.ab" --target aarch64-linux --emit static-library "${flags[@]}" --no-cache \
        -o "$archive" > "$out/build-a-$mode.log" 2>&1 || { cat "$out/build-a-$mode.log" >&2; fail "$mode static library does not build"; }

    "$readelf" -h "$library" > "$out/header-$mode.txt"
    grep -E 'Machine:.*AArch64' "$out/header-$mode.txt" > /dev/null || fail "$mode shared library is not AArch64"
    grep -E 'Type:.*DYN' "$out/header-$mode.txt" > /dev/null || fail "$mode shared library is not a shared object"
    "$readelf" -d -l "$library" > "$out/dynamic-$mode.txt"
    ! grep -E '\(NEEDED\)' "$out/dynamic-$mode.txt" > /dev/null || fail "$mode shared library names a library: $(grep NEEDED "$out/dynamic-$mode.txt")"
    ! grep -E '^ *INTERP' "$out/dynamic-$mode.txt" > /dev/null || fail "$mode shared library has PT_INTERP"
    undefined_dynamic "$library" > "$out/undefined-so-$mode.txt"
    check_symbols "$mode shared library" "$out/undefined-so-$mode.txt"
    "$nm" -D --defined-only "$library" | awk '{ print $NF }' > "$out/exports-$mode.txt"
    grep -xF abla_app_answer "$out/exports-$mode.txt" > /dev/null || fail "$mode shared library does not export abla_app_answer"
    # Hidden routines: the library's memmove, memcpy, memset and jump routines are its own, never exported to the host.
    for routine in memmove memcpy memset _setjmp _longjmp abla_x64_syscall; do
        ! grep -xF "$routine" "$out/exports-$mode.txt" > /dev/null || fail "$mode shared library exports $routine"
    done
    "$readelf" -r -W "$library" | awk '/R_AARCH64_/ { print $3 }' | sort -u > "$out/relocations-$mode.txt"
    kinds=$(grep -vxE 'R_AARCH64_(RELATIVE|GLOB_DAT|JUMP_SLOT|ABS64|TLSDESC|TLS_TPREL64|TLS_DTPMOD64|TLS_DTPREL64)' \
        "$out/relocations-$mode.txt" || true)
    [[ -z $kinds ]] || fail "$mode shared library has relocations a loader may not apply: $kinds"

    undefined_archive "$archive" > "$out/undefined-a-$mode.txt"
    check_symbols "$mode static library" "$out/undefined-a-$mode.txt"

    if ((run)); then
        link_host "$out/host-dl-$mode" "$case_dir/host.c" || fail 'the dlopen host does not link'
        link_host "$out/host-a-$mode" -DABLA_STATIC "$case_dir/host.c" "$archive" || fail "$mode static library does not link into a glibc host"
        for host in dl a; do
            status=0
            aarch64_run --timeout 120 -- "$out/host-$host-$mode" "$library" > "$out/run-$host-$mode.out" 2> "$out/run-$host-$mode.err" || status=$?
            # Sorted: the library writes by system call at once, the host's printf when its buffer is flushed at exit.
            if ((status != 0)) || [[ $(sort "$out/run-$host-$mode.out") != "$(sort <<< "$expected")" ]]; then
                cat "$out/run-$host-$mode.out" "$out/run-$host-$mode.err" >&2
                fail "$mode library run from the $host host: status $status, output above"
            fi
        done
    fi
done

# The control: the symbol check rejects what the libc runtime path left undefined before (#811), next to the two allowed.
printf '%s\n' malloc pthread_create write > "$out/undefined-control.txt"
if (check_symbols control "$out/undefined-control.txt") 2> /dev/null; then fail 'the control with malloc and write passed the symbol check'; fi

if ((run)); then
    echo 'aarch64 library: shared and static, release and --fast: no NEEDED, only pthread_create/join undefined; ran from a glibc host (dlopen and static link)'
else
    echo 'aarch64 library: shared and static, release and --fast: no NEEDED, only pthread_create/join undefined; run skipped (no ABLA_AARCH64_GLIBC or AArch64 runner)'
fi
