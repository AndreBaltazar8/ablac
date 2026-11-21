#!/usr/bin/env bash
# An arm64 Android library actually executed (#811): the library tests/cases/android-run/lib.ab is built by the Android
# build step, loaded with dlopen by a small NDK-built driver running under bionic's own linker (linker64, libc, libm,
# libdl of Google's arm64 Android 36 image) on qemu-aarch64, and its exports are called: getrandom (secureRandomBytes)
# through the library's own system call routine, and heap, strings, maps and thread-locals (emulated TLS on bionic's
# pthread keys). It catches what the link check (tools/test-android-link.sh) cannot: a library the dynamic linker
# refuses (an import no needed library provides: no DT_NEEDED libc.so, a symbol newer than the API level), a crash
# in the library's start-up (init arrays, relocations), a wrong system call number or translation, a TLS or heap
# fault, a wrong result.
# Needs the NDK (ABLA_ANDROID_NDK, ANDROID_NDK_ROOT, ... as the other Android tests), qemu-aarch64 and a bionic sysroot
# made by tools/prepare-bionic-sysroot.sh (ABLA_BIONIC_ROOT=<directory>); without any of them it says so and skips.
set -euo pipefail
# Its build helper (abla/android/build) writes the generated project with compiler.writeFile (read against the working
# directory) and builds into it with buildProgram (read against the build file, decision #91 A): until decision #95
# settles the file API, the working-directory reading stays allowed here, with its warning.
export ABLA_BUILD_PATH_CWD=warn
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux ]]; then echo 'android run: Linux only'; exit 0; fi
missing() {
    if [[ ${ABLA_REQUIRE_ANDROID_TESTS:-0} == 1 ]]; then
        echo "android run: required dependency missing: $1" >&2
        exit 1
    fi
    echo "android run: $1 missing; skipped"
    exit 0
}
bionic=${ABLA_BIONIC_ROOT:-}
[[ -n $bionic && -x $bionic/system/bin/bootstrap/linker64 ]] ||
    missing 'bionic sysroot (set ABLA_BIONIC_ROOT)'
command -v qemu-aarch64 > /dev/null || missing qemu-aarch64
clang=
for r in "${ABLA_ANDROID_NDK:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK_HOME:-}" "${ANDROID_HOME:-}/ndk" \
    "${ANDROID_SDK_ROOT:-}/ndk" "${ANDROID_HOME:-}/ndk-bundle" "${ANDROID_SDK_ROOT:-}/ndk-bundle"; do
    if [[ -n $r && -d $r ]]; then
        clang=$(find -L "$r" -name aarch64-linux-android24-clang 2> /dev/null | sort -V | tail -n 1 || true)
        [[ -z $clang ]] || break
    fi
done
[[ -n $clang ]] || missing 'Android NDK (set ABLA_ANDROID_NDK)'
out=build/android-run
rm -rf "$out"
mkdir -p "$out"
fail() { echo "android run: $1" >&2; exit 1; }
"$compiler" build tests/cases/android-run/build.ab -o "$out/build" --fast --no-cache > "$out/build.log" 2>&1 \
    || { cat "$out/build.log" >&2; fail 'the build program did not build'; }
status=0
"$out/build" > "$out/generate.log" 2>&1 || status=$?
[[ $status -eq 37 ]] || { cat "$out/generate.log" >&2; fail "building the library failed ($status)"; }
library=$PWD/$out/lib/src/main/jniLibs/arm64-v8a/libabla_app.so
[[ -f $library ]] || fail "no $library"
"$clang" tests/cases/android-run/driver.c -o "$out/driver" -ldl -Wl,--export-dynamic || fail 'the driver did not build'
status=0
LD_LIBRARY_PATH="$bionic/system/lib64/bootstrap:$bionic/system/lib64" timeout 300 qemu-aarch64 \
    "$bionic/system/bin/bootstrap/linker64" "$PWD/$out/driver" "$library" \
    abla_run_random nonzero abla_run_heap 465 abla_run_thread 142 abla_run_threads_heap 1860 abla_run_seed 78 abla_run_nested 77 abla_run_collected 1 > "$out/run.out" 2> "$out/run.err" < /dev/null || status=$?
if [[ $status -ne 0 ]]; then
    cat "$out/run.out" >&2
    grep -v 'linkerconfig' "$out/run.err" >&2 || true
    fail "the driver failed ($status)"
fi
grep -q '^abla_run_random ' "$out/run.out" && grep -qx 'abla_run_heap 465' "$out/run.out" && grep -qx 'abla_run_thread 142' "$out/run.out" && grep -qx 'abla_run_threads_heap 1860' "$out/run.out" && grep -qx 'abla_run_seed 78' "$out/run.out" || { cat "$out/run.out" >&2; fail 'unexpected output'; }
# Threads the library did not start (JNI-style) call one export at the same time, under the collector's stress mode
# (a collection at every safe point) and without: each export enters and leaves the runtime (heap lock live, a count of threads inside, the globals initialized once), and a
# nested export runs while the globals initialize. Without that this crashes.
for stress in 0 1; do
    count=8
    [[ $stress -eq 0 ]] || count=4
    status=0
    ABLA_GC_STRESS=$stress LD_LIBRARY_PATH="$bionic/system/lib64/bootstrap:$bionic/system/lib64" timeout 600 qemu-aarch64 \
        "$bionic/system/bin/bootstrap/linker64" "$PWD/$out/driver" "$library" -t "$count" abla_run_churn 1 \
        > "$out/threads-$stress.out" 2> "$out/threads-$stress.err" < /dev/null || status=$?
    if [[ $status -ne 0 ]]; then
        cat "$out/threads-$stress.out" >&2
        grep -v 'linkerconfig' "$out/threads-$stress.err" >&2 || true
        fail "calls from $count foreign threads (GC stress $stress) failed ($status)"
    fi
done
# A panic in a debug build: the message, the stack header and the load address on standard error, then the process ends
# with status 101 (qemu-user has no process_vm_readv, so the frames themselves show on hardware only).
ABLA_DEBUG=1 "$compiler" build tests/cases/android-run/build-debug.ab -o "$out/build-debug" --fast --no-cache > "$out/build-debug.log" 2>&1 \
    || { cat "$out/build-debug.log" >&2; fail 'the debug build program did not build'; }
status=0
ABLA_DEBUG=1 "$out/build-debug" > "$out/generate-debug.log" 2>&1 || status=$?
[[ $status -eq 37 ]] || { cat "$out/generate-debug.log" >&2; fail "building the debug library failed ($status)"; }
debug_library=$PWD/$out/lib-debug/src/main/jniLibs/arm64-v8a/libabla_app.so
status=0
LD_LIBRARY_PATH="$bionic/system/lib64/bootstrap:$bionic/system/lib64" timeout 300 qemu-aarch64 \
    "$bionic/system/bin/bootstrap/linker64" "$PWD/$out/driver" "$debug_library" abla_run_panic 0 \
    > "$out/panic.out" 2> "$out/panic.err" < /dev/null || status=$?
[[ $status -eq 101 ]] && grep -qx 'panic: index 5 out of bounds for array of size 1' "$out/panic.err" &&
    grep -q '^stack (return addresses' "$out/panic.err" && grep -q '^load address 0x' "$out/panic.err" ||
    { grep -v 'linkerconfig' "$out/panic.err" >&2; fail "the panic report: status $status"; }
echo 'android run: the arm64 Android library loads in bionic'"'"'s linker and its exports run under qemu-aarch64, also from concurrent foreign threads, and a debug panic reports'
