#!/usr/bin/env bash
# A release compiler builds and links a program with a collection at every
# safe point (ABLA_GC_STRESS=1): every value the compiler, its toolchain steps
# and the processes it spawns hold is rooted. About a quarter of an hour on a
# fast Mac, so it is not part of `make test`.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compiler-gc-stress"
mkdir -p "$output_directory"
ABLA_GC_STRESS=1 ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-3600} \
    "$project_root/tools/run-limited.sh" "$compiler" build \
    "$project_root/tests/cases/bootstrap/block.ab" \
    -o "$output_directory/block" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/block"
status=$?
set -e
[[ $status -eq 42 ]] || { echo "compiler gc stress: program exited $status, expected 42" >&2; exit 1; }
echo "compiler gc stress: a program builds and runs with a collection at every safe point"
