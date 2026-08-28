#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
ir=$project_root/build/internal-function-test.ll

"$compiler" --emit-llvm \
    "$project_root/tests/cases/internal-function.ab" >"$ir"
rg -q '^@llvm\.compiler\.used = .*@abla_test_increment' "$ir"
rg -q '^@abla_test_increment = internal alias i32 \(i32\), ptr @abla_fn_.*_direct$' "$ir"
rg -q '^@llvm\.compiler\.used = .*@abla_test_choose' "$ir"
rg -q '^define internal i32 @abla_test_choose\(' "$ir"
if rg -q '^define (external |private )?i32 @abla_test_increment\(' "$ir"; then
    exit 1
fi
if rg -q '^define (external |private )?i32 @abla_test_choose\(' "$ir"; then
    exit 1
fi

# Fixed-arity direct calls have no synthetic argument-count operand. Functions
# with default parameters retain it because they use it to select defaults.
choose_call=$(sed -n \
    '/^define internal i32 @abla_test_choose(/,/^}/p' "$ir" |
    rg 'call i32 @abla_fn_.*_direct')
[[ $choose_call =~ _direct\(i64\ 2,\ i32\ %0,\ i32\ %1\) ]]

echo 'Internal function link symbol lowering passed'
