#!/usr/bin/env bash
# abla/math/fast declares abla/math's public interface (with abla/math/v8:
# tests/cases/math-v8/interface.ab) and keeps the results abla/math gave before
# it became correctly rounded: per-function digests recorded from that
# abla/math (tests/cases/math-fast/digests.ab), natively at every optimization
# level and under `#` in the evaluator and the native tier.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/math-fast"
cases="$project_root/tests/cases"
mkdir -p "$output_directory"

run_42() {
    local status
    set +e
    "$1"
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "math-fast: $1 exited $status" >&2; exit 1; }
}

"$compiler" build "$cases/math-v8/interface.ab" -o "$output_directory/interface" --no-cache
run_42 "$output_directory/interface"
for profile in o2 o1 fast; do
    flags=()
    [[ $profile == o2 ]] || flags=("--$profile")
    "$compiler" build "$cases/math-fast/digests.ab" -o "$output_directory/digests-$profile" \
        ${flags[@]+"${flags[@]}"} --no-cache
    run_42 "$output_directory/digests-$profile"
done
for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build "$cases/math-fast/digests.ab" \
        -o "$output_directory/digests-$tier" --fast --no-cache
    run_42 "$output_directory/digests-$tier"
done
echo "math-fast: interface alike; digests native o2/o1/fast and # (evaluator and native tier) match abla/math before correct rounding"
