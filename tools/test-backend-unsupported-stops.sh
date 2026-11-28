#!/usr/bin/env bash
# An instruction the LLVM backend cannot lower (E_LLVM_INSTRUCTION_UNSUPPORTED) stops its function: the instructions after
# it, which may use its missing value, are not lowered (a store of it crashed the compiler). Both build modes.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/backend-unsupported-stops"
rm -rf "$output_directory"
mkdir -p "$output_directory"

for mode in "" "--fast"; do
    set +e
    # shellcheck disable=SC2086
    "$compiler" build "$project_root/tests/cases/backend-unsupported-stops/main.ab" $mode --no-cache \
        -o "$output_directory/main" > "$output_directory/out" 2> "$output_directory/err"
    status=$?
    set -e
    if [[ $status -ne 1 ]] ||
        ! grep -F 'error[E_LLVM_INSTRUCTION_UNSUPPORTED]: function `cString` cannot lower' "$output_directory/err" > /dev/null; then
        echo "backend unsupported stops ($mode): expected status 1 and the diagnostic, got $status" >&2
        cat "$output_directory/err" >&2
        exit 1
    fi
done
echo "backend unsupported stops: ok"
