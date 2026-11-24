#!/usr/bin/env bash
# An arm64 Android library actually executed (#811): the library tests/cases/android-run/lib.ab is built by the Android
# build step, loaded with dlopen by a small NDK-built driver running under bionic's own linker (linker64, libc, libm,
# libdl of Google's arm64 Android 36 image) on AArch64, and its exports are called: getrandom (secureRandomBytes)
# through the library's own system call routine, and heap, strings, maps and thread-locals (emulated TLS on bionic's
# pthread keys, which the library calls through the table of bionic functions the driver installs first, as the app's
# libabla_jni.so does; without the table an export ends the process with a message). It catches what the link check
# (tools/test-android-link.sh) cannot: a library the dynamic linker
# refuses (an import no needed library provides: no DT_NEEDED libc.so, a symbol newer than the API level), a crash
# in the library's start-up (init arrays, relocations), a wrong system call number or translation, a TLS or heap
# fault, a wrong result.
# Needs the NDK (ABLA_ANDROID_NDK, ANDROID_NDK_ROOT, ... as the other Android tests), an AArch64 runner and a bionic sysroot
# made by tools/prepare-bionic-sysroot.sh (ABLA_BIONIC_ROOT=<directory>); without any of them it says so and skips.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
source "$root/tools/aarch64-test-runner.sh"
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
aarch64_runner_available || missing 'AArch64 runner'
bionic=$(cd -- "$bionic" && pwd)
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
"$clang" -I "$out/lib/src/main/cpp" tests/cases/android-run/driver.c -o "$out/driver" -ldl -Wl,--export-dynamic ||
    fail 'the driver did not build'
# The generated adapter (libabla_jni.so), compiled and linked as the app's CMake does: its DT_NEEDED libabla_app.so is the
# library the driver loaded (the library's directory is on LD_LIBRARY_PATH); the -j runs install the table through its JNI_OnLoad.
mkdir -p "$out/jni"
"$clang" -shared -fPIC -I "$out/lib/src/main/cpp" "$out/lib/src/main/cpp/abla_jni.c" -o "$out/jni/libabla_jni.so" \
    -L "${library%/*}" -l:libabla_app.so \
    -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 || fail 'the generated libabla_jni.so did not build'
bionic_inputs=()
if [[ -n ${ABLA_AARCH64_RUN:-} ]]; then
    # The Android linker takes an absolute program path. /proc/self/cwd
    # resolves inside the per-job directory in both the Pi and QEMU lanes.
    mkdir -p "$out/bionic/lib64/bootstrap"
    for lib in lib64/liblog.so lib64/bootstrap/{libc,libdl_android,libdl,libm}.so; do
        cp -L -- "$bionic/system/$lib" "$out/bionic/$lib"
        bionic_inputs+=(--input "bionic/$lib")
    done
fi
run_android() ( # driver timeout library arguments...
    driver=$1
    duration=$2
    image=$3
    shift 3
    # @jni@ in the arguments: the generated adapter's path where the driver runs.
    arguments=("$@")
    stress=()
    if [[ -v ABLA_GC_STRESS ]]; then stress=(--env "ABLA_GC_STRESS=$ABLA_GC_STRESS"); fi
    linker=$bionic/system/bin/bootstrap/linker64
    if [[ -n ${ABLA_AARCH64_RUN:-} ]]; then
        cd "$out"
        relative_image=${image#"$root/$out/"}
        aarch64_run --timeout "$duration" "${stress[@]}" "${bionic_inputs[@]}" \
            --input "$driver" --input "$relative_image" --input jni/libabla_jni.so \
            --env "LD_LIBRARY_PATH=/proc/self/cwd/bionic/lib64/bootstrap:/proc/self/cwd/bionic/lib64:/proc/self/cwd/${relative_image%/*}" \
            -- "$linker" "/proc/self/cwd/$driver" "/proc/self/cwd/$relative_image" "${arguments[@]/#@jni@//proc/self/cwd/jni/libabla_jni.so}"
    else
        aarch64_run --timeout "$duration" "${stress[@]}" \
            --env "LD_LIBRARY_PATH=$bionic/system/lib64/bootstrap:$bionic/system/lib64:${image%/*}" \
            -- "$linker" "$PWD/$out/$driver" "$image" "${arguments[@]/#@jni@/$PWD/$out/jni/libabla_jni.so}"
    fi
)
status=0
run_android driver 300 "$library" \
    abla_run_random nonzero abla_run_heap 465 abla_run_thread 142 abla_run_threads_heap 1860 abla_run_seed 78 abla_run_nested 77 abla_run_collected 1 > "$out/run.out" 2> "$out/run.err" < /dev/null || status=$?
if [[ $status -ne 0 ]]; then
    cat "$out/run.out" >&2
    grep -v 'linkerconfig' "$out/run.err" >&2 || true
    fail "the driver failed ($status)"
fi
grep -q '^abla_run_random ' "$out/run.out" && grep -qx 'abla_run_heap 465' "$out/run.out" && grep -qx 'abla_run_thread 142' "$out/run.out" && grep -qx 'abla_run_threads_heap 1860' "$out/run.out" && grep -qx 'abla_run_seed 78' "$out/run.out" || { cat "$out/run.out" >&2; fail 'unexpected output'; }
# The driver installed the host table as libabla_jni.so does (decision #121): the first install takes, the same table again
# answers 0, another table 1 (the first stays) and an unknown version -1.
grep -qx 'host table: 0 0 1 -1' "$out/run.err" || { grep -v 'linkerconfig' "$out/run.err" >&2; fail 'the host table install answers'; }
# A plain dlopen without the table loads the library (it imports nothing, its start-up needs no table); the first export
# that needs a thread-local ends the process with status 70 and says why, instead of jumping to a null function.
status=0
run_android driver 120 "$library" -n abla_run_heap 465 > "$out/no-table.out" 2> "$out/no-table.err" < /dev/null || status=$?
[[ $status -eq 70 ]] && grep -q '^abla: this Android library was called before its host installed the thread table' "$out/no-table.err" ||
    { cat "$out/no-table.out" >&2; grep -v 'linkerconfig' "$out/no-table.err" >&2; fail "an export without the host table: status $status"; }
# Threads the library did not start (JNI-style) call one export at the same time, under the collector's stress mode
# (a collection at every safe point) and without: each export enters and leaves the runtime (heap lock live, a count of threads inside, the globals initialized once), and a
# nested export runs while the globals initialize. Without that this crashes. The table comes from the driver (host) and
# from the generated adapter's JNI_OnLoad (jni), as in an app.
for mode in host jni; do
for stress in 0 1; do
    count=8
    [[ $stress -eq 0 ]] || count=4
    status=0
    adapter=()
    [[ $mode == host ]] || adapter=(-j @jni@)
    ABLA_GC_STRESS=$stress run_android driver 600 "$library" "${adapter[@]}" -t "$count" abla_run_churn 1 \
        > "$out/threads-$mode-$stress.out" 2> "$out/threads-$mode-$stress.err" < /dev/null || status=$?
    if [[ $status -ne 0 ]]; then
        cat "$out/threads-$mode-$stress.out" >&2
        grep -v 'linkerconfig' "$out/threads-$mode-$stress.err" >&2 || true
        fail "calls from $count foreign threads (GC stress $stress, table from the $mode) failed ($status)"
    fi
    if [[ $mode == jni ]] && ! grep -qx 'JNI_OnLoad 0x10006' "$out/threads-$mode-$stress.err"; then
        fail "the generated JNI_OnLoad did not install the table (GC stress $stress)"
    fi
done
done
# Every worker starts from the barrier as a foreign caller. The interposed key creator pauses
# while the library's first-use state is in progress, giving the other workers time to observe it.
"$clang" -DTEST_DELAY_KEY -I "$out/lib/src/main/cpp" tests/cases/android-run/driver.c -o "$out/driver-delayed-key" -ldl -Wl,--export-dynamic ||
    fail 'the delayed-key driver did not build'
status=0
ABLA_GC_STRESS=0 run_android driver-delayed-key 60 "$library" -t 8 abla_run_churn 1 \
    > "$out/delayed-key.out" 2> "$out/delayed-key.err" < /dev/null || status=$?
if [[ $status -ne 0 ]] || ! grep -Fxq 'android test: delayed pthread_key_create' "$out/delayed-key.err" ||
    ! grep -Fxq 'abla_run_churn x8 ok' "$out/delayed-key.out"; then
    cat "$out/delayed-key.out" >&2
    grep -v 'linkerconfig' "$out/delayed-key.err" >&2 || true
    fail "calls during pthread key creation failed ($status)"
fi
# A panic in a debug build: the message, the stack header and the load address on standard error, then the process ends
# with status 101 (qemu-user has no process_vm_readv, so the frames themselves show on hardware only).
ABLA_DEBUG=1 "$compiler" build tests/cases/android-run/build-debug.ab -o "$out/build-debug" --fast --no-cache > "$out/build-debug.log" 2>&1 \
    || { cat "$out/build-debug.log" >&2; fail 'the debug build program did not build'; }
status=0
ABLA_DEBUG=1 "$out/build-debug" > "$out/generate-debug.log" 2>&1 || status=$?
[[ $status -eq 37 ]] || { cat "$out/generate-debug.log" >&2; fail "building the debug library failed ($status)"; }
debug_library=$PWD/$out/lib-debug/src/main/jniLibs/arm64-v8a/libabla_app.so
status=0
run_android driver 300 "$debug_library" abla_run_panic 0 \
    > "$out/panic.out" 2> "$out/panic.err" < /dev/null || status=$?
[[ $status -eq 101 ]] && grep -qx 'panic: index 5 out of bounds for array of size 1' "$out/panic.err" &&
    grep -q '^stack (return addresses' "$out/panic.err" && grep -q '^load address 0x' "$out/panic.err" ||
    { grep -v 'linkerconfig' "$out/panic.err" >&2; fail "the panic report: status $status"; }
echo 'android run: the arm64 Android library loads in bionic'"'"'s linker and its exports run on AArch64, also from concurrent foreign threads, and a debug panic reports'
