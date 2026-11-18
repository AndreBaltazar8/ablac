#!/usr/bin/env bash
# A function of 800 nested blocks (each a local and an `if` whose branch is the next block) builds within a CPU budget
# (#1022 follow-up). A block's type query walked its tail to find the locals it depends on, on every query and in a
# fresh scope each time, so the walks grew with the cube of the nesting: 28.7 s for this program, 84% of it in
# bootstrapTypeQueryReads; a large block's selection is now made once (BootstrapLowerer.blockTypeSelectionEntry), 1.8 s.
# The budget is CPU time, not wall time, so a busy machine doesn't fail it.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/nested-block-types"
rm -rf "$out"; mkdir -p "$out"
fail() { echo "nested block types: $*" >&2; exit 1; }
depth=800
{
    echo 'import "abla/io"'
    echo 'fun nested(x: int): int {'
    for ((level = 0; level < depth; level++)); do
        echo "val a$level = x + $level"
        echo "if (a$level > $level) {"
    done
    echo 'x'
    for ((level = depth - 1; level >= 0; level--)); do
        echo "} else a$level"
    done
    echo '}'
    echo 'fun main { println("${nested(1000000)} ${nested(-5)}") }'
} > "$out/main.ab"
status=0
ABLA_MAX_CPU_SECONDS=12 ABLA_MAX_SECONDS=180 "$project_root/tools/run-limited.sh" \
    "$compiler" build "$out/main.ab" -o "$out/program" --fast --no-cache > "$out/build.log" 2>&1 || status=$?
[[ $status -eq 0 ]] || { tail -5 "$out/build.log" >&2; fail "the build failed or exceeded 12 CPU seconds (exit $status)"; }
# Every test `x + level > level` holds when x > 0: a positive x reaches the innermost `x`, a negative one leaves at
# the first, with a0 = x.
output=$("$out/program")
[[ $output == "1000000 -5" ]] || fail "printed '$output'"
echo "nested block types: 800 nested blocks build within 12 CPU seconds and run"
