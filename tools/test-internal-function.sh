#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
ir=$project_root/build/internal-function-test.ll

"$compiler" --emit-llvm \
    "$project_root/tests/cases/internal-function.ab" >"$ir"
rg -q '^@llvm\.compiler\.used = .*@abla_test_increment' "$ir"
rg -q '^define internal i32 @abla_test_increment\(' "$ir"
if rg -q '^define (external |private )?i32 @abla_test_increment\(' "$ir"; then
    exit 1
fi

echo 'Internal function link symbol lowering passed'
