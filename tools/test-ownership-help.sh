#!/usr/bin/env bash
# An ownership diagnostic is followed by a `help:` line saying what it means
# and the usual fix.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/ownership-help"
mkdir -p "$output_directory"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-ownership-help.ab" \
    > "$output_directory/invalid.ll" 2> "$output_directory/invalid.err"
status=$?
set -e
[[ $status -ne 0 ]] || exit 1
grep -q 'ownership.borrow-mutation:append:values' "$output_directory/invalid.err"
grep -q '^help: .*declare the parameter `var`' "$output_directory/invalid.err"
echo "ownership help: diagnostics say what they mean and the usual fix"
