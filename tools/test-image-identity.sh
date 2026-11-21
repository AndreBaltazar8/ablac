#!/usr/bin/env bash
# The compiler keys its caches on its own image (bootstrapReadRunningImageIdentity, jitCacheCompilerIdentity): not by reading and hashing all of it
# in every process (10 MB, 97 MB for the static compiler: 30 and 80 ms of each build that touches a cache), but by the linker's content hash, the ELF
# GNU build-id that a program linking LLVM gets from -Wl,--build-id=sha1 (the Mach-O LC_UUID on a Mac). This builds a program that links LLVM and prints
# its identity, and checks that (1) the id it reads is the build-id readelf shows, (2) the id follows the content (an image with one more string has another),
# (3) two different images have different ids and the same program built twice has the same one, (4) an image without the note
# falls back to the whole-image hash (non-empty size, the file's own size), and (5) both paths give a working build.
# Usage: tools/test-image-identity.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
[[ $(uname -s) == Linux ]] || { echo 'image identity: Linux only (the Mach-O LC_UUID is read by the same code)'; exit 0; }
out=build/image-identity
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/image-identity/main.ab -o "$out/one" --no-cache > "$out/one.log" 2>&1 || { cat "$out/one.log" >&2; echo 'image identity: the program failed to build' >&2; exit 1; }
"$compiler" build tests/cases/image-identity/main.ab -o "$out/again" --no-cache > "$out/again.log" 2>&1
"$compiler" build tests/cases/modules/bootstrap-cfg.ab -o "$out/other" --no-cache > "$out/other.log" 2>&1 || { cat "$out/other.log" >&2; echo 'image identity: the other program failed to build' >&2; exit 1; }
note=$(readelf -nW "$out/one" | sed -n 's/.*Build ID: *\([0-9a-f]*\).*/\1/p')
[[ -n $note ]] || { echo 'image identity: a program that links LLVM has no GNU build-id' >&2; exit 1; }
# (1) the program reads that id from its own image
"$out/one" > "$out/one.out"
[[ $(sed -n 1p "$out/one.out") == "elf-$note" ]] || { echo "image identity: read [$(sed -n 1p "$out/one.out")], readelf says [$note]" >&2; exit 1; }
# (2) the id follows the bytes: the same program with one more string in it is another image with another id
mkdir -p "$out/variant"
sed 's|println(bootstrapRunningImageLinkerId())|println(bootstrapRunningImageLinkerId())\n    println("variant")|' tests/cases/image-identity/main.ab > "$out/variant/main.ab"
"$compiler" build "$out/variant/main.ab" -o "$out/variant/prog" --no-cache > "$out/variant.log" 2>&1 || { cat "$out/variant.log" >&2; echo 'image identity: the variant failed to build' >&2; exit 1; }
variant=$(readelf -nW "$out/variant/prog" | sed -n 's/.*Build ID: *\([0-9a-f]*\).*/\1/p')
[[ -n $variant && $variant != "$note" ]] || { echo 'image identity: an image that differs by a string has the same build-id' >&2; exit 1; }
# (3) different programs, different ids; the same program twice, the same one
other=$(readelf -nW "$out/other" | sed -n 's/.*Build ID: *\([0-9a-f]*\).*/\1/p')
[[ -n $other && $other != "$note" ]] || { echo 'image identity: two different images share a build-id' >&2; exit 1; }
[[ $(readelf -nW "$out/again" | sed -n 's/.*Build ID: *\([0-9a-f]*\).*/\1/p') == "$note" ]] ||
    { echo 'image identity: the same program linked twice has two build-ids (not reproducible)' >&2; exit 1; }
# (4) without the note: the whole-image hash, over the file's own size
cp "$out/one" "$out/stripped"
objcopy --remove-section=.note.gnu.build-id "$out/stripped" 2> /dev/null || llvm-objcopy --remove-section=.note.gnu.build-id "$out/stripped"
"$out/stripped" > "$out/stripped.out"
[[ -z $(sed -n 1p "$out/stripped.out") ]] || { echo 'image identity: an image without the note still reports an id' >&2; exit 1; }
size=$(stat -c %s "$out/stripped")
[[ $(sed -n 2p "$out/stripped.out" | cut -d' ' -f1) == "$size" ]] ||
    { echo "image identity: the fallback read [$(sed -n 2p "$out/stripped.out")], the file is $size bytes" >&2; exit 1; }
# the linker-id path reports a size that is not the file's (it read none of it)
[[ $(sed -n 2p "$out/one.out" | cut -d' ' -f1) != "$(stat -c %s "$out/one")" ]] ||
    { echo 'image identity: the build-id path read the whole image' >&2; exit 1; }
echo "image identity: the linker's build-id is read, follows the content, is reproducible and distinct per image; an image without it hashes whole"
