#!/usr/bin/env bash
# A field is one place however it is named (`this.items`, `items` in a method,
# `box.items`): moving a resource out of it needs `move`, and a view of it or
# of its elements is checked against changes to the field, as for a local.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases=$project_root/tests/cases/field-places
output_directory=$project_root/build/field-places
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program" > "$output_directory/program.out"
status=$?
set -e
expected=$'drop 1\n1 2 1 40 2'
if [[ $status -ne 42 || $(cat "$output_directory/program.out") != "$expected"* ]]; then
    echo "field places: expected 42 and the drops in order, got $status:" >&2
    cat "$output_directory/program.out" >&2
    exit 1
fi

check_rejected() {
    local fixture=$1
    local expected=$2
    local output="$output_directory/$fixture"
    rm -f "$output"
    if "$compiler" build "$cases/$fixture.ab" -o "$output" --no-cache \
        > "$output.log" 2>&1; then
        echo "field places: $fixture built" >&2
        exit 1
    fi
    if ! grep -Fq -- "$expected" "$output.log"; then
        echo "field places: $fixture was not rejected with $expected" >&2
        sed -n '1,30p' "$output.log" >&2
        exit 1
    fi
}

check_rejected invalid-method-field-copy 'ownership.place-move-required:local.view'
check_rejected invalid-method-field-move 'ownership.place-owner:this'
check_rejected invalid-method-field-return 'ownership.place-move-required:method.Booking.view'
check_rejected invalid-method-field-view \
    'in `Box_peek`, `this.items[0]` is changed while `view`'
check_rejected invalid-val-field-array 'in `main`, `box.items[0]` is changed while `view`'
check_rejected invalid-nested-field-array \
    'in `main`, `outer.box.items[0]` is changed while `view`'
check_rejected invalid-field-view-compile-time \
    'in `Box_peek`, `this.items[0]` is changed while `view`'

echo "field places: one place per field, however it is named"
