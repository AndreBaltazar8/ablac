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

pids=()
for program in background inline fork; do
    ABLA_KEEP_LLVM_TEXT=1 "$compiler" build "$cases/$program.ab" -o "$output_directory/$program" --no-cache &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
# Bound the process tree as well as the parent: the regression is a child
# waiting forever on a lock whose owning thread existed only in the parent.
forked=$(ABLA_MAX_SECONDS=60 "$project_root/tools/run-limited.sh" "$output_directory/fork")
[[ $forked == "80196000000" ]] || fail "fork/free race: unexpected checksum '$forked'"
# (Each pair of runs at once: nothing here depends on the machine being quiet.)
"$output_directory/inline" > "$output_directory/inline.out" &
inline_pid=$!
background=$("$output_directory/background")
wait "$inline_pid"
inline=$(<"$output_directory/inline.out")
[[ $background == "$inline" ]] || fail "with background freeing: '$background', without: '$inline'"
[[ $background == *" 6 true" ]] || fail "unexpected output '$background' (child's text, freed memory returned)"
ABLA_GC_STRESS=1 "$output_directory/inline" 3 > "$output_directory/inline-stressed.out" &
inline_pid=$!
stressed=$(ABLA_GC_STRESS=1 "$output_directory/background" 3)
wait "$inline_pid"
[[ $stressed == "$(<"$output_directory/inline-stressed.out")" ]] ||
    fail "under ABLA_GC_STRESS=1 the outputs differ"
# Both implementations must actually honor the requested three rounds.
[[ $stressed == "790718635 6 true" ]] || fail "the stressed run did not do three rounds: '$stressed'"
# The linked programs' LLVM text (ABLA_KEEP_LLVM_TEXT=1 above): the helper's entry, the function the runtime hands to a
# thread, is in the program that asks for background freeing and only there. (The symbols do not tell: a libc-free
# program defines its clone routine whether it has a helper or not, and a hosted one that has any thread imports
# pthread_create.)
helper='"abla.source"="__ablaRuntimeHostFreeWorker"'
! grep -q "$helper" "$output_directory/inline.ll" ||
    fail "a program without background freeing has the helper"
grep -q "$helper" "$output_directory/background.ll" ||
    fail "a program with background freeing has no helper"

echo "gc background free: same output (and under stress), a child process meanwhile, freed memory returned to the allocator; only the program asking for it has the helper"
