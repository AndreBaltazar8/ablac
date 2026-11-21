#!/usr/bin/env bash
# The pruning of the runtime modules' undemanded functions (src/runtime_prune.ab): a build with the hint an earlier build of the same program left in the build
# cache (ABLA_PRUNE_RUNTIME=1) is byte for byte the unpruned build, for a slice of the suite built every way the pruning can see (--fast, release, a cross
# target) and for a program that turns background freeing on (a by-name hook the pruning has to keep working); a hint that is wrong, missing something the
# program demands or holding something it does not, is detected by the lowering and the build is made again without it, with the same bytes; --no-cache never
# prunes; a hint file that is not one is ignored.
# Usage: tools/test-runtime-prune.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'runtime prune: Linux only'; exit 0; }
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS ABLA_PRUNE_RUNTIME ABLA_PRUNE_RUNTIME_HINT ABLA_CACHE_DIR
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root}
out=build/runtime-prune
rm -rf "$out"
mkdir -p "$out"
fail() { echo "runtime prune: $*" >&2; exit 1; }
programs=(tests/cases/libc-imports/hello.ab tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab
    tests/cases/libc-imports/tasks.ab tests/cases/libc-imports/threads.ab tests/cases/libc-imports/float-remainder.ab
    tests/cases/modules/http-event.ab tests/cases/modules/linux-net.ab tests/cases/gc-background-free/background.ab
    tests/cases/stm/basic.ab tests/cases/json-encode/main.ab tests/cases/generator-step/counter.ab)
# Name, then the flags: the pruning is on the front end, so each flag set is a different front end (target, optimisation profile).
variants=("fast:--fast" "release:" "aarch64:--fast --target aarch64-linux")
count=0
for program in "${programs[@]}"; do
    name=$(basename -- "$program" .ab)
    for variant in "${variants[@]}"; do
        tag=${variant%%:*}
        read -r -a flags <<< "${variant#*:}"
        base="$out/$name.$tag"
        cache="$base.cache"
        # the first build leaves the hint (the cache is the build's own), the second is another program text (an appended comment: positions before it do not
        # move) so the object cache misses and the compile runs, pruned by the hint
        mkdir -p "$base.dir"
        cp -r "$(dirname -- "$program")/." "$base.dir/"
        entry=$base.dir/$(basename -- "$program")
        ABLA_PRUNE_RUNTIME=1 ABLA_CACHE_DIR=$PWD/$cache ABLA_SYSROOT=$root "$compiler" build "$entry" -o "$base.first" "${flags[@]}" > "$base.first.log" 2>&1 ||
            { tail -5 "$base.first.log" >&2; fail "$name ($tag): the first build failed"; }
        printf '\n// a second text of the same program\n' >> "$entry"
        ABLA_PRUNE_RUNTIME=1 ABLA_CACHE_DIR=$PWD/$cache ABLA_COMPILER_DEMAND_TRACE=1 "$compiler" build "$entry" -o "$base.pruned" "${flags[@]}" \
            > "$base.pruned.log" 2> "$base.pruned.trace" || { grep -v '^abla-' "$base.pruned.trace" | tail -5 >&2; fail "$name ($tag): the pruned build failed"; }
        # the unpruned reference is built the same way, with a cache of its own and without the pruning (a build with the cache cuts the code into units
        # on some targets, so its bytes are not those of a --no-cache build)
        ABLA_CACHE_DIR=$PWD/$base.plaincache "$compiler" build "$entry" -o "$base.plain" "${flags[@]}" > "$base.plain.log" 2>&1 || fail "$name ($tag): the plain build failed"
        grep -q '^abla-prune-runtime [0-9]* of' "$base.pruned.trace" || fail "$name ($tag): the second build did not prune"
        ! grep -q '^abla-prune-runtime fallback' "$base.pruned.trace" || fail "$name ($tag): the lowering did not demand what the hint said"
        cmp -s "$base.plain" "$base.pruned" || fail "$name ($tag): the pruned executable differs from the unpruned one"
        count=$((count + 1))
    done
done
# A wrong hint is found by the build it prunes. The hints here come from builds made with the trace, as the cache's do.
hint() { # program -> a hint file of its demand
    local program=$1 trace=$out/hint-$(basename -- "$1" .ab).trace file=$out/hint-$(basename -- "$1" .ab).txt
    ABLA_COMPILER_DEMAND_TRACE=1 "$compiler" build "$program" -o "$out/hint.bin" --no-cache --fast > /dev/null 2> "$trace" || fail "$program did not build for its hint"
    { echo abla-runtime-demand-1; awk '$1 == "abla-demanded" && $3 == "fun" { n = $4; sub(/^\./, "", n); print n }' "$trace" | sort -u; } > "$file"
    echo "$file"
}
small=$(hint tests/cases/libc-imports/hello.ab)
large=$(hint tests/cases/modules/http-event.ab)
# the union: names the small program does not demand
{ echo abla-runtime-demand-1; { tail -n +2 "$small"; tail -n +2 "$large"; } | sort -u; } > "$out/hint-union.txt"
wrong=0
for case in "missing:$small:tests/cases/modules/http-event.ab" "extra:$out/hint-union.txt:tests/cases/libc-imports/hello.ab" "background:$small:tests/cases/gc-background-free/background.ab"; do
    IFS=: read -r kind hintfile program <<< "$case"
    name=$(basename -- "$program" .ab)
    "$compiler" build "$program" -o "$out/wrong-$kind.plain" --no-cache --fast > /dev/null 2>&1 || fail "$name did not build"
    ABLA_PRUNE_RUNTIME_HINT=$PWD/$hintfile ABLA_COMPILER_DEMAND_TRACE=1 "$compiler" build "$program" -o "$out/wrong-$kind.bin" --no-cache --fast \
        > "$out/wrong-$kind.log" 2> "$out/wrong-$kind.trace" || { grep -v '^abla-' "$out/wrong-$kind.trace" | tail -5 >&2; fail "$kind hint: the build failed"; }
    grep -q '^abla-prune-runtime [0-9]* of' "$out/wrong-$kind.trace" || fail "$kind hint: nothing was pruned (the test does not test)"
    grep -q '^abla-prune-runtime fallback' "$out/wrong-$kind.trace" || fail "$kind hint: it was not found wrong"
    cmp -s "$out/wrong-$kind.plain" "$out/wrong-$kind.bin" || fail "$kind hint: the fallback build differs from the unpruned one"
    wrong=$((wrong + 1))
done
# --no-cache never prunes (the hint of the cache is not read), and a file that is not a hint is ignored.
ABLA_PRUNE_RUNTIME=1 ABLA_CACHE_DIR=$PWD/$out/nocache.cache ABLA_COMPILER_DEMAND_TRACE=1 "$compiler" build tests/cases/libc-imports/hello.ab -o "$out/nocache.bin" --fast > /dev/null 2> /dev/null || fail "hello did not build"
{ cat tests/cases/libc-imports/hello.ab; printf '\n// changed\n'; } > "$out/nocache.ab"
ABLA_PRUNE_RUNTIME=1 ABLA_CACHE_DIR=$PWD/$out/nocache.cache ABLA_COMPILER_DEMAND_TRACE=1 "$compiler" build "$out/nocache.ab" -o "$out/nocache.bin" --fast --no-cache > /dev/null 2> "$out/nocache.trace" || fail "hello did not build with --no-cache"
! grep -q '^abla-prune-runtime' "$out/nocache.trace" || fail "--no-cache pruned"
printf 'not a hint\n' > "$out/garbage.txt"
ABLA_PRUNE_RUNTIME_HINT=$PWD/$out/garbage.txt ABLA_COMPILER_DEMAND_TRACE=1 "$compiler" build tests/cases/libc-imports/hello.ab -o "$out/garbage.bin" --no-cache --fast > /dev/null 2> "$out/garbage.trace" || fail "hello did not build with a garbage hint"
! grep -q '^abla-prune-runtime' "$out/garbage.trace" || fail "a file that is not a hint pruned"
echo "runtime prune: $count builds (${#programs[@]} programs x ${#variants[@]} ways) pruned by the cache's hint, byte for byte the unpruned ones; $wrong wrong hints (missing, extra, background freeing) found and rebuilt with the same bytes; --no-cache and a garbage hint prune nothing"
