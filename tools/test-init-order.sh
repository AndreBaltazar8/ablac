#!/usr/bin/env bash
# Globals initialize in dependency order (through functions, methods, lambdas and
# other modules; the earliest declared first among those ready), and a cycle is
# global.initialization-cycle, at run time and under `#`.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/init-order"
output_directory="$project_root/build/init-order"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main" --no-cache
output=$("$output_directory/main")
expected='init second
init first
init third
init fifth
init fourth
init factor
init sixth
init seventh
init ninth
init eighth
2 1 1 12 11 7 3 44 7 6
42 21 42 21 42'
[[ $output == "$expected" ]] || { echo "init order: output:"; echo "$output"; exit 1; }

rejected() { # $1 = case, then the texts its diagnostics must contain
    local name=$1; shift
    if "$compiler" build "$cases/$name.ab" -o "$output_directory/invalid" \
        --no-cache > "$output_directory/$name.err" 2>&1; then
        echo "init order: $name compiled"; exit 1
    fi
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/$name.err" ||
            { echo "init order: $name lacks '$text'"; cat "$output_directory/$name.err"; exit 1; }
    done
}
rejected invalid-cycle 'global.initialization-cycle:a2->b2->a2@0' 'invalid-cycle.ab:0:1'
rejected invalid-through-functions 'global.initialization-cycle:total->total' \
    'global.initialization-cycle:selfish->selfish'
rejected invalid-modules 'global.initialization-cycle:qy->px->qy' 'cycle-q.ab:'
rejected invalid-compile-time 'global.initialization-cycle:a2->b2->a2'
if grep -q 'E_EVAL' "$output_directory/invalid-compile-time.err"; then
    echo "init order: the cycle was evaluated under #"; exit 1
fi
echo "init order: dependency order through functions and modules; cycles rejected"
