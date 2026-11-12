#!/usr/bin/env bash
# Whether an android-arm64 library could load, checked without a device (#811): every symbol it leaves
# undefined must be defined by the library itself or exported by bionic's API 24 libc, libm, libdl or liblog
# (the NDK's sysroot stubs), and the set of those imports may only shrink (tools/android-imports-allowlist.txt,
# "<case> <symbol>"). This is a link check only: nothing here runs Android code.
# The NDK is looked for like the compiler looks for its builtins: ABLA_ANDROID_NDK, ANDROID_NDK_ROOT,
# ANDROID_NDK_HOME, then ndk/<newest> or ndk-bundle under ANDROID_HOME and ANDROID_SDK_ROOT. Without one the
# test says so and skips (exit 0), as the other Android tests do without their tools.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
find_ndk_lib() { # a file name under the NDK roots
    local r
    for r in "${ABLA_ANDROID_NDK:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK_HOME:-}" "${ANDROID_HOME:-}/ndk" \
        "${ANDROID_SDK_ROOT:-}/ndk" "${ANDROID_HOME:-}/ndk-bundle" "${ANDROID_SDK_ROOT:-}/ndk-bundle"; do
        if [[ -n $r && -d $r ]]; then find -L "$r" -path "*/aarch64-linux-android/24/$1" 2>/dev/null; fi
    done | sort -V | tail -n 1 || true
}
libc=$(find_ndk_lib libc.so)
if [[ -z $libc ]]; then
    echo 'android link: no Android NDK found (set ABLA_ANDROID_NDK); skipped'
    exit 0
fi
sysroot_libs=$(dirname "$libc")
nm=$(command -v llvm-nm || command -v nm)
out=build/android-link
rm -rf "$out"
mkdir -p "$out"
exports=$out/bionic-exports.txt
for lib in libc libm libdl liblog; do
    [[ -f $sysroot_libs/$lib.so ]] && "$nm" -D --defined-only "$sysroot_libs/$lib.so" | awk '{ s = $NF; sub(/@.*/, "", s); print s }'
done | sort -u > "$exports"
allow=tools/android-imports-allowlist.txt
actual=$out/actual.txt
: > "$actual"
for case in small rich; do
    "$compiler" build "tests/cases/android-link/build-$case.ab" -o "$out/build-$case" --fast --no-cache
    status=0
    "$out/build-$case" || status=$?
    [[ $status -eq 37 ]] || { echo "android link: building the $case library failed ($status)" >&2; exit 1; }
    library=$out/$case/src/main/jniLibs/arm64-v8a/libabla_app.so
    [[ -f $library ]] || { echo "android link: no $library" >&2; exit 1; }
    "$nm" -D --undefined-only "$library" | awk -v c="$case" '{ s = $NF; sub(/@.*/, "", s); if (s != "") print c " " s }' | sort -u >> "$actual"
done
sort -u -o "$actual" "$actual"
unresolved=$(awk '{ print $2 }' "$actual" | sort -u | comm -23 - "$exports")
if [[ -n $unresolved ]]; then
    printf 'android link: undefined symbols that neither the library nor bionic (API 24) defines, so dlopen would fail:\n%s\n' "$unresolved" >&2
    exit 1
fi
sort -c "$allow" || { echo "android link: $allow must be sorted" >&2; exit 1; }
unexpected=$(comm -23 "$actual" "$allow")
if [[ -n $unexpected ]]; then
    printf 'android link: new imports are not allowed (#811):\n%s\n' "$unexpected" >&2
    exit 1
fi
gone=$(comm -13 "$actual" "$allow")
[[ -z $gone ]] || printf 'android link: no longer imported, remove from %s:\n%s\n' "$allow" "$gone"
echo "android link: $(wc -l < "$actual") imports, all exported by bionic API 24 and within the allowed list"
