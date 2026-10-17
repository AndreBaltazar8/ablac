#!/usr/bin/env bash
# Generators nest (an inner generator runs to its end with its own buffer) and `yield`
# takes a whole expression; an affine element of an array iterated in place is borrowed,
# so awaiting or moving it is rejected, while iterating `move(array)` owns the elements.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/generators-tasks"
mkdir -p "$output_directory"

check() {
    "$compiler" build "$project_root/tests/cases/modules/$1.ab" \
        -o "$output_directory/$1" --no-cache
    set +e
    output=$("$output_directory/$1")
    status=$?
    set -e
    [[ $status -eq 0 && $output == "$2" ]] || { echo "$1: status $status, output '$output'"; exit 1; }
}

reject() {
    set +e
    diagnostics=$("$compiler" build "$project_root/tests/cases/modules/$1.ab" \
        -o "$output_directory/$1" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 && $diagnostics == *"$2"* ]] || { echo "$1: expected $2"; echo "$diagnostics"; exit 1; }
}

check generator-nested 114
check task-array-move 6
reject task-array-borrow "ownership.await-borrow:each"
reject task-array-borrow-move "move.local"
echo "generators and tasks: nesting, yield precedence, borrowed task elements"
