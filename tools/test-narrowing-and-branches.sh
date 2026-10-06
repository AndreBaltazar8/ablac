#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/narrowing-and-branches
source_file=$project_root/tests/cases/modules/narrowing-and-branches.ab
program=$output_directory/program

mkdir -p "$output_directory"
"$compiler" build "$source_file" -o "$program" --no-cache
set +e
"$program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'narrowing and branches: exited %d, expected 42\n' "$status" >&2
    exit 1
fi

printf '%s\n' 'borrowed nullables narrow, early exits narrow, [] takes its branch type'
