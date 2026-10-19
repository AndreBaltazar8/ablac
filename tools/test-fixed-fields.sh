#!/usr/bin/env bash
# A class instance's declared fields stay in its inline slots: a by-name store
# that would add a field panics (exit 101, naming the class and field by their
# symbols), and programs reading and writing fields give the same results when
# every safe point collects (ABLA_GC_STRESS=1).
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/fixed-fields"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/bootstrap/fixed-fields.ab" \
    -o "$output_directory/grow" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/grow" \
    > "$output_directory/grow.out" 2> "$output_directory/grow.err"
status=$?
set -e
[[ $status -eq 101 ]] || { echo "fixed fields: growing a class instance exited $status, expected 101" >&2; exit 1; }
grep -q "panic: cannot add field #12345 to an instance of class #[0-9-]*: a class's fields are fixed" \
    "$output_directory/grow.err" || { cat "$output_directory/grow.err" >&2; exit 1; }

run() { # program [environment...]
    local program=$1 status
    shift
    set +e
    env "$@" ABLA_MAX_SECONDS=120 "$project_root/tools/run-limited.sh" "$program" 2>&1
    status=$?
    set -e
    echo "status $status"
}
cases=(
    modules/classes modules/resource-drop modules/resource-structural-drop
    modules/map-resources modules/array-resource-drop-order
    field-places/main field-shadowing/main
)
for case in "${cases[@]}"; do
    name=${case//\//-}
    "$compiler" build "$project_root/tests/cases/$case.ab" \
        -o "$output_directory/$name" --no-cache > "$output_directory/$name.log" 2>&1 ||
        { cat "$output_directory/$name.log" >&2; exit 1; }
    normal=$(run "$output_directory/$name")
    stressed=$(run "$output_directory/$name" ABLA_GC_STRESS=1)
    [[ $normal == "$stressed" ]] || {
        echo "fixed fields: $case differs under ABLA_GC_STRESS=1: '$normal' vs '$stressed'" >&2
        exit 1
    }
done
echo "fixed fields: growing a class instance panics; field programs agree under collection stress"
