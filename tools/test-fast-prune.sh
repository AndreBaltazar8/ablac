#!/usr/bin/env bash
# --fast on a Linux host emits only the runtime functions its program reaches.
# One program per bridge family is built with pruning on and off (ABLA_FAST_PRUNE=0)
# and must link and behave the same: threads (thread_entry is reached only
# through the runtime), generators, float text, and exports (a library entered
# only through its exports, with GC roots). Wasm and cross targets are not pruned.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory=$project_root/build/fast-prune
cases=$project_root/tests/cases
mkdir -p "$output_directory"

run_both() {
    local name=$1 source=$2
    ABLA_FAST_PRUNE=1 "$compiler" build "$source" -o "$output_directory/$name-pruned" --fast --no-cache
    ABLA_FAST_PRUNE=0 "$compiler" build "$source" -o "$output_directory/$name-full" --fast --no-cache
    local status_pruned status_full
    set +e
    "$project_root/tools/run-limited.sh" "$output_directory/$name-pruned" >"$output_directory/$name-pruned.out" 2>&1
    status_pruned=$?
    "$project_root/tools/run-limited.sh" "$output_directory/$name-full" >"$output_directory/$name-full.out" 2>&1
    status_full=$?
    set -e
    if [[ $(uname -s) == Linux && $(stat -c %s "$output_directory/$name-pruned") -ge $(stat -c %s "$output_directory/$name-full") ]]; then
        echo "fast-prune: $name is not smaller pruned than full (pruning did not happen)" >&2
        exit 1
    fi
    if [[ $status_pruned -ne $status_full ]] || ! cmp -s "$output_directory/$name-pruned.out" "$output_directory/$name-full.out"; then
        echo "fast-prune: $name differs between the pruned and the full runtime (exit $status_pruned vs $status_full)" >&2
        exit 1
    fi
}

run_both threads "$cases/thread-globals/ok.ab"
run_both generators "$cases/generator-step/counter.ab"
run_both generator-words "$cases/generator-step/words.ab"
run_both floats "$cases/any-equality/floats.ab"

library=$output_directory/libroots.so
ABLA_FAST_PRUNE=1 "$compiler" build "$cases/export-global-roots/library.ab" --emit shared-library -o "$library" --fast --no-cache
clang "$cases/export-global-roots/caller.c" -L"$output_directory" -lroots \
    -Wl,-rpath,"$output_directory" -o "$output_directory/caller"
ABLA_MAX_MEMORY_MB=256 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" "$output_directory/caller"
