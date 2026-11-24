#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/android-extension"
library="$output_directory/src/main/jniLibs/arm64-v8a/libabla_app.so"
abi_manifest="$library.abi.json"
mkdir -p "$output_directory"

build_once() {
    "$compiler" build \
        "$project_root/tests/cases/android-extension/build.ab" \
        -o "$output_directory/build-driver" --fast --no-cache
}

build_once
first_identity=$(sha256sum "$library" | cut -d' ' -f1)
first_abi_identity=$(sha256sum "$abi_manifest" | cut -d' ' -f1)
rm -f "$abi_manifest"
build_once
second_identity=$(sha256sum "$library" | cut -d' ' -f1)
second_abi_identity=$(sha256sum "$abi_manifest" | cut -d' ' -f1)
[[ $first_identity == "$second_identity" ]] || exit 1
[[ $first_abi_identity == "$second_abi_identity" ]] || exit 1

set +e
"$output_directory/build-driver"
driver_status=$?
set -e
[[ $driver_status -eq 37 ]] || exit 1

grep -q 'AArch64' <<<"$(llvm-readelf -h "$library")"
grep -q 'DYN (Shared object file)' <<<"$(llvm-readelf -h "$library")"
llvm-readelf -lW "$library" | awk '
    $1 == "LOAD" {
        seen = 1
        if ($NF != "0x4000") {
            print "Android extension: expected 16 KiB PT_LOAD alignment: " $0 > "/dev/stderr"
            bad = 1
        }
    }
    END { exit (!seen || bad) }
'
grep -q ' abla_app_answer$' <<<"$(llvm-nm -D --defined-only "$library")"
grep -q '"schema":"abla.abi.v1"' "$abi_manifest"
grep -q '"name":"android-arm64"' "$abi_manifest"
grep -q '"symbol":"abla_app_answer"' "$abi_manifest"
grep -q '"ownership":"value"' "$abi_manifest"
grep -q '"panic":"not-contained"' "$abi_manifest"
node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' \
    "$abi_manifest"

header="$output_directory/src/main/cpp/abla-app.h"
jni="$output_directory/src/main/cpp/abla_jni.c"
kotlin="$output_directory/src/main/kotlin/org/abla/generated/AblaApp.kt"
cmake="$output_directory/src/main/cpp/CMakeLists.txt"
gradle="$output_directory/abla.gradle.kts"
[[ -s $header && -s $jni && -s $kotlin && -s $cmake && -s $gradle ]] || exit 1
grep -q 'int64_t abla_app_answer(void)' "$header"
grep -q 'Java_org_abla_generated_AblaApp_answer' "$jni"
# libabla_jni.so installs the bionic functions libabla_app.so calls through, in JNI_OnLoad (decision #121).
grep -q 'JNIEXPORT jint JNICALL JNI_OnLoad' "$jni"
grep -q 'abla_android_host_install(&abla_host)' "$jni"
grep -q 'pthread_key_create, pthread_getspecific, pthread_setspecific, pthread_create, pthread_join' "$jni"
grep -q 'int64_t abla_android_host_install(const struct abla_android_host \*host);' "$header"
grep -q ' T abla_android_host_install$' <<<"$(llvm-nm -D --defined-only "$library")"
[[ -z $(llvm-nm -D --undefined-only "$library") ]]
grep -q 'external fun answer(): Long' "$kotlin"
grep -q 'IMPORTED_LOCATION.*ANDROID_ABI.*libabla_app.so' "$cmake"
grep -q 'IMPORTED_NO_SONAME TRUE' "$cmake"
grep -Fq 'target_link_options(abla_jni PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")' "$cmake"
grep -q 'jniLibs.srcDir' "$gradle"

set +e
"$compiler" build \
    "$project_root/tests/cases/android-extension/invalid-target.ab" \
    -o "$output_directory/invalid-target" --fast --no-cache \
    >"$output_directory/invalid-target.out" \
    2>"$output_directory/invalid-target.err"
invalid_target_status=$?
set -e
[[ $invalid_target_status -ne 0 ]] || exit 1
grep -q 'error\[E_BUILD_TARGET_DEFINITION\]' \
    "$output_directory/invalid-target.err"

# The NDK lookup belongs to the extension: the compiler reads none of the NDK's variables and names none of its files.
if rg -n 'ABLA_ANDROID|ANDROID_NDK|ANDROID_HOME|ANDROID_SDK_ROOT|libclang_rt' \
    "$project_root/src" >/dev/null; then
    echo "Android NDK lookup leaked into the compiler" >&2
    exit 1
fi

# Discover a synthetic NDK through both roots. A scalar export has no dependency, and an export importing
# the stub's test symbol keeps the dependency.
fake="$output_directory/fake"
rm -rf "$fake"
ndk="$fake/sdk/ndk/27.0.0/toolchains/llvm/prebuilt/linux-x86_64"
mkdir -p "$ndk/lib/clang/20/lib/linux" "$ndk/sysroot/usr/lib/aarch64-linux-android/24"
: > "$fake/empty.s"
llvm-mc -triple aarch64-linux-android -filetype=obj "$fake/empty.s" -o "$fake/empty.o"
llvm-ar rcs "$ndk/lib/clang/20/lib/linux/libclang_rt.builtins-aarch64-android.a" "$fake/empty.o"
llvm-mc -triple aarch64-linux-android -filetype=obj -o "$fake/libc.o" <<'ASM'
.text
.globl abla_android_stub_probe
abla_android_stub_probe:
    mov x0, #42
    ret
ASM
ld.lld -shared -m aarch64linux -soname libc.so "$fake/libc.o" -o "$ndk/sysroot/usr/lib/aarch64-linux-android/24/libc.so"
needed() { llvm-readelf -d "$library" | grep -c 'NEEDED.*\[libc.so\]' || true; }
without_ndk=(env -u ABLA_ANDROID_NDK -u ANDROID_NDK_ROOT -u ANDROID_NDK_HOME
    -u ANDROID_HOME -u ANDROID_SDK_ROOT -u ABLA_ANDROID_BUILTINS)

"${without_ndk[@]}" \
    "$compiler" build "$project_root/tests/cases/android-extension/build.ab" \
    -o "$output_directory/build-driver" --fast --no-cache
[[ $(needed) -eq 0 ]] || { echo "a library built with no NDK needs libc.so" >&2; exit 1; }
"${without_ndk[@]}" ABLA_ANDROID_NDK="$fake/sdk/ndk/27.0.0" \
    "$compiler" build "$project_root/tests/cases/android-extension/build.ab" \
    -o "$output_directory/build-driver" --fast --no-cache
[[ $(needed) -eq 0 ]] || { echo "an import-free Android library needs libc.so" >&2; exit 1; }

"${without_ndk[@]}" ABLA_TEST_ANDROID_IMPORT=1 ABLA_ANDROID_NDK="$fake/sdk/ndk/27.0.0" \
    "$compiler" build "$project_root/tests/cases/android-extension/build.ab" \
    -o "$output_directory/build-driver" --fast --no-cache
[[ $(needed) -eq 1 ]] || { echo "ABLA_ANDROID_NDK: the library does not need libc.so" >&2; exit 1; }
"${without_ndk[@]}" ABLA_TEST_ANDROID_IMPORT=1 ANDROID_HOME="$fake/sdk" \
    "$compiler" build "$project_root/tests/cases/android-extension/build.ab" \
    -o "$output_directory/build-driver" --fast --no-cache
[[ $(needed) -eq 1 ]] || { echo "ANDROID_HOME: the library does not need libc.so" >&2; exit 1; }

# Without the two grants the build stops and says which one and where it came from.
set +e
"$compiler" build "$project_root/tests/cases/android-extension/missing-grant.ab" \
    -o "$output_directory/missing-grant" --fast --no-cache \
    >"$output_directory/missing-grant.out" 2>"$output_directory/missing-grant.err"
missing_status=$?
set -e
[[ $missing_status -ne 0 ]] || { echo "a build script without the grants built" >&2; exit 1; }
grep -q 'compile.effect-denied:filesystem.read:androidBuildArm64Library->androidNdkLookup' \
    "$output_directory/missing-grant.err"
grep -q '#compilerGrant' "$output_directory/missing-grant.err"

if rg -n 'android-arm64|aarch64-linux-android' \
    "$project_root/src" >/dev/null; then
    echo "Android platform policy leaked into the compiler" >&2
    exit 1
fi

example_root="$project_root/build/examples/android"
"$compiler" build \
    "$project_root/examples/android/build.ab" \
    -o "$example_root/build-driver" --fast --no-cache
[[ -s $example_root/build.gradle.kts ]] || exit 1
[[ -s $example_root/settings.gradle.kts ]] || exit 1
[[ -s $example_root/src/main/AndroidManifest.xml ]] || exit 1
[[ -s $example_root/src/main/kotlin/org/abla/example/MainActivity.kt ]] || exit 1
[[ -s $example_root/src/main/jniLibs/arm64-v8a/libabla_app.so ]] || exit 1
grep -q 'abiFilters += "arm64-v8a"' "$example_root/build.gradle.kts"
grep -q 'Hello from Abla:' \
    "$example_root/src/main/kotlin/org/abla/example/MainActivity.kt"
grep -q 'android.intent.category.LAUNCHER' \
    "$example_root/src/main/AndroidManifest.xml"

echo "Android extension: deterministic arm64 library, integration, and runnable example project passed"
