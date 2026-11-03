#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output="$root/build/inferred-command"
mkdir -p "$output"
"$compiler" build "$root/tests/cases/inferred-command/main.ab" -o "$output/main"
status=0
"$output/main" || status=$?
[[ $status -eq 42 ]]
echo 'inferred conditional and when values retain the type of fresh fluent results'
