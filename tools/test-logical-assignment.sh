#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
out=build/logical-assignment
cases=tests/cases/logical-assignment
mkdir -p "$out"
for tier in interp jit; do
    for fixture in locals field; do
        exe="$out/$fixture-$tier"
        ABLA_COMPILE_EVAL=$tier "$compiler" build "$cases/$fixture.ab" --no-cache -o "$exe"
        "$exe"
        echo "logical assignment: $fixture ($tier and runtime)"
    done
done
reject() {
    local fixture=$1 diagnostic=$2
    if "$compiler" build "$cases/$fixture.ab" --no-cache -o "$out/$fixture" > "$out/$fixture.log" 2>&1; then
        echo "logical assignment: $fixture compiled unexpectedly" >&2
        return 1
    fi
    grep -F "$diagnostic" "$out/$fixture.log"
}
reject target-type 'logical.assignment.bool'
reject rhs-type 'logical.assignment.bool'
reject field-type 'logical.assignment.bool'
reject field-rhs-type 'logical.assignment.bool'
reject index 'E_PARSE_LOGICAL_ASSIGNMENT_TARGET'
reject global 'logical.assignment.target'
