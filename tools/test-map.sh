#!/usr/bin/env bash
# Map<K, V>: string and int keys, removal, growth, object values.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/map"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/map.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

# The same under a collection every few KB.
"$compiler" build \
    "$project_root/tests/cases/modules/map-collect.ab" \
    -o "$output_directory/collect" --no-cache
set +e
"$output_directory/collect"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "map: keys, values, removal, growth, under collection"
