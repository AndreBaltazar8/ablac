#!/usr/bin/env bash
# The toolchain's shipped objects come only from a trusted root (bootstrapTrustedToolchainRoot, src/module_paths.ab): ABLA_SYSROOT,
# the toolchain beside the compiler's image, or the directory of a configured ABLA_STDLIB; never the working directory, which is
# where the compiler falls back to when ABLA_SYSROOT is unset. A shipped fast runtime's record is a digest anyone can compute
# (tests/cases/shipped-root/digest.ab), so a checkout could carry a ./fast-runtime-v1 entry with an edited object.
#   - the raw compiler (no launcher, so no ABLA_SYSROOT), copied where no toolchain is beside it, seeds ./fast-runtime-v1 in a
#     directory with ABLA_SYSROOT=. and ABLA_STDLIB, the object is edited ("out of memory" -> "PLANTED-OBJ!!") and its record
#     rewritten;
#   - a build there without ABLA_SYSROOT must not link it (before, it did: the program carried "PLANTED-OBJ!!");
#   - the same build with an explicit ABLA_SYSROOT=. does link it (the planted entry is valid, and an explicit root still counts).
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
echo "shipped-root: a fast runtime planted in the working directory is linked only with an explicit ABLA_SYSROOT=."
