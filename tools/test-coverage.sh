#!/usr/bin/env bash
# --coverage-functions: the files a program ran, written at exit; nothing without the flag or the variable; refusals;
# no partial file after SIGKILL; a flagged build differs from an unflagged one and the unflagged is untouched.
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
out="$project_root/build/coverage"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root"
fixture=tests/cases/coverage/main.ab
"$compiler" build "$fixture" -o "$out/flagged" --fast --coverage-functions
"$compiler" build "$fixture" -o "$out/plain" --fast --no-cache
expect_ran() { # file: main and used.ab listed, unused.ab not
    grep -qx 'tests/cases/coverage/main.ab' "$1" && grep -qx 'tests/cases/coverage/sub/used.ab' "$1" || { echo "coverage: missing a ran file in $1"; cat "$1"; exit 1; }
    ! grep -q 'unused.ab' "$1" || { echo "coverage: unused.ab listed in $1"; exit 1; }
}
sorted() { LC_ALL=C sort -c "$1" && [ "$(LC_ALL=C sort -u "$1" | wc -l)" = "$(wc -l < "$1")" ]; }

for mode in return exit panic; do
    status=0
    ABLA_COVERAGE_OUT="$out/$mode.txt" "$out/flagged" "$mode" || status=$?
    expect_ran "$out/$mode.txt"; sorted "$out/$mode.txt"
    [ ! -e "$out/$mode.txt.tmp" ] || { echo "coverage: $mode left its .tmp"; exit 1; }
done
# %p becomes the pid; the unflagged build and an unset variable write nothing.
ABLA_COVERAGE_OUT="$out/pid-%p.txt" "$out/flagged" return
[ "$(ls "$out"/pid-*.txt | wc -l)" = 1 ] && ! ls "$out"/pid-%p.txt 2>/dev/null
ABLA_COVERAGE_OUT="$out/plain.txt" "$out/plain" return
[ ! -e "$out/plain.txt" ] || { echo "coverage: an unflagged build wrote a file"; exit 1; }
(cd "$out" && "$out/flagged" return) ; [ -z "$(ls "$out" | grep -v -e flagged -e plain -e '\.txt$')" ]
# A function that never ran does not list its file.
status=0; ABLA_COVERAGE_OUT="$out/never.txt" "$out/flagged" never || status=$?
grep -qx 'tests/cases/coverage/sub/unused.ab' "$out/never.txt" || { echo "coverage: a called function's file is missing"; exit 1; }
# SIGTERM dumps (default disposition): the status is 143, the file is complete.
ABLA_COVERAGE_OUT="$out/term.txt" "$out/flagged" wait & pid=$!
sleep 0.5; kill -TERM "$pid"; status=0; wait "$pid" || status=$?
[ "$status" = 143 ] || { echo "coverage: SIGTERM status $status, expected 143"; exit 1; }
expect_ran "$out/term.txt"
# SIGKILL leaves neither the file nor a partial one.
ABLA_COVERAGE_OUT="$out/kill.txt" "$out/flagged" wait & pid=$!
sleep 0.5; kill -KILL "$pid"; wait "$pid" 2>/dev/null || true
[ ! -e "$out/kill.txt" ] && [ ! -e "$out/kill.txt.tmp" ] || { echo "coverage: SIGKILL left a file"; exit 1; }
# Hits from two threads and the main thread, one dump (one complete file, no .tmp).
"$compiler" build tests/cases/coverage/threads.ab -o "$out/threads" --fast --coverage-functions
ABLA_COVERAGE_OUT="$out/threads.txt" "$out/threads" || true
grep -qx 'tests/cases/coverage/threads.ab' "$out/threads.txt" && grep -qx 'tests/cases/coverage/sub/used.ab' "$out/threads.txt" \
    && grep -qx 'tests/cases/coverage/sub/unused.ab' "$out/threads.txt" && grep -qx 'tests/cases/coverage/sub/third.ab' "$out/threads.txt" \
    || { echo "coverage: a thread's file is missing"; cat "$out/threads.txt"; exit 1; }
sorted "$out/threads.txt"; [ ! -e "$out/threads.txt.tmp" ]
# Two processes on one path (no %p) never mix: the temporary is per process.
for round in 1 2 3 4 5 6; do
    ABLA_COVERAGE_OUT="$out/shared.txt" "$out/flagged" return & ABLA_COVERAGE_OUT="$out/shared.txt" "$out/flagged" exit &
    wait || true
    expect_ran "$out/shared.txt"; sorted "$out/shared.txt"
done
[ -z "$(ls "$out" | grep 'shared.txt.tmp')" ] || { echo "coverage: a temporary was left"; exit 1; }
# A path that does not fit is refused, not truncated: 2040 "./" segments (4080 bytes) and a 30-byte file name make
# 4110; a truncation to 4095 would leave the valid file name "abcdefghijklmn", which must not appear (the kernel
# would refuse the full path too, so this tells our refusal from the open() failing).
pad=$(printf './%.0s' $(seq 1 2040))
(cd "$out" && ABLA_COVERAGE_OUT="${pad}abcdefghijklmnopqrstuvwxyz.txt" "$out/flagged" return) || true
[ -z "$(ls "$out" | grep -e '^abcdefghijklmn')" ] || { echo "coverage: a path of 4096 bytes or more was truncated and written"; exit 1; }
(cd "$out" && ABLA_COVERAGE_OUT="./short-ok.txt" "$out/flagged" return) || true
[ -e "$out/short-ok.txt" ] || { echo "coverage: a short relative path was not written"; exit 1; }
# A compile-time call in a flagged build: it builds, runs and the list holds the program's files only.
"$compiler" build tests/cases/coverage/ct.ab -o "$out/ct" --fast --coverage-functions
ABLA_COVERAGE_OUT="$out/ct.txt" ABLA_COVERAGE_TEST=1 "$out/ct" || true
grep -qx 'tests/cases/coverage/ct.ab' "$out/ct.txt" || { echo "coverage: the compile-time fixture's list is wrong"; exit 1; }
# A shared library: the host asks for the list through abla_coverage_write, and it also dumps when the process ends.
"$compiler" build tests/cases/coverage-lib/lib.ab --emit shared-library -o "$out/libcov.so" --fast --coverage-functions
clang tests/cases/coverage-lib/caller.c -L"$out" -lcov -Wl,-rpath,"$out" -o "$out/libcaller"
"$out/libcaller" "$out/lib-write.txt"
grep -qx 'tests/cases/coverage-lib/lib.ab' "$out/lib-write.txt" && grep -qx 'tests/cases/coverage-lib/sub/helper.ab' "$out/lib-write.txt" \
    || { echo "coverage: the library's list is wrong"; cat "$out/lib-write.txt"; exit 1; }
ABLA_COVERAGE_OUT="$out/lib-exit.txt" "$out/libcaller"
grep -qx 'tests/cases/coverage-lib/sub/helper.ab' "$out/lib-exit.txt" || { echo "coverage: the library did not dump when the process ended"; exit 1; }
# Two flagged libraries in one host: no duplicate symbols (only the weak writer is visible), both run.
"$compiler" build tests/cases/coverage-lib/lib2.ab --emit shared-library -o "$out/libcovtwo.so" --fast --coverage-functions
clang tests/cases/coverage-lib/caller2.c -L"$out" -lcov -lcovtwo -Wl,-rpath,"$out" -o "$out/libcaller2"
"$out/libcaller2"
# A build graph mixes an object, a recursive host child and a Wasm module.
# Build plain first to populate caches, then require coverage from every supported node.
mkdir -p "$out/nested"
"$compiler" build tests/cases/coverage-nested/outer.ab -o "$out/nested/plain" --fast > "$out/nested/plain.log" 2>&1
clang tests/cases/coverage-lib/caller.c "$out/nested/libcov.o" -o "$out/nested/caller-plain" 2>/dev/null && { echo "coverage: unflagged library exported writer"; exit 1; }
ABLA_COVERAGE_OUT="$out/nested/plain-child.txt" "$out/nested/child"
[ ! -e "$out/nested/plain-child.txt" ] || { echo "coverage: unflagged child wrote a file"; exit 1; }
"$compiler" build tests/cases/coverage-nested/outer.ab -o "$out/nested/flagged" --fast --coverage-functions > "$out/nested/flagged.log" 2>&1
[ "$(grep -c 'warning\[W_COVERAGE_TARGET\].*coverage-wasm.*wasm32-module' "$out/nested/flagged.log")" = 1 ] || { cat "$out/nested/flagged.log"; echo "coverage: expected one child target warning"; exit 1; }
nm "$out/nested/libcov.o" | grep " W abla_coverage_write$" >/dev/null || { echo "coverage: nested object missing weak writer"; exit 1; }
clang tests/cases/coverage-lib/caller.c "$out/nested/libcov.o" -o "$out/nested/caller"
"$out/nested/caller" "$out/nested/library.txt"
grep -qx 'tests/cases/coverage-lib/sub/helper.ab' "$out/nested/library.txt" || { echo "coverage: nested library missing hits"; exit 1; }
ABLA_COVERAGE_OUT="$out/nested/child.txt" "$out/nested/child"
grep -qx 'tests/cases/coverage-nested/child.ab' "$out/nested/child.txt"
ABLA_COVERAGE_OUT="$out/nested/grandchild.txt" "$out/nested/grandchild" return
expect_ran "$out/nested/grandchild.txt"
[ -s "$out/nested/host.wasm" ] || { echo "coverage: unsupported child not built"; exit 1; }
# AArch64 Linux, under qemu-aarch64: the dump by system calls too (no libc), in --fast and release; each end, %p,
# SIGTERM (143) and threads. It could not build before: the dump's string helpers were x86-64 assembly.
if command -v qemu-aarch64 > /dev/null; then
    a64=$out/aarch64; mkdir -p "$a64"
    for build in fast release; do
        flags=--fast; [ "$build" = release ] && flags=
        "$compiler" build "$fixture" -o "$a64/flagged-$build" --target aarch64-linux $flags --coverage-functions \
            > "$a64/build-$build.log" 2>&1 || { cat "$a64/build-$build.log"; echo "coverage: aarch64 $build did not build"; exit 1; }
        for mode in return exit panic; do
            ABLA_COVERAGE_OUT="$a64/$build-$mode.txt" qemu-aarch64 "$a64/flagged-$build" "$mode" > /dev/null 2>&1 || true
            expect_ran "$a64/$build-$mode.txt"; sorted "$a64/$build-$mode.txt"
            [ ! -e "$a64/$build-$mode.txt.tmp" ] || { echo "coverage: aarch64 $build $mode left its .tmp"; exit 1; }
        done
        ABLA_COVERAGE_OUT="$a64/$build-pid-%p.txt" qemu-aarch64 "$a64/flagged-$build" return
        [ "$(ls "$a64"/$build-pid-*.txt | wc -l)" = 1 ] && ! ls "$a64/$build-pid-%p.txt" 2>/dev/null ||
            { echo "coverage: aarch64 $build %p was not the pid"; exit 1; }
        (cd "$a64" && qemu-aarch64 "$a64/flagged-$build" return)
        [ -z "$(ls "$a64" | grep -v -e flagged -e '\.txt$' -e '\.log$')" ] || { echo "coverage: aarch64 wrote without the variable"; exit 1; }
        # SIGTERM in --fast only: the fixture's wait is an empty loop, which a release build removes.
        [ "$build" = fast ] || continue
        ABLA_COVERAGE_OUT="$a64/$build-term.txt" qemu-aarch64 "$a64/flagged-$build" wait & pid=$!
        sleep 1; kill -TERM "$pid"; status=0; wait "$pid" || status=$?
        [ "$status" = 143 ] || { echo "coverage: aarch64 $build SIGTERM status $status, expected 143"; exit 1; }
        expect_ran "$a64/$build-term.txt"
    done
    "$compiler" build tests/cases/coverage/threads.ab -o "$a64/threads" --target aarch64-linux --fast --coverage-functions
    ABLA_COVERAGE_OUT="$a64/threads.txt" qemu-aarch64 "$a64/threads" > /dev/null 2>&1 || true
    grep -qx 'tests/cases/coverage/sub/third.ab' "$a64/threads.txt" && grep -qx 'tests/cases/coverage/sub/used.ab' "$a64/threads.txt" ||
        { echo "coverage: an aarch64 thread's file is missing"; cat "$a64/threads.txt"; exit 1; }
else
    echo "coverage: no qemu-aarch64, the aarch64 runs skipped"
fi
# Refused where it does not apply.
if "$compiler" build "$fixture" -o "$out/refused" --fast --coverage-functions --target-triple wasm32-unknown-unknown --object-format wasm --emit object > "$out/refused.log" 2>&1; then
    echo "coverage: wasm accepted the flag"; exit 1
fi
grep -q 'E_COVERAGE_TARGET' "$out/refused.log" || { cat "$out/refused.log"; echo "coverage: the refusal has no code"; exit 1; }
# A macOS executable dumps by the BSD system calls (it runs in tools/test-coverage-macos.sh on a Mac). Built here for both
# Macs: the flag is accepted, and the program's object (written before the link, which needs ABLA_MACOS_SDK away from
# macOS) calls none of the libSystem functions the dump used to (getenv, strstr, snprintf, open, signal, raise, usleep).
for mac in x86_64-macos arm64-macos; do
    "$compiler" build "$fixture" -o "$out/mac-$mac" --fast --no-cache --coverage-functions --target "$mac" \
        > "$out/mac-$mac.log" 2>&1 || true
    ! grep -q E_COVERAGE_TARGET "$out/mac-$mac.log" || { cat "$out/mac-$mac.log"; echo "coverage: $mac refused the flag"; exit 1; }
    [ -s "$out/mac-$mac.o" ] || { cat "$out/mac-$mac.log"; echo "coverage: no $mac object"; exit 1; }
    # llvm-nm: GNU nm cannot read Mach-O (and a failed read must fail here, not pass as "no imports").
    undefined=$(llvm-nm -u "$out/mac-$mac.o") || { echo "coverage: llvm-nm could not read the $mac object"; exit 1; }
    imports=$(grep -E "^ *(U )?_(getenv|strstr|snprintf|getpid|open|close|write|rename|signal|raise|usleep)\$" <<< "$undefined" || true)
    [ -z "$imports" ] || { echo "coverage: the $mac dump calls libSystem:"; echo "$imports"; exit 1; }
    # And it is instrumented: no imports also holds for an object the flag left alone (master 4ac86702 built macOS
    # programs without coverage: the build only enabled it for Linux triples, and the Mac CI found no file).
    llvm-nm "$out/mac-$mac.o" | grep -E ' _?abla_coverage_dump$' >/dev/null &&
        grep -a -F 'tests/cases/coverage/sub/used.ab' "$out/mac-$mac.o" >/dev/null ||
        { echo "coverage: the $mac object has no coverage dump or file list"; exit 1; }
done
# A macOS dylib is still refused (#833: it links the C adapter).
if "$compiler" build tests/cases/coverage-lib/lib.ab --emit shared-library -o "$out/refused-mac.dylib" --fast --coverage-functions \
    --target arm64-macos > "$out/refused-mac.log" 2>&1; then
    echo "coverage: a macOS dylib accepted the flag"; exit 1
fi
grep -q E_COVERAGE_TARGET "$out/refused-mac.log" || { cat "$out/refused-mac.log"; exit 1; }
echo "coverage: files listed at exit, exit(), panic and SIGTERM (x86-64 and AArch64 Linux); nothing for SIGKILL, an unset variable or an unflagged build; macOS objects by system calls; wasm and macOS dylibs refused"
