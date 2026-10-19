#!/usr/bin/env bash
# Globals named like the standard library's parameters and locals don't reach
# into the library (abla/unsafe/memory, abla/io, abla/json) or the program's
# own locals, nor a body's result once its scope is left, nor a default's lambda
# parameter; a thread body's inner local doesn't hide the global after it.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/global-names"
output_directory="$project_root/build/global-names"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program" >"$output_directory/program.out"
status=$?
set -e
[[ $status -eq 42 ]] || { echo "global names: expected 42, got $status" >&2; cat "$output_directory/program.out" >&2; exit 1; }
expected='{"value":[1,2,3],"text":"local","count":7}
global text 7 11 global key 3 1 18'
[[ "$(cat "$output_directory/program.out")" == "$expected" ]] ||
    { echo "global names: unexpected output" >&2; cat "$output_directory/program.out" >&2; exit 1; }

expect_error() { # <case> <diagnostic>
    if "$compiler" build "$cases/$1.ab" -o "$output_directory/$1" --no-cache \
        >"$output_directory/$1.log" 2>&1; then
        echo "global names: $1 built" >&2; exit 1
    fi
    grep -q "$2" "$output_directory/$1.log" ||
        { echo "global names: $1 did not report $2" >&2; cat "$output_directory/$1.log" >&2; exit 1; }
}
expect_error thread-global 'thread.mutable-global'
echo "global names: globals named like library parameters stay out of its locals and the program's"
