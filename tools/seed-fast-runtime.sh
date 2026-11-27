#!/usr/bin/env bash
# tools/seed-fast-runtime.sh [compiler]: ships the prebuilt runtime of --fast builds into this source tree's toolchain
# (<sysroot>/fast-runtime-v1, src/toolchain.ab bootstrapFastRuntimeShip), with debug information (the default) and without,
# so that the first --fast build in a fresh cache (every test with its own ABLA_CACHE_DIR, a new CI runner) takes the object
# instead of compiling the runtime. `make ablac` runs it once per compiler; the packagers do the same for a toolchain package.
# The entries of an earlier compiler are removed: no compiler but the one that built an entry has its key.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
# The prebuilt runtime is for native x86-64 Linux programs on an x86-64 Linux host.
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || exit 0
sysroot=${ABLA_SYSROOT:-$root}
work=$(mktemp -d "${TMPDIR:-/tmp}/abla-fast-runtime-seed.XXXXXX")
trap 'rm -rf "$work"' EXIT
rm -rf "$sysroot/fast-runtime-v1"
printf 'import "abla/io"\nfun main: int { println("hello"); 0 }\n' > "$work/seed.ab"
for debug in --debug --no-debug; do
    ABLA_SYSROOT=$sysroot ABLA_CACHE_DIR="$work/cache" ABLA_SEED_FAST_RUNTIME=1 \
        "$compiler" build "$work/seed.ab" --fast "$debug" --no-cache -o "$work/seed" ||
        { echo "seed-fast-runtime: the $debug build failed" >&2; exit 1; }
done
records=("$sysroot"/fast-runtime-v1/*/record)
[[ ${#records[@]} == 2 && -s ${records[0]} && -s ${records[1]} ]] ||
    { echo "seed-fast-runtime: expected two entries in $sysroot/fast-runtime-v1" >&2; exit 1; }
