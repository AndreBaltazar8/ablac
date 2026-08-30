#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
ir=$project_root/build/internal-function-test.ll
native=$project_root/build/internal-function-assembly-test
required_native=$project_root/build/required-internal-function-test

"$compiler" --emit-llvm \
    "$project_root/tests/cases/internal-function.ab" >"$ir"
rg -q '^@llvm\.used = .*@abla_test_increment' "$ir"
rg -q '^@abla_test_increment = internal alias i32 \(i32\), ptr @abla_fn_.*_direct$' "$ir"
rg -q '^@llvm\.used = .*@abla_test_choose' "$ir"
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

# Demand lowering must treat exact linker-symbol tokens in reachable inline
# assembly as edges to internalFunction declarations. An unrelated internal
# alias remains eligible for whole-program pruning.
"$compiler" build \
    "$project_root/tests/cases/internal-function-assembly.ab" \
    -o "$native" --no-cache
nm "$native" | rg -q 'abla_test_reachable_from_assembly$'
if nm "$native" | rg -q 'abla_test_unused_internal_alias$'; then
    exit 1
fi
if nm "$native" | rg -q 'abla_test_unused_scalar_initializer$'; then
    exit 1
fi
"$native"

# Some target backends introduce helper calls only after source and assembly
# reachability closes. A required internal definition must survive as a local
# symbol without becoming part of the public artifact ABI.
"$compiler" build \
    "$project_root/tests/cases/required-internal-function.ab" \
    -o "$required_native" --emit object --no-cache
nm "$required_native" | rg -q ' t abla_test_late_runtime_helper$'
if rg -q 'abla_test_late_runtime_helper' "$required_native.abi.json"; then
    exit 1
fi
echo 'Internal function link symbol lowering passed'
