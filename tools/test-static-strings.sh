#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_root=$project_root/build/static-strings-test

mkdir -p "$output_root"
"$compiler" build \
    "$project_root/tests/cases/modules/static-string-concat.ab" \
    -o "$output_root/static-string-concat" --no-cache
set +e
"$output_root/static-string-concat"
status=$?
set -e
test "$status" -eq 42
