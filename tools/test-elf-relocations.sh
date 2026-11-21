#!/usr/bin/env bash
# #806: the libc-free links check their image's relocations in-process (src/elf_relocations.ab) where they ran llvm-readelf. This checks the reader against
# that tool on real files: an executable the compiler links for x86-64 and one for AArch64 have only relative relocations (nothing to report), an object
# file has others, and the first one the reader names (type and offset) is the first non-relative line of `llvm-readelf -rW`; a file that is not an ELF
# is "?" (the caller then asks llvm-readelf). Linux only.
# Usage: tools/test-elf-relocations.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'elf relocations: Linux only'; exit 0; }
out=build/elf-relocations
rm -rf "$out"
mkdir -p "$out"
fail() { echo "elf relocations: $*" >&2; exit 1; }
"$compiler" build tests/cases/elf-relocations/main.ab -o "$out/reader" --no-cache > "$out/reader.log" 2>&1 || { tail -5 "$out/reader.log" >&2; fail "the reader did not build"; }
source=tests/cases/libc-imports/hello.ab
"$compiler" build "$source" -o "$out/hello.x86" --fast --no-cache > "$out/hello.x86.log" 2>&1 || fail "hello did not build for x86-64"
"$compiler" build "$source" -o "$out/hello.a64" --fast --no-cache --target aarch64-linux > "$out/hello.a64.log" 2>&1 || fail "hello did not build for aarch64-linux"
"$compiler" build "$source" -o "$out/hello.x86.o" --emit object --fast --no-cache > "$out/hello.o.log" 2>&1 || fail "hello did not build as an object"
"$compiler" build "$source" -o "$out/hello.a64.o" --emit object --fast --no-cache --target aarch64-linux > "$out/hello.a64.o.log" 2>&1 || fail "hello did not build as an AArch64 object"
read_relocations() { "$out/reader" "$1" "$2"; }
# 1. the linked images: nothing but relative relocations (a hello has none at all: its code is position-independent without any)
[[ $(read_relocations "$out/hello.x86" 8) == "" ]] || fail "hello.x86 has a relocation that is not R_X86_64_RELATIVE: $(read_relocations "$out/hello.x86" 8)"
[[ $(read_relocations "$out/hello.a64" 1027) == "" ]] || fail "hello.a64 has a relocation that is not R_AARCH64_RELATIVE: $(read_relocations "$out/hello.a64" 1027)"
# ... and a hand-made static-pie with relative relocations only (a data pointer): nothing to report, and with another relative type given the first entry
# (a type-8 one) is the one reported, so the reader does look at the entries; its AArch64 twin likewise
printf 'int x;\nint *p = &x;\nvoid _start(void) {}\n' > "$out/tiny.c"
clang -nostdlib -static-pie -fPIE -Wl,-e,_start -o "$out/tiny.x86" "$out/tiny.c" || fail "clang could not link the x86-64 control"
clang --target=aarch64-unknown-linux-gnu -nostdlib -static-pie -fPIE -fuse-ld=lld -Wl,-e,_start -o "$out/tiny.a64" "$out/tiny.c" || fail "clang could not link the AArch64 control"
llvm-readelf -rW "$out/tiny.x86" > "$out/tiny.readelf"
[[ $(grep -c R_X86_64_RELATIVE "$out/tiny.readelf") -gt 0 ]] || fail "the x86-64 control has no relative relocation"
[[ $(read_relocations "$out/tiny.x86" 8) == "" ]] || fail "the x86-64 control reads as [$(read_relocations "$out/tiny.x86" 8)]"
[[ $(read_relocations "$out/tiny.x86" 9) == "relocation type 8 at offset "* ]] || fail "the x86-64 control with type 9: [$(read_relocations "$out/tiny.x86" 9)]"
[[ $(read_relocations "$out/tiny.a64" 1027) == "" ]] || fail "the AArch64 control reads as [$(read_relocations "$out/tiny.a64" 1027)]"
[[ $(read_relocations "$out/tiny.a64" 8) == "relocation type 1027 at offset "* ]] || fail "the AArch64 control with type 8: [$(read_relocations "$out/tiny.a64" 8)]"
# a dynamically linked program has GLOB_DAT entries among its relative ones: the first non-relative one, as llvm-readelf's order has it
"$compiler" build tests/cases/modules/bootstrap-cfg.ab -o "$out/hosted" --fast --no-cache > "$out/hosted.log" 2>&1 || fail "bootstrap-cfg did not build"
llvm-readelf -rW "$out/hosted" > "$out/hosted.readelf"
first=$(awk '$3 ~ /^R_X86_64_/ && $3 !~ /RELATIVE$/ { print $1, $3; exit }' "$out/hosted.readelf")
if [[ -n $first ]]; then
    [[ $(read_relocations "$out/hosted" 8) == "${first##* } at offset $((16#${first%% *}))" ]] ||
        fail "the hosted program: the reader says [$(read_relocations "$out/hosted" 8)], llvm-readelf's first is [$first]"
fi
# 2. the objects: the first relocation that is not relative, as llvm-readelf names it
for case in "x86 8 R_X86_64_" "a64 1027 R_AARCH64_"; do
    read -r tag relative prefix <<< "$case"
    object=$out/hello.$([[ $tag == x86 ]] && echo x86 || echo a64).o
    mine=$(read_relocations "$object" "$relative")
    [[ -n $mine && $mine != '?' ]] || fail "the $tag object reads as [$mine]"
    # the first relocation line that is not RELATIVE: "offset info type ..."
    llvm-readelf -rW "$object" > "$object.readelf"
    expected=$(awk -v prefix="$prefix" '$3 ~ "^" prefix && $3 !~ "RELATIVE$" { print $1, $3; exit }' "$object.readelf")
    [[ -n $expected ]] || fail "llvm-readelf lists no relocation of the $tag object"
    offset=$((16#${expected%% *}))
    name=${expected##* }
    [[ $mine == *" at offset $offset" ]] || fail "the $tag object: the reader says [$mine], llvm-readelf's first is [$expected] (offset $offset)"
    case $mine in
        "relocation type "*) ;;
        *) [[ $mine == "$name at offset $offset" ]] || fail "the $tag object: the reader names [$mine], llvm-readelf [$name]" ;;
    esac
done
# 3. not an ELF, and a truncated one
echo 'not an elf file' > "$out/text"
[[ $(read_relocations "$out/text" 8) == '?' ]] || fail "a text file is not '?'"
head -c 100 "$out/hello.x86" > "$out/truncated"
[[ $(read_relocations "$out/truncated" 8) == '?' ]] || fail "a truncated ELF is not '?'"
[[ $(read_relocations "$out/missing" 8) == '?' ]] || fail "a missing file is not '?'"
echo "elf relocations: the in-process reader agrees with llvm-readelf on x86-64 and AArch64 images and objects, and says ? for what it cannot read"
