#!/usr/bin/env bash
# The toolchain's shipped objects come only from a trusted root (bootstrapTrustedToolchainRoot, src/module_paths.ab): ABLA_SYSROOT,
# the toolchain beside the compiler's image, or the directory of a configured ABLA_STDLIB; never the working directory, which is
# where the compiler falls back to when ABLA_SYSROOT is unset. A shipped fast runtime's record is a digest anyone can compute
# (tests/cases/shipped-root/digest.ab), so a checkout could carry a ./fast-runtime-v1 entry with an edited object.
#   - the raw compiler (no launcher, so no ABLA_SYSROOT), copied where no toolchain is beside it, seeds ./fast-runtime-v1 in a
#     directory with ABLA_SYSROOT=. and ABLA_STDLIB, the object is edited ("out of memory" -> "PLANTED-OBJ!!") and its record
#     rewritten;
#   - a build there without ABLA_SYSROOT must not link it (before, it did: the program carried "PLANTED-OBJ!!");
#   - the same build with an explicit ABLA_SYSROOT=. does link it (the planted entry is valid, and an explicit root still counts);
#   - runtime/, whose package-index helper the compiler runs: with a toolchain beside the image, `package search` without
#     ABLA_SYSROOT runs that toolchain's helper, never a ./runtime/package-index-fetch.ab planted in the working directory
#     (before, it ran the planted one), and runs the planted one with ABLA_SYSROOT=.
#
#   tools/test-shipped-root.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=$root/build/shipped-root
rm -rf "$out"
mkdir -p "$out/raw" "$out/checkout"
fail() { echo "shipped-root: $1" >&2; exit 1; }
payload=${ABLA_COMPILER_PAYLOAD:-$compiler.bin}
[[ -x $payload ]] || payload=$compiler
cp "$payload" "$out/raw/ablac"
raw=$out/raw/ablac
ulimit -s 131072 2> /dev/null || true
stdlib=$root/stdlib

"$compiler" build tests/cases/shipped-root/digest.ab -o "$out/digest" --fast --no-cache > "$out/digest.log" 2>&1 ||
    fail "digest.ab did not build: $(head -4 "$out/digest.log")"
printf 'import "abla/io"\nfun main: int { println("hello"); 0 }\n' > "$out/checkout/hello.ab"

# The planted entry: seeded by the same compiler image (so its key is the one a build there looks up), then edited.
(cd "$out/checkout" && env ABLA_SYSROOT=. ABLA_STDLIB="$stdlib" ABLA_SEED_FAST_RUNTIME=1 \
    "$raw" build hello.ab --fast -o seeded --cache-dir "$out/cache-seed" > "$out/seed.log" 2>&1) ||
    fail "the seeding build failed: $(tail -4 "$out/seed.log")"
entries=("$out"/checkout/fast-runtime-v1/*/record)
[[ ${#entries[@]} == 1 && -f ${entries[0]} ]] || fail "seeding wrote no ./fast-runtime-v1 entry"
entry=$(dirname "${entries[0]}")
grep -a -F 'out of memory: the system refused' "$entry/runtime.o" > /dev/null || fail "no out-of-memory text in the seeded runtime.o"
LC_ALL=C sed -i 's/out of memory: the system refused/PLANTED-OBJ!!: the system refused/' "$entry/runtime.o"
digest=$("$out/digest" "$entry/runtime.o") || fail "digest failed on $entry/runtime.o"
sed -i "3s/.*/$digest/" "$entry/record"

# Without ABLA_SYSROOT: the working directory's entry must not be used.
(cd "$out/checkout" && env -u ABLA_SYSROOT ABLA_STDLIB="$stdlib" "$raw" build hello.ab --fast -o implicit \
    --cache-dir "$out/cache-implicit" > "$out/implicit.log" 2>&1) || fail "the build without ABLA_SYSROOT failed: $(tail -4 "$out/implicit.log")"
[[ $("$out/checkout/implicit") == hello ]] || fail "the build without ABLA_SYSROOT does not print hello"
! grep -a -F 'PLANTED-OBJ!!' "$out/checkout/implicit" > /dev/null ||
    fail "a build without ABLA_SYSROOT linked the fast runtime planted in its working directory"

# With an explicit ABLA_SYSROOT=.: the entry is the toolchain's, and is used.
(cd "$out/checkout" && env ABLA_SYSROOT=. ABLA_STDLIB="$stdlib" "$raw" build hello.ab --fast -o explicit \
    --cache-dir "$out/cache-explicit" > "$out/explicit.log" 2>&1) || fail "the build with ABLA_SYSROOT=. failed: $(tail -4 "$out/explicit.log")"
[[ $("$out/checkout/explicit") == hello ]] || fail "the build with ABLA_SYSROOT=. does not print hello"
grep -a -F 'PLANTED-OBJ!!' "$out/checkout/explicit" > /dev/null ||
    fail "the planted entry was not used even with ABLA_SYSROOT=. (the test's plant is not valid)"
# runtime/, which the compiler runs: `package search` builds and runs runtime/package-index-fetch.ab. A raw compiler with a
# toolchain beside it (a flat one: stdlib and runtime/ next to the image) runs that toolchain's helper, here a stub that
# writes a marker; a helper planted in the working directory writes a canary and must run only with ABLA_SYSROOT=.
tool=$out/tool
mkdir -p "$tool/runtime" "$out/checkout/runtime" "$out/home"
cp "$payload" "$tool/ablac"
ln -s "$stdlib" "$tool/stdlib"
helper() { # <marker file>: a package-index helper that writes the marker and answers 200 with an empty catalog
    printf 'import "abla/sys/linux/fs"\nimport "abla/sys/linux/io"\n\nfun main(): int {\n    val _written = Path("%s").writeText("ran")\n    if (linuxWriteStandardOutputAll("200\\n")) 0 else 1\n}\n' "$1"
}
helper "$out/trusted-helper-ran" > "$tool/runtime/package-index-fetch.ab"
helper "$out/planted-helper-ran" > "$out/checkout/runtime/package-index-fetch.ab"
search() { # <name> [environment...]: `package search` in the checkout with the toolchain-beside-the-image compiler
    local name=$1
    shift
    (cd "$out/checkout" && env -u ABLA_SYSROOT HOME="$out/home" XDG_CACHE_HOME= ABLA_PACKAGE_CACHE="$out/package-$name" \
        ABLA_PACKAGE_INDEX_URL= ABLA_STDLIB="$stdlib" "$@" "$tool/ablac" package search anything > "$out/search-$name.log" 2>&1) || true
}
search implicit
[[ ! -e $out/planted-helper-ran ]] || fail "package search without ABLA_SYSROOT ran the runtime/ helper planted in its working directory"
[[ -e $out/trusted-helper-ran ]] || fail "package search without ABLA_SYSROOT did not run its own toolchain's helper: $(tail -4 "$out/search-implicit.log")"
search explicit ABLA_SYSROOT=.
[[ -e $out/planted-helper-ran ]] ||
    fail "package search with ABLA_SYSROOT=. did not run ./runtime's helper (the test's plant is not valid): $(tail -4 "$out/search-explicit.log")"
echo "shipped-root: a fast runtime or runtime/ helper planted in the working directory is used only with an explicit ABLA_SYSROOT=."
