#!/usr/bin/env bash
# Value slots used inside one IR block get llvm.lifetime.start/end pairs, and the
# program they are in still computes the same.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/value-lifetimes"
mkdir -p "$output_directory"
source="$project_root/tests/cases/bootstrap/value-lifetimes.ab"
"$compiler" --emit-llvm "$source" > "$output_directory/program.ll"
starts=$(grep -c 'call void @llvm.lifetime.start.p0' "$output_directory/program.ll" || true)
ends=$(grep -c 'call void @llvm.lifetime.end.p0' "$output_directory/program.ll" || true)
if [[ $starts -eq 0 || $starts -ne $ends ]]; then
    echo "value lifetimes: expected matching markers, got $starts starts and $ends ends" >&2
    exit 1
fi
"$compiler" build "$source" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "value lifetimes: program expected 42, got $status" >&2
    exit 1
fi
echo "value lifetimes: $starts block-local value slots marked; the program agrees"
