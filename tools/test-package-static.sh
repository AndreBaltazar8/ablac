#!/usr/bin/env bash
# The static toolchain package (tools/package-linux-static-toolchain.sh): built from the static compiler, unpacked in a directory of its own, and used with an EMPTY PATH (no clang, no
# ld.lld, no coreutils: not even `ls`): hello builds, links in the compiler's process and runs, built a second time it is the same executable, and the package holds no loader,
# no shared library and no libLLVM. Prints the package's size. Needs the static compiler (tools/build-static-compiler.sh after eval "$(tools/static-llvm-env.sh)").
# The Xtensa installer and a Windows executable also build with the packaged compiler on an empty PATH.
# Usage: tools/test-package-static.sh <static compiler> [dynamic-package.tar.gz to compare sizes with]
set -euo pipefail
export LC_ALL=C
compiler=${1:?usage: tools/test-package-static.sh <static compiler> [dynamic package]}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
compare=${2:-}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'static package: x86-64 Linux only'; exit 0; }
out=build/package-static
rm -rf "$out"
mkdir -p "$out/unpacked" "$out/empty"
fail() { echo "static package: $*" >&2; exit 1; }
args=("$compiler" "$root" "$out/package.tar.gz")
[[ -z $compare ]] || args+=(--compare "$compare")
report=$(tools/package-linux-static-toolchain.sh "${args[@]}" 2> "$out/package.log") || { tail -5 "$out/package.log" >&2; fail "the package did not build"; }
tar -C "$out/unpacked" -xzf "$out/package.tar.gz"
pkg=$out/unpacked/${ABLA_PACKAGE_NAME:-abla-toolchain-static-x86_64-linux}
for part in bin/ablac libexec/ablac.bin libexec/abla-install-xtensa-native share/abla/stdlib share/abla/stdlib-discovery-v1 share/abla/release-collector-v1/record share/abla/fast-runtime-v1 share/abla/runtime lib/clang/23/lib/linux/libclang_rt.builtins-x86_64.a share/licenses/abla.txt; do
    [[ -e $pkg/$part ]] || fail "the package lacks $part"
done
# no shared library, no libLLVM, no tool of an LLVM install
found=$(find "$pkg" -type f \( -name '*.so' -o -name '*.so.*' -o -name 'libLLVM*' -o -name 'libclang-cpp*' -o -name clang -o -name ld.lld -o -name wasm-ld -o -name lld-link -o -name opt -o -name llc \) -print)
[[ -z $found ]] || fail "the package holds: $found"
for executable in "$pkg/libexec/ablac.bin" "$pkg/libexec/abla-install-xtensa-native"; do
    interpreter=$(readelf -lW "$executable" | grep -c 'INTERP\|Shared library' || true)
    [[ $interpreter == 0 ]] || fail "$executable is not static"
done
# an empty PATH: the launcher and the compiler run on their own
hello() { # output name, cache name
    env -i PATH="$PWD/$out/empty" HOME="$PWD/$out" ABLA_CACHE_DIR="$PWD/$out/$2" ABLA_COMPILER_MEMORY_TRACE=1 "$PWD/$pkg/bin/ablac" build tests/cases/libc-imports/hello.ab -o "$out/$1" \
        > "$out/$1.log" 2>&1 || { tail -5 "$out/$1.log" >&2; fail "hello did not build with an empty PATH"; }
}
env -i PATH="$PWD/$out/empty" "$PWD/$pkg/bin/ablac" --version > "$out/version.txt" 2>&1 || fail "ablac --version failed with an empty PATH"
grep "^ablac " "$out/version.txt" > /dev/null || fail "ablac --version printed: $(cat "$out/version.txt")"
hello hello1 cache1
grep -Fq 'discovery.shipped-hit:' "$out/hello1.log" || fail 'hello did not use the packaged stdlib records'
grep -Fq "release-collector.hit" "$out/hello1.log" || fail "hello did not use the packaged collector"
[[ $("$out/hello1") == hello ]] || fail "hello did not print hello"
hello hello2 cache2
cmp -s "$out/hello1" "$out/hello2" || fail "two builds of hello differ"
hello hello-hit cache1
cmp "$out/hello1" "$out/hello-hit"
grep -Fq "release-collector.hit" "$out/hello-hit.log" || fail "cached hello did not use the packaged collector"
# The object is tied to the stdlib contents, including edits that preserve file metadata.
collector_source="$pkg/share/abla/stdlib/abla/runtime/platform/host.ab"
cp -p "$collector_source" "$out/host.original.ab"
sed "s/__ablaRuntimeHostGcWorkersSet(4)/__ablaRuntimeHostGcWorkersSet(3)/" "$out/host.original.ab" > "$collector_source"
touch -r "$out/host.original.ab" "$collector_source"
! cmp -s "$out/host.original.ab" "$collector_source" || fail "collector fixture was not edited"
hello hello-edit cache-edit
if grep -Fq "release-collector.hit" "$out/hello-edit.log"; then fail "edited collector used the packaged object"; fi
[[ $("$out/hello-edit") == hello ]] || fail "edited collector did not build a working hello"
cp -p "$out/host.original.ab" "$collector_source"
# The prebuilt --fast runtime: a fresh cache takes the package's object (both debug settings) and compiles no runtime; an edited
# runtime source is another key, which the package does not have, so that build compiles its own.
fast_hello() { # output name, cache name, debug flag
    env -i PATH="$PWD/$out/empty" HOME="$PWD/$out" ABLA_CACHE_DIR="$PWD/$out/$2" ABLA_COMPILER_MEMORY_TRACE=1 "$PWD/$pkg/bin/ablac" build tests/cases/libc-imports/hello.ab \
        --fast "$3" -o "$out/$1" > "$out/$1.log" 2>&1 || { tail -5 "$out/$1.log" >&2; fail "hello --fast $3 did not build with an empty PATH"; }
    [[ $("$out/$1") == hello ]] || fail "hello --fast $3 did not print hello"
}
for debug in --debug --no-debug; do
    fast_hello "fast$debug" "cache-fast$debug" "$debug"
    grep -Fq 'fast-runtime.shipped' "$out/fast$debug.log" || fail "hello --fast $debug did not take the packaged runtime"
    if grep -Fq 'fast-runtime.compile' "$out/fast$debug.log"; then fail "hello --fast $debug compiled the runtime"; fi
done
sed "s/__ablaRuntimeHostGcWorkersSet(4)/__ablaRuntimeHostGcWorkersSet(3)/" "$out/host.original.ab" > "$collector_source"
fast_hello fast-edit cache-fast-edit --debug
grep -Fq 'fast-runtime.compile' "$out/fast-edit.log" || fail "an edited runtime used the packaged --fast runtime"
cp -p "$out/host.original.ab" "$collector_source"
# a program with a compile-time action and a second module build too (the standard library is the package's own)
env -i PATH="$PWD/$out/empty" HOME="$PWD/$out" ABLA_CACHE_DIR="$PWD/$out/cache3" "$PWD/$pkg/bin/ablac" run tests/cases/libc-imports/strings-arrays.ab > "$out/run.log" 2>&1 ||
    { tail -5 "$out/run.log" >&2; fail "a run with an empty PATH failed"; }
windows() {
    local output=$1
    shift
    env -i PATH="$PWD/$out/empty" HOME="$PWD/$out" ABLA_CACHE_DIR="$PWD/$out/cache-windows" "$@" \
        "$PWD/$pkg/bin/ablac" build tests/cases/windows/exit7.ab --target x86_64-windows-freestanding --no-cache \
        -o "$out/$output.exe" > "$out/$output.log" 2>&1
}
windows windows || { tail -5 "$out/windows.log" >&2; fail 'Windows link on an empty PATH failed'; }
[[ -s $out/windows.exe ]] || fail 'Windows build produced no executable'
if windows windows-external ABLA_LINK_INPROCESS=0; then
    fail 'Windows link succeeded with the embedded linker disabled and an empty PATH'
fi
echo "$report; hello builds, runs and is reproducible, and Windows links with an empty PATH"
