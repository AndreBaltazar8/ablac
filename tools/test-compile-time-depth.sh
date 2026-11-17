#!/usr/bin/env bash
# Deep compile-time recursion in the evaluator (ABLA_COMPILE_EVAL=interp: by default the native
# tier takes a recursive site, and natively it runs as it does at run time) stops with
# E_EVAL_STACK_DEPTH instead of crashing the
# compiler; recursion the stack can take still evaluates.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compile-time-depth"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/compile-time-recursion.ab" \
    -o "$output_directory/shallow" --no-cache
"$output_directory/shallow"

reject() { # file [env…]
    local file=$1; shift
    set +e
    diagnostics=$(env ABLA_COMPILE_EVAL=interp "$@" "$compiler" build "$project_root/tests/cases/modules/$file.ab" \
        -o "$output_directory/$file" --no-cache 2>&1)
    status=$?
    set -e
    # A crash is 128+signal; the diagnostic is an ordinary failure.
    [[ $status -ne 0 && $status -lt 128 && $diagnostics == *E_EVAL_STACK_DEPTH* ]] ||
        { echo "$file: status $status"; echo "$diagnostics"; exit 1; }
    [[ $(grep -c 'E_EVAL_STACK_DEPTH' <<<"$diagnostics") -eq 1 ]] || { echo "$file: reported more than once"; exit 1; }
}

reject compile-time-recursion-deep
reject compile-time-recursion ABLA_EVAL_DEPTH_LIMIT=300
echo "compile-time depth: deep recursion is a diagnostic, not a crash"
