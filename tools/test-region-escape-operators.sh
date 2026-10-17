#!/usr/bin/env bash
# A value an operator computes inside a region (a string concatenation, an
# overloaded operator's object, a `when` branch) lives in the region: storing it
# in an outer variable is region.escape. Using it inside the region is fine.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/region-escape-operators"
mkdir -p "$output_directory"

reject() {
    set +e
    diagnostics=$("$compiler" build "$project_root/tests/cases/modules/$1.ab" \
        -o "$output_directory/$1" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 && $diagnostics == *"region.escape:assignment.saved"* ]] ||
        { echo "$1: expected region.escape:assignment.saved"; echo "$diagnostics"; exit 1; }
}

reject region-escape-concatenation
reject region-escape-operator-object
reject region-escape-when
"$compiler" build "$project_root/tests/cases/modules/region-concatenation-inside.ab" \
    -o "$output_directory/inside" --no-cache
[[ $("$output_directory/inside") == "6 0 50" ]] || exit 1
echo "region escape: operator results stay in their region"
