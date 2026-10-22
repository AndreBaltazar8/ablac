#!/usr/bin/env bash
# abla/process/metrics reads this process's CPU time, memory, descriptors,
# descriptor limit, start time and heap (tests/cases/modules/process-metrics.ab
# checks each against what it just did).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/process-metrics"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/process-metrics.ab" \
    -o "$output_directory/program" --no-cache
set +e
output=$(ABLA_TEST_ULIMIT=$(ulimit -n) "$output_directory/program")
status=$?
set -e
[[ $status -eq 42 && $output == "process metrics: ok" ]] ||
    { echo "process metrics: exited with $status"; echo "$output"; exit 1; }
echo "process metrics: cpu, memory, descriptors, limit, start time, heap"
