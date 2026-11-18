#!/usr/bin/env bash
# A resource class that nothing constructs, named only as an element or field type, has a drop function
# built for the value that holds it; that function must not call a `drop` method the build did not keep
# (E_LLVM_INSTRUCTION_UNSUPPORTED "cannot lower result `call` target X_drop"). Both build modes.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/resource-unconstructed-drop"
rm -rf "$output_directory"
mkdir -p "$output_directory"

for mode in "" "--fast"; do
    # shellcheck disable=SC2086
    "$compiler" build "$project_root/tests/cases/resource-unconstructed-drop/main.ab" $mode \
        -o "$output_directory/main"
    set +e
    "$project_root/tools/run-limited.sh" "$output_directory/main"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        echo "resource unconstructed drop ($mode): expected 42, got $status" >&2
        exit 1
    fi
done
echo "resource unconstructed drop: ok"
