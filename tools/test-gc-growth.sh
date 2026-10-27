#!/usr/bin/env bash
# ABLA_GC_GROWTH=<bytes> sets the growth between collections without a rebuild. A
# program keeping a small live heap amid much garbage stays below 8 MiB with a 2 MiB
# step and not with the default one, keeping what it keeps either way (and under
# ABLA_GC_STRESS=1); a value that is not decimal bytes of at least 1 MiB is ignored.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/gc-growth"
program="$output_directory/garbage"
mkdir -p "$output_directory"
fail() {
    echo "gc growth: $1" >&2
    exit 1
}
"$compiler" build "$project_root/tests/cases/gc-growth/garbage.ab" \
    -o "$program" --fast --no-cache

expected='total 48778890 kept 7890'
default=$("$program")
[[ $default == "$expected small false" ]] || fail "default growth: '$default'"
stepped=$(ABLA_GC_GROWTH=2097152 "$program")
[[ $stepped == "$expected small true" ]] || fail "ABLA_GC_GROWTH=2097152: '$stepped'"
ignored=$(ABLA_GC_GROWTH=2mb "$program")
[[ $ignored == "$expected small false" ]] || fail "ABLA_GC_GROWTH=2mb is not bytes, yet: '$ignored'"
tiny=$(ABLA_GC_GROWTH=4096 "$program")
[[ $tiny == "$expected small false" ]] || fail "ABLA_GC_GROWTH=4096 is under 1 MiB, yet: '$tiny'"
stressed=$(ABLA_GC_STRESS=1 ABLA_GC_GROWTH=2097152 "$program")
[[ $stressed == "$expected small true" ]] || fail "under ABLA_GC_STRESS=1: '$stressed'"
echo 'gc growth: ABLA_GC_GROWTH sets the step between collections; other values are ignored'
