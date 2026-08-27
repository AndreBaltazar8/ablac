#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
program=$project_root/build/native-function-address-test

"$compiler" build \
    "$project_root/tests/cases/modules/native-function-address.ab" \
    -o "$program" --fast --no-cache
set +e
"$program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    exit 1
fi

echo 'Native function address lowering passed'
