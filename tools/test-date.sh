#!/usr/bin/env bash
# abla/date (UTC calendar, ISO 8601 and HTTP dates) and abla/process/time's
# wall clock, at run time and at compile time.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/date"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/date.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "date: UTC calendar, formats and the wall clock"
