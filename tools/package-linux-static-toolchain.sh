#!/usr/bin/env bash
# The static toolchain package (#806, #92): abla-toolchain-static-x86_64-linux, beside today's abla-toolchain-x86_64-linux (tools/package-linux-toolchain.sh), which stays as it is.
# libexec/ablac.bin is the statically linked compiler with lld in its own process (tools/build-static-compiler.sh with ABLA_STATIC_LLD_LIB), so the package has no libLLVM.so,
# no clang, no ld.lld, no wasm-ld, no patchelf'd loader or libraries: the compiler, compiler-rt's builtins archive (the only runtime a libc-free program links), the standard
# library and runtime, the licences and the Xtensa installer (a libc-free static program the packaged compiler builds). It builds and links the hosted x86-64 Linux programs that bring no C library (the default) from this alone; what still
# needs an external tool (cross targets through opt/llc/llvm-extract, WebAssembly, a program that needs a C library) says which on the PATH it wants.
#
#   tools/package-linux-static-toolchain.sh <ablac-static> <abla-root> <output.tar.gz> [--compare <dynamic-package.tar.gz>]
#
# The builtins archive is ABLA_COMPILER_RT_BUILTINS, else the one of the PATH's clang (a packaging-time use only). Prints the package's size (unpacked and compressed), and
# next to the dynamic package's when --compare names it.
set -euo pipefail

compare=
args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --compare) compare=${2:?--compare needs a package}; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
if [[ ${#args[@]} -ne 3 ]]; then
    printf "usage: %s <ablac-static> <abla-root> <output.tar.gz> [--compare <package>]\n" "$0" >&2
    exit 2
fi
compiler_binary=$(realpath "${args[0]}")
abla_root=$(realpath "${args[1]}")
output=$(realpath -m "${args[2]}")

[[ -x $compiler_binary ]] || { printf 'missing compiler executable: %s\n' "$compiler_binary" >&2; exit 1; }
for directory in "$abla_root/runtime" "$abla_root/stdlib"; do
    [[ -d $directory ]] || { printf 'missing Abla sysroot directory: %s\n' "$directory" >&2; exit 1; }
done
# A dynamic or interpreted executable here would be today's package under another name.
if readelf -lW "$compiler_binary" 2> /dev/null | grep 'INTERP\|Shared library' > /dev/null; then
    printf '%s is not statically linked (it names a loader or a shared library)\n' "$compiler_binary" >&2
    exit 1
fi
builtins=${ABLA_COMPILER_RT_BUILTINS:-}
if [[ -z $builtins ]]; then
    builtins=$(clang --rtlib=compiler-rt -print-libgcc-file-name 2> /dev/null || true)
fi
[[ -f $builtins && $builtins == *builtins-x86_64.a ]] || {
    printf 'no compiler-rt builtins archive for x86-64 (set ABLA_COMPILER_RT_BUILTINS): %s\n' "$builtins" >&2
    exit 1
}

working=$(mktemp -d)
cleanup() {
    local status=$?
    trap - EXIT
    if ! chmod -R u+w -- "$working" || ! rm -rf -- "$working"; then
        printf 'failed to clean temporary packaging directory: %s\n' "$working" >&2
        if [[ $status -eq 0 ]]; then status=1; fi
    fi
    return "$status"
}
trap cleanup EXIT
# The directory inside the archive: ABLA_PACKAGE_NAME (the default name of the static package; the release that makes it the default asset sets abla-toolchain-x86_64-linux).
name=${ABLA_PACKAGE_NAME:-abla-toolchain-static-x86_64-linux}
bundle="$working/$name"
mkdir -p "$bundle/bin" "$bundle/libexec" "$bundle/share/abla" "$bundle/share/licenses" "$bundle/lib/clang/23/lib/linux"

cp "$compiler_binary" "$bundle/libexec/ablac.bin"
chmod 0755 "$bundle/libexec/ablac.bin"
cp "$builtins" "$bundle/lib/clang/23/lib/linux/libclang_rt.builtins-x86_64.a"
cp -R "$abla_root/runtime" "$abla_root/stdlib" "$bundle/share/abla/"
cp "$abla_root/LICENSE" "$bundle/share/licenses/abla.txt"

# The launcher needs no other program (it runs with an empty PATH): the shell's own commands, and `readlink` only when it was started through a symbolic link.
cat > "$bundle/bin/ablac" <<'SH'
#!/bin/sh
set -eu
launcher=$0
while [ -L "$launcher" ]; do
    target=$(readlink "$launcher")
    case $target in
        /*) launcher=$target ;;
        *) launcher=${launcher%/*}/$target ;;
    esac
done
case $launcher in
    */*) here=${launcher%/*} ;;
    *) here=. ;;
esac
root=$(CDPATH= cd -- "$here/.." && pwd)
# Deeply nested programs need more than the default stack: up to 128 MiB, within the hard limit. ABLA_MAX_STACK_KB chooses another size.
stack_kb=${ABLA_MAX_STACK_KB:-131072}
hard_stack_kb=$(ulimit -H -s)
case $hard_stack_kb in
    ''|*[!0-9]*) ;;
    *) if [ "$hard_stack_kb" -lt "$stack_kb" ]; then stack_kb=$hard_stack_kb; fi ;;
esac
ulimit -S -s "$stack_kb" 2>/dev/null || :
export ABLA_SYSROOT="$root/share/abla"
export PATH="$root/bin:${PATH-}"
exec "$root/libexec/ablac.bin" "$@"
SH
chmod 0755 "$bundle/bin/ablac"

cat > "$bundle/share/licenses/NOTICE-static.txt" <<'EOF'
libexec/ablac.bin is one statically linked executable. Besides Abla's own code (share/licenses/abla.txt) it contains:
  LLVM and lld          Apache License 2.0 with LLVM Exceptions (https://llvm.org/LICENSE.txt)
  compiler-rt builtins  Apache License 2.0 with LLVM Exceptions (lib/clang/*/lib/linux/libclang_rt.builtins-x86_64.a, linked into the programs it builds)
  libstdc++ and libgcc  GNU GPL version 3 with the GCC Runtime Library Exception (https://www.gnu.org/licenses/gcc-exception-3.1.html)
  zlib                  zlib License (https://zlib.net/zlib_license.html)
Abla's own C library (src/static_libc) replaces the system's: nothing of glibc or musl is in it.
EOF

# The Xtensa installer is built by the packaged compiler itself, on an empty PATH (a libc-free static program: no shared library), as a release build (-O2): its
# code generation runs in the compiler's process (abla_emit_object), so there is no opt or llc to carry.
mkdir -p "$working/native-build"
env -i PATH="$working/native-build" ABLA_CACHE_DIR="$working/cache" HOME="$working" "$bundle/bin/ablac" build "$abla_root/tools/xtensa-native/main.ab" --no-cache \
    -o "$working/native-build/installer"
cp "$working/native-build/installer" "$bundle/libexec/abla-install-xtensa-native"
chmod 0755 "$bundle/libexec/abla-install-xtensa-native"
"$(dirname -- "${BASH_SOURCE[0]}")/package-xtensa-installer.sh" "$bundle"
ln -s ../libexec/abla-install-xtensa-native "$bundle/bin/abla-install-xtensa"

mkdir -p "$(dirname "$output")"
"$bundle/bin/ablac" --seed-stdlib-discovery
cat > "$working/native-build/collector-seed.ab" <<'AB'
import "abla/io"
fun main: int { println("hello"); 0 }
AB
env -i PATH="$working/native-build" HOME="$working" ABLA_SEED_RELEASE_COLLECTOR=1 \
    "$bundle/bin/ablac" build "$working/native-build/collector-seed.ab" --no-cache -o "$working/native-build/collector-seed"
[[ -s $bundle/share/abla/release-collector-v1/record ]]
# The prebuilt runtime of --fast builds (src/toolchain.ab, bootstrapFastRuntimeShip), with debug information (the default) and
# without: the object a first --fast build in a fresh cache would otherwise compile, in share/abla/fast-runtime-v1.
for debug in --debug --no-debug; do
    env -i PATH="$working/native-build" HOME="$working" ABLA_CACHE_DIR="$working/fast-runtime-cache" ABLA_SEED_FAST_RUNTIME=1 \
        "$bundle/bin/ablac" build "$working/native-build/collector-seed.ab" --fast "$debug" --no-cache -o "$working/native-build/fast-seed"
done
shipped_runtimes=("$bundle"/share/abla/fast-runtime-v1/*/record)
[[ ${#shipped_runtimes[@]} == 2 && -s ${shipped_runtimes[0]} && -s ${shipped_runtimes[1]} ]]

tar -C "$working" -czf "$output" "$name"
(
    cd "$(dirname "$output")"
    sha256sum "$(basename "$output")" > "$(basename "$output").sha256"
)
unpacked=$(du -sm "$bundle" | cut -f1)
packed=$(du -m "$output" | cut -f1)
report="static package: $unpacked MB unpacked, $packed MB as tar.gz"
if [[ -n $compare && -f $compare ]]; then
    report="$report (the dynamic package: $(du -m "$compare" | cut -f1) MB as tar.gz)"
fi
echo "$report"
