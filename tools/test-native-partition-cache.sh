#!/usr/bin/env bash
# The ELF partition cache: a rebuild after an edit reuses the partitions the
# edit did not touch. Partitions hold the boxed-ABI wrappers; typed scalar
# bodies stay in the root object, so an edit to one refreshes no partition.
# Partitioning is ELF-only, so other hosts build the x86-64 Linux object.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
directory="$project_root/build/native-partition-cache-test"
source_file="$directory/app.ab"
program="$directory/program"
cache_directory="$project_root/build/.abla-cache"
mkdir -p "$directory" "$cache_directory" || exit 1

native_host=0
target_flags=(--target x86_64-linux --emit object)
if [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]]; then
    native_host=1
    target_flags=()
fi

# This test measures cache population, so prior runs must not turn its first
# build into a whole-object or partition hit. The cache contains generated,
# reproducible artifacts only.
find "$cache_directory" -mindepth 1 -maxdepth 1 -type f -delete || exit 1

# Every function is reachable (unreachable ones are pruned before emission)
# and takes a parameter, so none folds into its caller.
write_source() {
    {
        printf 'fun partitionFunction0(value: int): int = value + %s\n' "$1"
        for index in $(seq 1 95); do
            printf 'fun partitionFunction%s(value: int): int = value * %s\n' \
                "$index" "$index"
        done
        printf 'fun partitionSum(value: int): int = 0'
        for index in $(seq 1 95); do
            printf ' +\n    partitionFunction%s(value)' "$index"
        done
        printf '\nfun partitionCaller(value: int): int = partitionFunction0(value) + 40\n'
        printf 'fun main: int = if (partitionSum(1) == 4560) partitionCaller(2 - %s) else 0\n' "$1"
    } > "$source_file"
}

partition_count() {
    find "$cache_directory" -maxdepth 1 -type f \
        -name 'native-partition-x86_64-linux-llvm21-v2-*.o' | wc -l
}

write_source 1 || exit 1
before=$(partition_count)
"$compiler" build "$source_file" -o "$program" --fast \
    ${target_flags[@]+"${target_flags[@]}"} || exit 1
after_first=$(partition_count)
first_added=$((after_first - before))
[[ $first_added -ge 4 ]] || exit 1

write_source 2 || exit 1
"$compiler" build "$source_file" -o "$program" --fast \
    ${target_flags[@]+"${target_flags[@]}"} || exit 1
after_second=$(partition_count)
second_added=$((after_second - after_first))
[[ $second_added -lt $first_added ]] || exit 1

if [[ $native_host -eq 1 ]]; then
    set +e
    "$project_root/tools/run-limited.sh" "$program"
    status=$?
    set -e
    [[ $status -eq 42 ]] || exit 1
fi

printf 'native partition cache: first=%s refreshed edit=%s; unchanged buckets reused\n' \
    "$first_added" "$second_added"
