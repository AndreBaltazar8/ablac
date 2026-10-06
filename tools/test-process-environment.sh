#!/usr/bin/env bash
# abla/process reads environment variables: set, unset, a fallback, and a
# name that is only a prefix of a set one.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/process-environment"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/process-environment.ab" \
    -o "$output_directory/program" --no-cache
set +e
ABLA_TEST_ENV="value=with=equals" "$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "process environment: set, unset and fallback"
