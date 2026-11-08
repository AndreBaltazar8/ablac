#!/usr/bin/env bash
# `x == null` / `x != null` on a nullable value read its tag inline: the results are right
# (fast and release builds, and under `#`), and the release IR has the inline check and no
# call of the generic equality for it.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/null-compare"
mkdir -p "$output_directory"
source="$project_root/tests/cases/null-compare/main.ab"

for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build "$source" -o "$output_directory/program" $mode --no-cache
    set +e
    "$output_directory/program"
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "null-compare: status $status (mode '$mode')" >&2; exit 1; }
done

# A kept IR text of the release build: the tag test is there, and no `abla_not_equal` or
# `abla_equal` call remains in `report` (the function that compares).
ABLA_KEEP_LLVM_TEXT=1 "$compiler" build "$source" -o "$output_directory/kept" --no-cache
grep -q 'scalar.is.null' "$output_directory/kept.ll" ||
    { echo "null-compare: no inline null test in the IR" >&2; exit 1; }
if grep -E 'call .*@abla_(not_)?equal\(' "$output_directory/kept.ll" > "$output_directory/generic.txt"; then
    echo "null-compare: a generic equality call remains:" >&2
    head -3 "$output_directory/generic.txt" >&2
    exit 1
fi
echo "null compare: inline tag test, results right natively and under #"
