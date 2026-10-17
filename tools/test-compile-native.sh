#!/usr/bin/env bash
# Native code at compile time: extern:"c" calls (the compiler process's C
# library and a manifest native library built here), raw memory, the standard
# library's system calls, and the trusted.native grant that gates them.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$project_root/$compiler"
cases="$project_root/tests/cases/compile-native"
output_directory="$project_root/build/compile-native"
rm -rf "$output_directory"
mkdir -p "$output_directory"

run_case() { # <case directory> <output> [compiler arguments…]
    local directory=$1 output=$2
    shift 2
    (cd "$directory" && "$compiler" "$@" main.ab -o "$output" --no-cache)
}

expect_42() { # <case directory> <program> [environment assignments…]
    local directory=$1 program=$2 status
    shift 2
    set +e
    (cd "$directory" && env "$@" "$program") > "$program.out"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        printf '%s exited %s, expected 42\n' "$program" "$status" >&2
        cat "$program.out" >&2
        exit 1
    fi
}

# The compiler process's C library, raw memory and abla/fs.
run_case "$cases/granted" "$output_directory/granted" build
expect_42 "$cases/granted" "$output_directory/granted"

# Denied: rejected by the effect analysis, and never performed.
printf 'keep\n' > "$cases/denied/sentinel.txt"
trap 'rm -f "$cases/denied/sentinel.txt"' EXIT
set +e
(cd "$cases/denied" && "$compiler" --emit-llvm main.ab) \
    > "$output_directory/denied.ll" 2> "$output_directory/denied.err"
denied=$?
set -e
[[ $denied -ne 0 ]] || exit 1
grep -q 'compile.effect-denied:trusted.native' "$output_directory/denied.err"

[[ -f $cases/denied/sentinel.txt ]] || {
    echo 'a denied compile-time C call was performed' >&2
    exit 1
}

# A parser handler (it runs before the effect analysis) is denied when evaluated.
printf 'keep\n' > "$cases/handler-denied/sentinel.txt"
trap 'rm -f "$cases/denied/sentinel.txt" "$cases/handler-denied/sentinel.txt"' EXIT
set +e
(cd "$cases/handler-denied" && "$compiler" --emit-llvm main.ab) \
    > "$output_directory/handler-denied.ll" 2> "$output_directory/handler-denied.err"
handler_denied=$?
set -e
[[ $handler_denied -ne 0 ]] || exit 1
grep -q 'E_COMPILE_NATIVE_DENIED' "$output_directory/handler-denied.err"
[[ -f $cases/handler-denied/sentinel.txt ]] || {
    echo 'a denied parser-handler C call was performed' >&2
    exit 1
}

# A manifest native library, built here and found through LIBRARY_PATH.
library_directory="$output_directory/lib"
mkdir -p "$library_directory"
if [[ $(uname -s) == Darwin ]]; then
    library="$library_directory/libctnative.dylib"
    clang -dynamiclib -O1 "$cases/library/ctnative.c" -o "$library" \
        -install_name "$library"
else
    library="$library_directory/libctnative.so"
    clang -shared -fPIC -O1 "$cases/library/ctnative.c" -o "$library"
fi
LIBRARY_PATH="$library_directory" run_case "$cases/library" \
    "$output_directory/library" build
expect_42 "$cases/library" "$output_directory/library" \
    LD_LIBRARY_PATH="$library_directory" DYLD_LIBRARY_PATH="$library_directory"

# A library that is not found: the missing symbol names it.
set +e
(cd "$cases/library-missing" && "$compiler" build main.ab \
    -o "$output_directory/missing" --no-cache) \
    > "$output_directory/missing.log" 2> "$output_directory/missing.err"
missing=$?
set -e
[[ $missing -ne 0 ]] || exit 1
grep -q 'E_COMPILE_NATIVE_SYMBOL' "$output_directory/missing.err"
grep -q 'nativeLibraries not found: ctnativemissing' "$output_directory/missing.err"

# The flat host API: linked natively, performed at compile time under the
# capability each function implies.
rm -rf "$cases/host/build-host-compile" "$cases/host/build-host-run"
run_case "$cases/host" "$output_directory/host" build
expect_42 "$cases/host" "$output_directory/host"
rm -rf "$cases/host/build-host-compile" "$cases/host/build-host-run"
rm -f "$cases/host-denied/denied-output.txt"
set +e
(cd "$cases/host-denied" && "$compiler" --emit-llvm main.ab) \
    > "$output_directory/host-denied.ll" 2> "$output_directory/host-denied.err"
host_denied=$?
set -e
[[ $host_denied -ne 0 ]] || exit 1
grep -q 'compile.effect-denied:filesystem.write:record->ablaHostWriteFileAtomic' \
    "$output_directory/host-denied.err"
[[ ! -e $cases/host-denied/denied-output.txt ]] || {
    echo 'a denied compile-time host write was performed' >&2
    exit 1
}

# abla/fs under a filesystem.read grant; println to the compiler's output.
(cd "$cases/fs-read" && "$compiler" build main.ab -o "$output_directory/fs-read" --no-cache) \
    > "$output_directory/fs-read.compile.out"
grep -q 'compile time read 19 bytes' "$output_directory/fs-read.compile.out"
expect_42 "$cases/fs-read" "$output_directory/fs-read"
set +e
(cd "$cases/fs-read-denied" && "$compiler" build main.ab -o "$output_directory/fs-read-denied" --no-cache) \
    > "$output_directory/fs-read-denied.log" 2> "$output_directory/fs-read-denied.err"
fs_denied=$?
set -e
[[ $fs_denied -ne 0 ]] || exit 1
grep -q 'compile.effect-denied:filesystem.read' "$output_directory/fs-read-denied.err"
(cd "$cases/print-only" && "$compiler" build main.ab -o "$output_directory/print-only" --no-cache) \
    > "$output_directory/print-only.compile.out"
grep -q 'printed at compile time: 42' "$output_directory/print-only.compile.out"
expect_42 "$cases/print-only" "$output_directory/print-only"

# A failed read is journaled: the cached build is not reused once the file exists.
rm -rf "$cases/fs-cache/build" "$cases/fs-cache/late.txt"
(cd "$cases/fs-cache" && "$compiler" build main.ab -o "$output_directory/fs-cache" >/dev/null)
[[ $("$output_directory/fs-cache") == false ]] || exit 1
printf 'now here\n' > "$cases/fs-cache/late.txt"
(cd "$cases/fs-cache" && "$compiler" build main.ab -o "$output_directory/fs-cache" >/dev/null)
result=$("$output_directory/fs-cache")
rm -rf "$cases/fs-cache/build" "$cases/fs-cache/late.txt"
[[ $result == true ]] || {
    echo 'a cached build ignored a file that appeared after a failed compile-time read' >&2
    exit 1
}

echo "compile-time native: C calls, callbacks, raw memory, system calls, a manifest library, the host API, abla/fs reads and println; denied calls not performed"
