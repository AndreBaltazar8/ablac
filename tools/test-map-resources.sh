#!/usr/bin/env bash
# A Map owns its affine values the way an array owns its elements: lent by
# `get`/`values`, moved out by `take`, dropped once when replaced, removed,
# cleared or left in the map, at run time and under `#`.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/map-resources"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/map-resources.ab" \
    -o "$output_directory/map-resources"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/map-resources"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "map resources: expected 42, got $status" >&2
    exit 1
fi

"$compiler" build "$project_root/tests/cases/modules/map-resource-drops.ab" \
    -o "$output_directory/map-resource-drops"
"$project_root/tools/run-limited.sh" "$output_directory/map-resource-drops" \
    > "$output_directory/map-resource-drops.out"
expected=$'drop 1\nreplaced\ndrop 2\nremoved\nend\ndrop 3'
if [[ $(cat "$output_directory/map-resource-drops.out") != "$expected" ]]; then
    echo "map resources: drops out of order or missing:" >&2
    cat "$output_directory/map-resource-drops.out" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/array-resource-drop-order.ab" \
    -o "$output_directory/array-drop-order"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/array-drop-order"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "map resources: array drop order differs at compile time ($status)" >&2
    exit 1
fi

check_rejected() {
    local fixture=$1
    local expected=$2
    local output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    local result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq -- "$expected" "$output.err"; then
        echo "map resources: $fixture was not rejected with $expected" >&2
        sed -n '1,40p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]] || exit 1
}

check_rejected invalid-map-get-move 'ownership.borrow-move:got'
check_rejected invalid-map-values-move 'move.local'
check_rejected invalid-map-get-after-set \
    'error[E_BORROW_CONFLICT]: in `main`, `tokens` is changed while `seen`'

echo "map resources: lent by get/values, moved by take, dropped once"
