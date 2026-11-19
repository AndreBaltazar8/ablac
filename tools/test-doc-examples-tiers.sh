#!/usr/bin/env bash
# The documentation's compile-time examples hold in every tier: each example with a `#` site or a `compile`
# declaration is built and run again under ABLA_COMPILE_EVAL=interp and =jit, with the same expected output as
# tools/test-doc-examples.sh checks under the default (auto). An example that is wrong in one tier is a compiler bug,
# unless the documentation promises less there.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for tier in interp jit; do
    printf '%s: ' "$tier"
    ABLA_COMPILE_EVAL=$tier DOC_EXAMPLES_COMPILE_TIME=1 DOC_EXAMPLES_WORK=$project_root/build/doc-examples-$tier \
        "$project_root/tools/test-doc-examples.sh" "$compiler"
done
echo "doc examples in every tier: the compile-time examples give their documented results under interp and jit"
