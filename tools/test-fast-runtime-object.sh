#!/usr/bin/env bash
set -euo pipefail

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || exit 0
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/build"
scratch=$(mktemp -d "$root/build/fast-runtime-test.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/sysroot"
cp -a "$root/stdlib" "$root/runtime" "$scratch/sysroot/"
export ABLA_SYSROOT=$scratch/sysroot
unset ABLA_STDLIB
export ABLA_CACHE_DIR=$scratch/cache
source_file=$scratch/main.ab
program=$scratch/program
cat > "$source_file" <<'ABLA'
import "abla/io"
import "abla/memory"
import "abla/process"

class Link(val value: string, val next: Link?)

fun main: int {
    var kept: Link? = null
    for (index in 0 until 128) kept = Link("retained-${index}-padding-for-heap", kept)
    for (index in 0 until 4000) {
        val garbage = "garbage-${index}-padding-for-heap"
        if (garbage.size == 0) panic("allocation failed")
    }
    memoryCollect()
    if (memoryHeapStat(5) + memoryHeapStat(6) == 0) panic("collector did not run")
    var node = kept
    var remaining = 128
    while (true) {
        val link = node
        if (link == null) break
        remaining = remaining - 1
        if (link.value != "retained-${remaining}-padding-for-heap") panic("lost a root")
        node = link.next
    }
    if (remaining != 0) panic("lost the list")
    println("limit ${memoryLimit()}")
    0
}
ABLA

ABLA_FAST_RUNTIME_OBJECT=0 "$compiler" build "$source_file" --fast --no-cache -o "$program"
"$program" > "$scratch/expected"
grep -qx 'limit 4611686018427387903' "$scratch/expected"
cp "$program" "$scratch/ordinary"

unset ABLA_FAST_RUNTIME_OBJECT
"$compiler" build "$source_file" --fast --no-cache -o "$program"
"$program" > "$scratch/actual"
cmp "$scratch/expected" "$scratch/actual"
ABLA_GC_STRESS=1 "$program" > "$scratch/stress"
cmp "$scratch/expected" "$scratch/stress"
ABLA_GC_STRESS=1 ABLA_COMPACT_HEADERS=0 "$program" > "$scratch/legacy-stress"
cmp "$scratch/expected" "$scratch/legacy-stress"
records=("$ABLA_CACHE_DIR"/fast-runtime-v1/*/record)
[[ ${#records[@]} == 1 && -s ${records[0]} ]]
cp "$program" "$scratch/cold"
cp "$program.o" "$scratch/cold.o"

"$compiler" build "$source_file" --fast -o "$program"
cmp "$scratch/cold" "$program"
cmp "$scratch/cold.o" "$program.o"
"$compiler" build "$source_file" --fast -o "$program"
cmp "$scratch/cold" "$program"

# A second empty runtime cache must yield the same bytes.
ABLA_CACHE_DIR=$scratch/other-cache "$compiler" build "$source_file" --fast --no-cache -o "$program"
cmp "$scratch/cold" "$program"
cmp "$scratch/cold.o" "$program.o"

# Two producers racing for the same missing key must agree with the baseline
# cold split, including when one waits for the other's publication.
ABLA_CACHE_DIR=$scratch/race-cache "$compiler" build "$source_file" --fast --no-cache -o "$scratch/race-a" &
first=$!
ABLA_CACHE_DIR=$scratch/race-cache "$compiler" build "$source_file" --fast --no-cache -o "$scratch/race-b" &
second=$!
wait "$first"
wait "$second"
cmp "$scratch/cold" "$scratch/race-a"
cmp "$scratch/cold" "$scratch/race-b"
race_records=("$scratch/race-cache"/fast-runtime-v1/*/record)
[[ ${#race_records[@]} == 1 && -s ${race_records[0]} ]]

runtime_object=${records[0]%/record}/runtime.o
touch -r "$runtime_object" "$scratch/object-mtime"
printf 'bad!' | dd of="$runtime_object" conv=notrunc status=none
touch -r "$scratch/object-mtime" "$runtime_object"
"$compiler" build "$source_file" --fast -o "$program"
cmp "$scratch/cold" "$program"

printf 'damaged record\n' > "${records[0]}"
"$compiler" build "$source_file" --fast -o "$program"
cmp "$scratch/cold" "$program"

ABLA_CACHE_DIR=$scratch/debug-cache-a "$compiler" build "$source_file" --fast -g --no-cache -o "$program"
cp "$program" "$scratch/debug-first"
ABLA_CACHE_DIR=$scratch/debug-cache-b "$compiler" build "$source_file" --fast -g --no-cache -o "$program"
cmp "$scratch/debug-first" "$program"

touch "$scratch/blocked-cache"
ABLA_CACHE_DIR=$scratch/blocked-cache "$compiler" build "$source_file" --fast --no-cache -o "$program"
cmp "$scratch/ordinary" "$program"

ABLA_KEEP_LLVM_TEXT=1 ABLA_FAST_RUNTIME_OBJECT=0 \
    "$compiler" build "$source_file" --fast --no-cache -o "$program"
cp "$program.ll" "$scratch/ordinary.ll"
ABLA_KEEP_LLVM_TEXT=1 "$compiler" build "$source_file" --fast --no-cache -o "$program"
cmp "$scratch/ordinary.ll" "$program.ll"

cat > "$scratch/staged.ab" <<'ABLA'
import "abla/io"
fun answer(): int = 42
val staged: int = #answer()
fun main: int {
    println("staged ${staged}")
    0
}
ABLA
ABLA_FAST_RUNTIME_OBJECT=0 "$compiler" build "$scratch/staged.ab" --fast --no-cache -o "$program"
cp "$program" "$scratch/ordinary-staged"
"$compiler" build "$scratch/staged.ab" --fast --no-cache -o "$program"
cmp "$scratch/ordinary-staged" "$program"

# The object's DWARF names no program and no machine's paths: another program in another cache gets the same object, and the
# standard library is under the fixed prefix that `ablac symbolize` maps back (docs/debugging.md), not this sysroot.
printf 'import "abla/io"\nfun main: int { println("other"); 0 }\n' > "$scratch/other.ab"
ABLA_CACHE_DIR=$scratch/other-program-cache "$compiler" build "$scratch/other.ab" --fast -g --no-cache -o "$scratch/other"
first_objects=("$scratch"/debug-cache-a/fast-runtime-v1/*/runtime.o)
other_objects=("$scratch"/other-program-cache/fast-runtime-v1/*/runtime.o)
[[ ${#first_objects[@]} == 1 && ${#other_objects[@]} == 1 ]]
cmp "${first_objects[0]}" "${other_objects[0]}"
grep -aFq '/abla-toolchain/stdlib' "${first_objects[0]}"
if grep -aFq "$ABLA_SYSROOT" "${first_objects[0]}"; then echo "fast runtime: the object names the sysroot $ABLA_SYSROOT" >&2; exit 1; fi

# A toolchain that ships the entry (ABLA_SEED_FAST_RUNTIME=1, as the packagers and `make ablac` do): a fresh cache takes it, runs
# no front end or code generation for the runtime, and the program is the same bytes.
ABLA_CACHE_DIR=$scratch/seed-cache ABLA_SEED_FAST_RUNTIME=1 "$compiler" build "$source_file" --fast --no-cache -o "$program"
cmp "$scratch/cold" "$program"
shipped=("$ABLA_SYSROOT"/fast-runtime-v1/*/record)
[[ ${#shipped[@]} == 1 && -s ${shipped[0]} ]]
shipped_build() { # cache name: a fresh-cache build, its trace in $scratch/<cache name>.trace
    ABLA_CACHE_DIR=$scratch/$1 ABLA_COMPILER_MEMORY_TRACE=1 "$compiler" build "$source_file" --fast --no-cache -o "$program" \
        2> "$scratch/$1.trace"
}
shipped_build shipped-cache
grep -aFq 'fast-runtime.shipped' "$scratch/shipped-cache.trace"
if grep -aFq 'fast-runtime.compile' "$scratch/shipped-cache.trace"; then echo 'fast runtime: compiled although the toolchain ships it' >&2; exit 1; fi
cmp "$scratch/cold" "$program"
# A shipped object that does not match its record is not taken: the build compiles its own.
shipped_object=${shipped[0]%/record}/runtime.o
cp "$shipped_object" "$scratch/shipped-object"
printf 'bad!' | dd of="$shipped_object" conv=notrunc status=none
shipped_build damaged-shipped-cache
grep -aFq 'fast-runtime.compile' "$scratch/damaged-shipped-cache.trace"
if grep -aFq 'fast-runtime.shipped' "$scratch/damaged-shipped-cache.trace"; then echo 'fast runtime: took a damaged shipped object' >&2; exit 1; fi
cmp "$scratch/cold" "$program"
cp "$scratch/shipped-object" "$shipped_object"

host=$ABLA_SYSROOT/stdlib/abla/runtime/platform/host.ab
grep -q '^var __ablaRuntimeHostLimit: int = 4611686018427387903$' "$host"
sed -e 's/^var __ablaRuntimeHostLimit: int = 4611686018427387903$/var __ablaRuntimeHostLimit: int = 66846720/' \
    -e 's/^    else __ablaRuntimeHostLimit$/    else __ablaRuntimeHostLimit + __ablaRuntimeHostFixtureReadSlots()/' \
    "$host" > "$host.next"
cat >> "$host.next" <<'ABLA'

// New collector helpers follow their state into the object.
val __ablaRuntimeHostFixtureSlots: int = __ablaRuntimeHostGcAdaptiveMinimumSlots
private trusted fun __ablaRuntimeHostFixtureReadSlots(): int = __ablaRuntimeHostFixtureSlots
ABLA
mv "$host.next" "$host"
"$compiler" build "$source_file" --fast -o "$program"
"$program" > "$scratch/updated"
grep -qx 'limit 67108864' "$scratch/updated"
records=("$ABLA_CACHE_DIR"/fast-runtime-v1/*/record)
[[ ${#records[@]} == 2 && -s ${records[0]} && -s ${records[1]} ]]

# The switch cannot influence an ordinary release link.
ABLA_FAST_RUNTIME_OBJECT=0 "$compiler" build "$source_file" --no-cache -o "$program"
cp "$program" "$scratch/release"
"$compiler" build "$source_file" --no-cache -o "$program"
cmp "$scratch/release" "$program"
echo "fast runtime object: reproducible, rooted and invalidated by runtime source"
