#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
package="$project_root/tests/cases/package-project"
output="$package/build/package-probe"

"$compiler" build --project "$package" --fast --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output"
status=$?
set -e
[[ $status -eq 42 ]]

set +e
"$compiler" run --project "$package"
run_status=$?
set -e
[[ $run_status -eq 42 ]]

set +e
invalid_output=$("$compiler" build --project \
    "$project_root/tests/cases/package-project-invalid" \
    --fast --no-cache 2>&1)
invalid_status=$?
set -e
[[ $invalid_status -eq 2 ]]
[[ $invalid_output == *'package entry must be a safe relative path'* ]]

printf '%s\n' 'package workflow: TOML build/run + unsafe-path rejection passed'
