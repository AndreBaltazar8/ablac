#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/android-extension"
library="$output_directory/src/main/jniLibs/arm64-v8a/libabla_app.so"
mkdir -p "$output_directory"

build_once() {
    "$compiler" build \
        "$project_root/tests/cases/android-extension/build.ab" \
        -o "$output_directory/build-driver" --fast --no-cache
}

build_once
first_identity=$(sha256sum "$library" | cut -d' ' -f1)
build_once
second_identity=$(sha256sum "$library" | cut -d' ' -f1)
[[ $first_identity == "$second_identity" ]]

set +e
"$output_directory/build-driver"
driver_status=$?
set -e
[[ $driver_status -eq 37 ]]

llvm-readelf -h "$library" | grep -q 'AArch64'
llvm-readelf -h "$library" | grep -q 'DYN (Shared object file)'
llvm-nm -D --defined-only "$library" | grep -q ' abla_app_answer$'

header="$output_directory/src/main/cpp/abla-app.h"
jni="$output_directory/src/main/cpp/abla_jni.c"
kotlin="$output_directory/src/main/kotlin/org/abla/generated/AblaApp.kt"
cmake="$output_directory/src/main/cpp/CMakeLists.txt"
gradle="$output_directory/abla.gradle.kts"
[[ -s $header && -s $jni && -s $kotlin && -s $cmake && -s $gradle ]]
grep -q 'int64_t abla_app_answer(void)' "$header"
grep -q 'Java_org_abla_generated_AblaApp_answer' "$jni"
grep -q 'external fun answer(): Long' "$kotlin"
grep -q 'IMPORTED_LOCATION.*ANDROID_ABI.*libabla_app.so' "$cmake"
grep -q 'jniLibs.srcDir' "$gradle"

set +e
"$compiler" build \
    "$project_root/tests/cases/android-extension/invalid-target.ab" \
    -o "$output_directory/invalid-target" --fast --no-cache \
    >"$output_directory/invalid-target.out" \
    2>"$output_directory/invalid-target.err"
invalid_target_status=$?
set -e
[[ $invalid_target_status -ne 0 ]]
grep -q 'error\[E_BUILD_TARGET_DEFINITION\]' \
    "$output_directory/invalid-target.err"

if rg -n 'android-arm64|aarch64-linux-android' \
    "$project_root/bootstrap/compiler" >/dev/null; then
    echo "Android platform policy leaked into the compiler" >&2
    exit 1
fi

echo "Android extension: deterministic arm64 libabla_app.so + generated ABI/JNI/Kotlin/Gradle integration passed"
