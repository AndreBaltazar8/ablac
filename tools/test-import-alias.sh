#!/usr/bin/env bash
# One file imported through two relative spellings that climb above the working
# directory (`../lib/x.ab` and `../../other/../pkg/lib/x.ab`) is one module.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
case $compiler in /*) ;; *) compiler=$project_root/$compiler ;; esac
output_root=$project_root/build/import-alias-test
mkdir -p "$output_root"
cd "$project_root/tests/cases/import-alias/pkg/app"
"$compiler" build main.ab -o "$output_root/import-alias" --no-cache
set +e
"$output_root/import-alias"
status=$?
set -e
test "$status" -eq 42
echo "import alias: one module per file"
