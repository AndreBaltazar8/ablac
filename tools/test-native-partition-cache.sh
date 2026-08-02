#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
directory="$project_root/build/native-partition-cache-test"
source_file="$directory/app.ab"
program="$directory/program"
cache_directory="$project_root/build/.abla-cache"
mkdir -p "$directory" "$cache_directory"

# This test measures cache population, so prior runs must not turn its first
# build into a whole-object or partition hit. The cache contains generated,
# reproducible artifacts only.
find "$cache_directory" -mindepth 1 -maxdepth 1 -type f -delete

{
    printf 'fun partitionFunction0: int = 1\n'
    for index in $(seq 1 95); do
        printf 'fun partitionFunction%s: int = %s\n' "$index" "$index"
    done
    printf 'fun partitionCaller: int = partitionFunction0() + 40\n'
    printf 'fun main: int = partitionCaller()\n'
} > "$source_file"

partition_count() {
    find "$cache_directory" -maxdepth 1 -type f \
        -name 'native-partition-x86_64-linux-llvm21-v1-*.o' | wc -l
}

before=$(partition_count)
"$compiler" build "$source_file" -o "$program" --fast
after_first=$(partition_count)
first_added=$((after_first - before))
[[ $first_added -ge 4 ]]

sed -i 's/partitionFunction0: int = 1/partitionFunction0: int = 2/' \
    "$source_file"
"$compiler" build "$source_file" -o "$program" --fast
after_second=$(partition_count)
second_added=$((after_second - after_first))
[[ $second_added -ge 1 ]]
[[ $second_added -lt $first_added ]]

set +e
"$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]]

printf 'native partition cache: first=%s refreshed edit=%s; unchanged buckets reused\n' \
    "$first_added" "$second_added"
