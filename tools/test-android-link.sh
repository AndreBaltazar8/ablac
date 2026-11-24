#!/usr/bin/env bash
# Whether an android-arm64 library could load, checked without a device (#811, decision #121): the libraries the Android
# build makes import nothing at all, from bionic or elsewhere, and need no shared library (no DT_NEEDED, not even
# libc.so), the scalar one and those using thread-locals and threads alike: the five bionic functions the runtime calls
# come from the table the host installs (abla_android_host_install, which each library exports). A control library that
# imports one of them (pthread_create, which the API 24 stub defines) is rejected. This is a link check only: nothing
# here runs Android code (tools/test-android-run.sh does).
# The NDK is looked for like the compiler looks for its builtins: ABLA_ANDROID_NDK, ANDROID_NDK_ROOT,
# ANDROID_NDK_HOME, then ndk/<newest> or ndk-bundle under ANDROID_HOME and ANDROID_SDK_ROOT. Without one the
# test says so and skips (exit 0), as the other Android tests do without their tools.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
find_ndk_lib() { # a file name under the NDK roots
    local r found
    for r in "${ABLA_ANDROID_NDK:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK_HOME:-}" "${ANDROID_HOME:-}/ndk" \
        "${ANDROID_SDK_ROOT:-}/ndk" "${ANDROID_HOME:-}/ndk-bundle" "${ANDROID_SDK_ROOT:-}/ndk-bundle"; do
        if [[ -n $r && -d $r ]]; then
            found=$(find -L "$r" -path "*/aarch64-linux-android/24/$1" 2>/dev/null | sort -V | tail -n 1 || true)
            if [[ -n $found ]]; then printf '%s\n' "$found"; return; fi
        fi
    done
}
libc=$(find_ndk_lib libc.so)
if [[ -z $libc ]]; then
    if [[ ${ABLA_REQUIRE_ANDROID_TESTS:-0} == 1 ]]; then
        echo 'android link: required API 24 Android NDK sysroot missing' >&2
        exit 1
    fi
    echo 'android link: no Android NDK found (set ABLA_ANDROID_NDK); skipped'
    exit 0
fi
sysroot_libs=$(dirname "$libc")
nm=$(command -v llvm-nm || command -v nm)
nm=$(command -v llvm-nm || command -v nm)
readelf=$(command -v llvm-readelf || command -v readelf)
out=build/android-link
rm -rf "$out"
mkdir -p "$out"

undefined_symbols() {
    "$nm" -D --undefined-only "$1" | awk '{ s = $NF; sub(/@.*/, "", s); if (s != "") print s }' | sort -u
}

# No undefined dynamic symbol and no needed library.
check_no_imports() {
    local library=$1 symbols libraries
    symbols=$(undefined_symbols "$library") || return 1
    if [[ -n $symbols ]]; then
        printf 'android link: %s imports (none is allowed):\n%s\n' "$library" "$symbols" >&2
        return 1
    fi
    libraries=$("$readelf" -d "$library" | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p')
    if [[ -n $libraries ]]; then
        printf 'android link: %s needs shared libraries (none is allowed): %s\n' "$library" "$libraries" >&2
        return 1
    fi
}
# What the code generator must know of Android (#1139 area 9, the module triple): bionic before API 29 cannot load a library with native thread-locals (a PT_TLS segment), so
# they are emulated (__emutls_v.* symbols); and x18 is the platform register, which Android code must not use. A compiler whose in-process code generation read the module's
# triple "aarch64-linux-android24" un-normalized (v0.2.66 to v0.2.70) built libraries with PT_TLS and 24 uses of x18.
objdump=$(command -v llvm-objdump || true)
check_android_codegen() { # library has-thread-locals
    local library=$1 threaded=$2 uses
    if "$readelf" -lW "$library" | grep -qE '^ +TLS '; then
        echo "android link: $library has a PT_TLS segment (native thread-locals: bionic before API 29 cannot load it)" >&2
        return 1
    fi
    if [[ $threaded == 1 ]] && ! "$nm" "$library" | grep -q '__emutls_v\.'; then
        echo "android link: $library has thread-locals and no emulated TLS (__emutls_v.*)" >&2
        return 1
    fi
    if [[ -z $objdump ]]; then
        [[ ${ABLA_REQUIRE_ANDROID_TESTS:-0} != 1 ]] || { echo 'android link: llvm-objdump is required' >&2; return 1; }
        return 0
    fi
    uses=$("$objdump" -d --no-show-raw-insn "$library" | grep -cE '[[:space:],[]x18([],[:space:]]|$)' || true)
    if [[ $uses != 0 ]]; then
        echo "android link: $library uses x18, the platform register, in $uses instructions" >&2
        return 1
    fi
}
# label:build program:output directory:ABLA_DEBUG. The debug runtime is part of the set: it must not import a symbol
# either (backtrace, bionic's write), and neither may a release build.
count=0
for variant in small:small:small:0 threads:threads:threads:0 threads-debug:threads:threads:1 rich:rich:rich:0 rich-release:rich-release:rich-release:0 \
    rich-debug:rich:rich:1 rich-release-debug:rich-release:rich-release:1; do
    IFS=: read -r case program dir debug <<< "$variant"
    ABLA_DEBUG=$debug "$compiler" build "tests/cases/android-link/build-$program.ab" -o "$out/build-$case" --fast --no-cache
    status=0
    ABLA_DEBUG=$debug "$out/build-$case" || status=$?
    [[ $status -eq 37 ]] || { echo "android link: building the $case library failed ($status)" >&2; exit 1; }
    library=$out/$dir/src/main/jniLibs/arm64-v8a/libabla_app.so
    [[ -f $library ]] || { echo "android link: no $library" >&2; exit 1; }
    check_no_imports "$library" || { echo "android link: the $case library" >&2; exit 1; }
    grep -q ' T abla_android_host_install$' <<< "$("$nm" -D --defined-only "$library")" ||
        { echo "android link: the $case library does not export abla_android_host_install" >&2; exit 1; }
    check_android_codegen "$library" $([[ $case == threads* || $case == rich* ]] && echo 1 || echo 0) ||
        { echo "android link: the $case library" >&2; exit 1; }
    count=$((count + 1))
done

# A real shared object that imports pthread_create, which the API 24 stub supplies: rejected all the same.
llvm-mc -triple aarch64-linux-android -filetype=obj -o "$out/imports.o" <<'ASM'
.text
.globl abla_android_import_probe
abla_android_import_probe:
    b pthread_create
ASM
ld.lld -shared -m aarch64linux "$out/imports.o" "$libc" -o "$out/imports.so"
if check_no_imports "$out/imports.so" > "$out/imports.log" 2>&1; then
    echo 'android link: accepted the control that imports pthread_create' >&2
    exit 1
fi
grep -qx pthread_create "$out/imports.log" || { cat "$out/imports.log" >&2; exit 1; }
echo "android link: $count libraries import nothing and need no shared library; the importing control is rejected"
