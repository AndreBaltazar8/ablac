#!/usr/bin/env bash
# A compiler.transform changes the bodies, annotations and extension fields of
# any module's declarations, its own, another of the program's or the standard
# library's (with the `transform.library` capability): a change to another
# module is an edit the module graph applies.
# Two different bodies for one function conflict; the runtime's functions are
# never changed (E_COMPILER_TRANSFORM_RUNTIME).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/transform-targets"
output_directory="$project_root/build/transform-targets"
mkdir -p "$output_directory"

runs() { # $1 = case, $2 = the exit status its program must have, then build flags
    "$compiler" build "$cases/$1.ab" -o "$output_directory/$1" --no-cache "${@:3}"
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
runs private 42
# Under strict imports too: a body reads names as its own module does.
runs module 42 --strict-imports
runs private 42 --strict-imports

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
refused stdlib-ungranted E_COMPILE_NATIVE_DENIED
grep -qF '`transform.library`' "$output_directory/stdlib-ungranted.err" ||
    { echo "transform targets: stdlib-ungranted doesn't name transform.library"; exit 1; }
grep -q 'conflict-a.ab' "$output_directory/conflict.err" &&
    grep -q 'conflict-b.ab' "$output_directory/conflict.err" ||
    { echo "transform targets: the conflict doesn't name both transforms"; cat "$output_directory/conflict.err"; exit 1; }
echo "transform targets: own, other modules' (private ones too, strict imports too) and the standard library's bodies, annotations and fields changed; conflicts and the runtime refused"
