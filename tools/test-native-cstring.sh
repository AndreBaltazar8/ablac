#!/usr/bin/env bash
# A native string copied by nativeCString, and every string made from it,
# keeps its text after the native memory is overwritten and released, at run
# time and in `#` code (both tiers); a borrowed one, and a template of it,
# read the native memory as it is now.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$project_root/$compiler"
case_directory="$project_root/tests/cases/native-cstring"
output_directory="$project_root/build/native-cstring"
mkdir -p "$output_directory"

export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
for mode in interp jit; do
    program="$output_directory/main-$mode"
    (cd "$case_directory" && ABLA_COMPILE_EVAL=$mode "$compiler" build main.ab \
        -o "$program" --no-cache)
    set +e
    output=$("$program")
    status=$?
    set -e
    [[ $status == 42 && $output == "native-cstring 6 6 3" ]] ||
        { echo "native-cstring ($mode): exited $status, printed: $output" >&2; exit 1; }
done

echo "native-cstring: copies keep their text (run time, # in both tiers); borrows read in place"
