#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
program="$project_root/build/portable-buffered-io/program"

mkdir -p "$(dirname -- "$program")"
"$compiler" build \
    "$project_root/tests/cases/modules/portable-buffered-io.ab" \
    -o "$program" --fast --no-cache

set +e
"$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' 'portable buffered I/O: callback sink + truncate/append file adapter passed'
