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
