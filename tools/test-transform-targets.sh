#!/usr/bin/env bash
# A compiler.transform replaces the bodies of its own module's functions and
# annotates any module's. A request it can't carry out is refused when it is
# made, never reported done and dropped: the runtime's functions
# (E_COMPILER_TRANSFORM_RUNTIME), and for now another module's body, of the
# standard library (E_COMPILER_TRANSFORM_STDLIB) or the program
# (E_COMPILER_TRANSFORM_MODULE).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/transform-targets"
output_directory="$project_root/build/transform-targets"
mkdir -p "$output_directory"

"$compiler" build "$cases/own.ab" -o "$output_directory/own" --no-cache
set +e
"$output_directory/own"
status=$?
set -e
[[ $status == 42 ]] || { echo "transform targets: own module's change not applied ($status)"; exit 1; }
"$compiler" build "$cases/annotation.ab" -o "$output_directory/annotation" --no-cache
set +e
"$output_directory/annotation"
status=$?
set -e
[[ $status == 2 ]] || { echo "transform targets: annotated program exited with $status"; exit 1; }

refused() { # $1 = case, $2 = the diagnostic it must report
    if "$compiler" build "$cases/$1.ab" -o "$output_directory/$1" --no-cache \
        > "$output_directory/$1.err" 2>&1; then
        echo "transform targets: $1 compiled"; exit 1
    fi
    grep -qF "error[$2]" "$output_directory/$1.err" ||
        { echo "transform targets: $1 lacks $2"; cat "$output_directory/$1.err"; exit 1; }
}
refused runtime E_COMPILER_TRANSFORM_RUNTIME
refused stdlib E_COMPILER_TRANSFORM_STDLIB
refused module E_COMPILER_TRANSFORM_MODULE
refused annotation-runtime E_COMPILER_TRANSFORM_RUNTIME
echo "transform targets: own module's bodies and any module's annotations changed; runtime, other modules' bodies refused"
