#!/usr/bin/env bash
# A module's declaration shadows a same-named declaration of a module it
# imports; the runtime's C externs are private. Two imported modules that
# declare the same name stay ambiguous.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/module-shadowing"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/shadow-imports.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-shadow-ambiguous.ab" \
    > "$output_directory/invalid.ll" 2> "$output_directory/invalid.err"
invalid=$?
set -e
[[ $status -eq 42 && $invalid -ne 0 ]] || exit 1
grep -q 'E_IMPORT_UNQUALIFIED_AMBIGUOUS' "$output_directory/invalid.err"
echo "module shadowing: own declarations shadow imports, runtime externs private"
