#!/usr/bin/env bash
# #806 step C: what the compiler would still need from a C library once it links LLVM statically. The compiler's own
# object (src/orc_main.ab built by the given compiler; it leaves <output>.o) is linked against LLVM's static archives,
# libstdc++, libz and libgcc with NO libc, and the symbols left undefined are compared with tools/compiler-libc-needs.txt,
# one per line (204 today: the malloc family, system calls, pthread, printf, locale and math the libraries call). The list
# only shrinks as Abla's own C functions replace them (docs/toolchain.md, TODO.md "Abla without libc (#806)"): a symbol
# that is undefined and not listed fails the test (a new libc dependency), and a listed one that is defined fails it too
# (remove the line). The same set whether all of LLVM's targets are linked or only X86, AArch64 and WebAssembly.
#
# Needs LLVM's static archives, which the pinned shell's LLVM does not carry: ABLA_STATIC_LLVM_LIB names a directory with
# libLLVM*.a (and ABLA_STATIC_ZLIB one with libz.a when the C compiler finds none). Without them the test says so and
# passes (CI gets them once the LLVM release publishes them).
# Usage: tools/test-compiler-libc-needs.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'compiler libc needs: Linux only'; exit 0; }
list=tools/compiler-libc-needs.txt
[[ -f $list ]] || { echo "compiler libc needs: missing $list" >&2; exit 1; }
sort -cu "$list" || { echo "compiler libc needs: $list must be sorted and unique" >&2; exit 1; }
llvm_lib=${ABLA_STATIC_LLVM_LIB:-}
if [[ -z $llvm_lib || ! -d $llvm_lib ]] || ! compgen -G "$llvm_lib/libLLVMSupport.a" > /dev/null; then
    echo 'compiler libc needs: skipped (no static LLVM: set ABLA_STATIC_LLVM_LIB to a directory with libLLVM*.a)'
    exit 0
fi
lld=$(command -v ld.lld || true)
[[ -n $lld ]] || { echo 'compiler libc needs: ld.lld is needed' >&2; exit 1; }
cc=$(command -v gcc || command -v cc || true)
[[ -n $cc ]] || { echo 'compiler libc needs: a C compiler is needed (for libstdc++.a and libgcc.a)' >&2; exit 1; }
stdcxx=$("$cc" -print-file-name=libstdc++.a)
libgcc=$("$cc" -print-libgcc-file-name)
libgcc_eh=$(dirname "$libgcc")/libgcc_eh.a
zlib=$("$cc" -print-file-name=libz.a)
if [[ $zlib != /* && -n ${ABLA_STATIC_ZLIB:-} ]]; then zlib=$ABLA_STATIC_ZLIB/libz.a; fi
for file in "$stdcxx" "$libgcc" "$libgcc_eh" "$zlib"; do
    [[ -f $file ]] || { echo "compiler libc needs: missing $file (static libstdc++, libgcc and libz are needed)" >&2; exit 1; }
done
out=build/compiler-libc-needs
rm -rf "$out"
mkdir -p "$out"
"$compiler" build src/orc_main.ab -o "$out/compiler" --no-cache > "$out/build.log" 2>&1 ||
    { echo "compiler libc needs: the compiler's own build failed" >&2; tail -5 "$out/build.log" >&2; exit 1; }
object=$out/compiler.o
[[ -f $object ]] || { echo "compiler libc needs: the build left no $object" >&2; exit 1; }
# The targets the compiler initialises (X86, AArch64, WebAssembly) and the core: the other targets add no symbol.
archives=$(ls "$llvm_lib"/libLLVM*.a | grep -vE "libLLVM(AMDGPU|ARC|ARM|AVR|BPF|CSKY|DirectX|Hexagon|Lanai|LoongArch|M68k|MSP430|Mips|NVPTX|PowerPC|RISCV|SPIRV|Sparc|SystemZ|VE|XCore|Xtensa)[A-Za-z]*\.a")
# lld stops at 20 errors by default; --unresolved-symbols=report-all lists every undefined symbol.
"$lld" -static -o "$out/compiler-static" "$object" --start-group $archives --end-group "$stdcxx" "$zlib" "$libgcc" "$libgcc_eh" \
    --gc-sections --unresolved-symbols=report-all --error-limit=0 -e 0 > "$out/link.log" 2>&1 || true
sed -n 's/^.*undefined symbol: //p' "$out/link.log" | sort -u > "$out/actual.txt"
[[ -s $out/actual.txt ]] || { echo "compiler libc needs: the link reported no undefined symbol (an unexpected link failure?)" >&2; tail -5 "$out/link.log" >&2; exit 1; }
new=$(comm -13 "$list" "$out/actual.txt" || true)
gone=$(comm -23 "$list" "$out/actual.txt" || true)
if [[ -n $new ]]; then echo "compiler libc needs: not on $list (a new libc dependency):" >&2; echo "$new" >&2; fi
if [[ -n $gone ]]; then echo "compiler libc needs: on $list but defined now (remove the line):" >&2; echo "$gone" >&2; fi
[[ -z $new && -z $gone ]] || exit 1
echo "compiler libc needs: $(wc -l < "$list") symbols, as listed"
