#!/usr/bin/env bash
# ABLA_GC_STRESS=1 collects at every safe point, so a value a function fails to root
# is freed at once instead of under rare pressure. Programs that keep values across
# allocations (generators, tasks, retained strings, loop-carried roots, callbacks that
# allocate: comparators, generator and task bodies, drops) give their
# usual results under it.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/gc-stress"
mkdir -p "$output_directory"

build() { # source name
    "$compiler" build "$1" -o "$output_directory/$2" --no-cache \
        >"$output_directory/$2.log" 2>&1 || { cat "$output_directory/$2.log" >&2; exit 1; }
}

# expect <name> <status> <output, or * for any> [environment...]
expect() {
    local name=$1 expected_status=$2 expected_output=$3 output status
    shift 3
    set +e
    output=$(env "$@" ABLA_MAX_SECONDS=60 ABLA_MAX_MEMORY_MB=256 \
        "$project_root/tools/run-limited.sh" "$output_directory/$name" 2>&1)
    status=$?
    set -e
    if [[ $status -ne $expected_status ||
        ($expected_output != "*" && $output != "$expected_output") ]]; then
        echo "gc stress: $name ($*): status $status, output '$output'" >&2
        exit 1
    fi
}

# The knob: the same program, collected only under pressure by default.
build "$project_root/tests/cases/gc-stress/collects.ab" collects
expect collects 1 ""
expect collects 42 "" ABLA_GC_STRESS=1

modules="$project_root/tests/cases/modules"
for name in generator-nested generator-lazy generator-affine task-array-move \
    generator-task-capture string-retention; do
    build "$modules/$name.ab" "$name"
done
# Fewer rounds of the loop-roots program: each of its calls collects here.
sed 's/round < 2000/round < 40/' "$modules/runtime-memory-loop-roots.ab" \
    > "$output_directory/loop-roots.ab"
build "$output_directory/loop-roots.ab" loop-roots
build "$project_root/tests/cases/gc-stress/callbacks.ab" callbacks

stress=ABLA_GC_STRESS=1
expect callbacks 42 "" $stress
expect generator-nested 0 114 $stress
expect generator-lazy 0 $'produce 0\ngot 0\nproduce 1\ngot 1\nproduce 2\ngot 2\ntotal 5050\nstart\nv 1\nclosed\n--\nstart\nv 1\nafter 1\nv 2\nafter 2\nclosed\n--\ndropping\na\nbb\nb!\nb!\nc\nu0\nu1\nu2\nc1\nc2\nzero\none\none!\nmany\no 10\nclose a\nclose r\nfirst 1\nlevel 0\nlevel 2\nlevel 4\nlevel 5\nend' $stress
expect generator-affine 0 $'got 7\ngot 8\ndrop 8\ndrop 7\n--\ngot 7\ngot 8\ngot 3\ndrop 8\ndrop 7\n--\ngot 1\ndefer sees 9\ndrop 9\ngot 2\n--\ngot 0\ngot 5\ndrop 5\n--\nend\ndrop 7' $stress
expect task-array-move 0 6 $stress
expect generator-task-capture 0 $'1\n4\nfinished 4' $stress
expect string-retention 42 "*" $stress
expect loop-roots 42 "" $stress
echo "gc stress: every safe point collects; generators, tasks, retained strings and loop roots hold"
