#!/usr/bin/env bash
# A loop that allocates reaches a safe point on its back edge: garbage made in main's
# own loop by runtime helpers alone (no other call) is collected, with the default
# step and with a collection at every safe point (ABLA_GC_STRESS=1), and what the
# program keeps survives.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/loop-safe-point"
program="$output_directory/loop"
mkdir -p "$output_directory"
fail() {
    echo "loop safe point: $1" >&2
    exit 1
}
"$compiler" build "$project_root/tests/cases/loop-safe-point/loop.ab" \
    -o "$program" --no-cache

long=$("$program")
[[ $long == 'total 148558890 kept 7890 bounded true' ]] || fail "default step: '$long'"
short=$(ABLA_GC_STRESS=1 "$program" short)
[[ $short == 'total 4777890 kept 7890 bounded true' ]] ||
    fail "under ABLA_GC_STRESS=1: '$short'"
echo 'loop safe point: an allocating loop collects at its back edge, under stress too'
