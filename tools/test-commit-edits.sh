#!/usr/bin/env bash
# `#` sites change the program (compiler.replaceFunctionBody,
# compiler.addFunctionAnnotation): each round of lowering commits their edits
# and lowers again, until a round changes nothing; a program that never
# settles stops after 8 rounds with compile.edit-fixpoint. Both tiers.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/commit-edits"
output_directory="$project_root/build/commit-edits"
mkdir -p "$output_directory"

for mode in interp jit; do
    for name in specialize rounds; do
        ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/$name.ab" \
            -o "$output_directory/$name-$mode" --no-cache
        set +e
        "$output_directory/$name-$mode"
        status=$?
        set -e
        [[ $status == 42 ]] || { echo "commit edits: $name under $mode exited $status"; exit 1; }
    done
    if ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/fixpoint.ab" \
        -o "$output_directory/fixpoint-$mode" --no-cache > "$output_directory/fixpoint-$mode.err" 2>&1; then
        echo "commit edits: fixpoint compiled under $mode"; exit 1
    fi
    grep -q '^error\[E_COMPILE_EDIT_FIXPOINT\]: compile.edit-fixpoint: .*8 rounds' "$output_directory/fixpoint-$mode.err" &&
        grep -q 'annotate `.*fixpoint.ab:tagged` (round 8: [^)]*commit-edits/fixpoint.ab:[0-9]*:[0-9]*)' "$output_directory/fixpoint-$mode.err" ||
        { echo "commit edits: fixpoint under $mode"; cat "$output_directory/fixpoint-$mode.err"; exit 1; }
done
echo "commit edits: # sites' edits committed in rounds, settled or stopped at 8 (interp, jit)"
