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
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux ]]; then echo 'android run: Linux only'; exit 0; fi
bionic=${ABLA_BIONIC_ROOT:-}
if [[ -z $bionic || ! -x $bionic/system/bin/bootstrap/linker64 ]]; then
    echo 'android run: no bionic sysroot (tools/prepare-bionic-sysroot.sh <dir>, then ABLA_BIONIC_ROOT=<dir>); skipped'
    exit 0
fi
command -v qemu-aarch64 > /dev/null || { echo 'android run: no qemu-aarch64; skipped'; exit 0; }
clang=
for r in "${ABLA_ANDROID_NDK:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK_HOME:-}" "${ANDROID_HOME:-}/ndk" \
    "${ANDROID_SDK_ROOT:-}/ndk" "${ANDROID_HOME:-}/ndk-bundle" "${ANDROID_SDK_ROOT:-}/ndk-bundle"; do
    if [[ -n $r && -d $r ]]; then
        found=$(find -L "$r" -name aarch64-linux-android24-clang 2> /dev/null | sort -V | tail -n 1 || true)
        [[ -z $found ]] || clang=$found
    fi
done
[[ -n $clang ]] || { echo 'android run: no Android NDK found (set ABLA_ANDROID_NDK); skipped'; exit 0; }
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
"$clang" tests/cases/android-run/driver.c -o "$out/driver" -ldl || fail 'the driver did not build'
status=0
LD_LIBRARY_PATH="$bionic/system/lib64/bootstrap:$bionic/system/lib64" timeout 300 qemu-aarch64 \
    "$bionic/system/bin/bootstrap/linker64" "$PWD/$out/driver" "$library" \
    abla_run_random nonzero abla_run_heap 465 abla_run_thread 142 abla_run_threads_heap 1860 > "$out/run.out" 2> "$out/run.err" < /dev/null || status=$?
if [[ $status -ne 0 ]]; then
    cat "$out/run.out" >&2
    grep -v 'linkerconfig' "$out/run.err" >&2 || true
    fail "the driver failed ($status)"
fi
grep -q '^abla_run_random ' "$out/run.out" && grep -qx 'abla_run_heap 465' "$out/run.out" && grep -qx 'abla_run_thread 142' "$out/run.out" && grep -qx 'abla_run_threads_heap 1860' "$out/run.out" || { cat "$out/run.out" >&2; fail 'unexpected output'; }
echo 'android run: the arm64 Android library loads in bionic'"'"'s linker and its exports run under qemu-aarch64'
