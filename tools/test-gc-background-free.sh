#!/usr/bin/env bash
# Background freeing (memorySetBackgroundFree): a program that turns it on gives
# the output the same program gives without it (under the collector's stress
# too), starts a child process while the helper may be freeing, and what the
# helper frees goes back to the allocator (macOS: out of use in malloc;
# elsewhere: filling as much again reuses it).
# Only such a program is built with the helper: one without it has no helper's
# code at all.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/gc-background-free"
output_directory="$project_root/build/gc-background-free"
mkdir -p "$output_directory"
fail() {
    echo "gc background free: $1" >&2
    exit 1
}

for program in background inline fork; do
    "$compiler" build "$cases/$program.ab" -o "$output_directory/$program" --no-cache
done
# Bound the process tree as well as the parent: the regression is a child
# waiting forever on a lock whose owning thread existed only in the parent.
forked=$(ABLA_MAX_SECONDS=60 "$project_root/tools/run-limited.sh" "$output_directory/fork")
[[ $forked == "80196000000" ]] || fail "fork/free race: unexpected checksum '$forked'"
background=$("$output_directory/background")
inline=$("$output_directory/inline")
[[ $background == "$inline" ]] || fail "with background freeing: '$background', without: '$inline'"
[[ $background == *" 6 true" ]] || fail "unexpected output '$background' (child's text, freed memory returned)"
stressed=$(ABLA_GC_STRESS=1 "$output_directory/background" 3)
[[ $stressed == "$(ABLA_GC_STRESS=1 "$output_directory/inline" 3)" ]] ||
    fail "under ABLA_GC_STRESS=1 the outputs differ"
# The linked programs (--emit-llvm writes the unpruned runtime, threads and all).
nm -u "$output_directory/inline" > "$output_directory/inline.symbols"
! grep -q "pthread_create" "$output_directory/inline.symbols" ||
    fail "a program without background freeing has the helper"
nm -u "$output_directory/background" > "$output_directory/background.symbols"
grep -q "pthread_create" "$output_directory/background.symbols" ||
    fail "a program with background freeing has no helper"

echo "gc background free: same output (and under stress), a child process meanwhile, freed memory returned to the allocator; only the program asking for it has the helper"
