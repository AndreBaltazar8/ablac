#!/usr/bin/env bash
# A compiler.transform changes the bodies, annotations and extension fields of
# any module's declarations, its own, another of the program's or the standard
# library's: a change to another module is an edit the module graph applies.
# Two different bodies for one function conflict; the runtime's functions are
# never changed (E_COMPILER_TRANSFORM_RUNTIME).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/transform-targets"
output_directory="$project_root/build/transform-targets"
mkdir -p "$output_directory"

runs() { # $1 = case, $2 = the exit status its program must have
    "$compiler" build "$cases/$1.ab" -o "$output_directory/$1" --no-cache
    set +e
    "$output_directory/$1"
    local status=$?
    set -e
    [[ $status == "$2" ]] || { echo "transform targets: $1 exited with $status, expected $2"; exit 1; }
}
runs own 42
runs annotation 2
runs module 42
runs stdlib 42
runs field 42
runs agree 42
runs sees 42

refused() { # $1 = case, $2 = the diagnostic it must report
    if "$compiler" build "$cases/$1.ab" -o "$output_directory/$1" --no-cache \
        > "$output_directory/$1.err" 2>&1; then
        echo "transform targets: $1 compiled"; exit 1
    fi
    grep -qF "error[$2]" "$output_directory/$1.err" ||
        { echo "transform targets: $1 lacks $2"; cat "$output_directory/$1.err"; exit 1; }
}
refused runtime E_COMPILER_TRANSFORM_RUNTIME
refused annotation-runtime E_COMPILER_TRANSFORM_RUNTIME
refused conflict E_COMPILER_EDIT_CONFLICT
grep -q 'conflict-a.ab' "$output_directory/conflict.err" &&
    grep -q 'conflict-b.ab' "$output_directory/conflict.err" ||
    { echo "transform targets: the conflict doesn't name both transforms"; cat "$output_directory/conflict.err"; exit 1; }
echo "transform targets: own, other modules' and the standard library's bodies, annotations and fields changed; conflicts and the runtime refused"
