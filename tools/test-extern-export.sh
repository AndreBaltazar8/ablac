#!/usr/bin/env bash
# An extern:"c" declaration and an @export of the same symbol in one program are one function to the linker: their
# signatures (parameter count, parameter types, result) must agree, or the build fails naming both places. A match
# (a nominal scalar is its underlying type), an extern with no export, and an export nobody declares stay allowed.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cases=$project_root/tests/cases/extern-export
output_directory=$project_root/build/extern-export
rm -rf "$output_directory"
mkdir -p "$output_directory"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-2048}

runs() { # $1 = case, $2 = exit status
    "$compiler" build "$cases/$1.ab" -o "$output_directory/$1" --no-cache > "$output_directory/$1.err" 2>&1 ||
        { echo "extern-export: $1 didn't build"; cat "$output_directory/$1.err"; exit 1; }
    set +e
    "$output_directory/$1" > "$output_directory/$1.out"
    local status=$?
    set -e
    [[ $status == "$2" ]] || { echo "extern-export: $1 exited $status, not $2"; cat "$output_directory/$1.out"; exit 1; }
}
rejected() { # $1 = case, then the texts its diagnostics must contain
    local name=$1; shift
    if "$compiler" build "$cases/$name.ab" -o "$output_directory/$name" --no-cache > "$output_directory/$name.err" 2>&1; then
        echo "extern-export: $name compiled"; exit 1
    fi
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/$name.err" ||
            { echo "extern-export: $name lacks '$text'"; cat "$output_directory/$name.err"; exit 1; }
    done
    [[ $(grep -c 'extern.export-mismatch' "$output_directory/$name.err") == 1 ]] ||
        { echo "extern-export: $name should have one mismatch"; cat "$output_directory/$name.err"; exit 1; }
}

runs match 42
grep -qx '10 12 1' "$output_directory/match.out" || { echo "extern-export: match printed:"; cat "$output_directory/match.out"; exit 1; }
runs extern-only 5
runs bool 7
grep -qx "true false true" "$output_directory/bool.out" || { echo "extern-export: bool printed:"; cat "$output_directory/bool.out"; exit 1; }
rejected bad-parameter 'extern.export-mismatch:mockDelay@' ':parameter1:i32:i64:' "$cases/bad-parameter.ab"
rejected bad-count 'extern.export-mismatch:mockDelay@' ':parameters:2:1:' "$cases/bad-count.ab"
rejected bad-result 'extern.export-mismatch:mockDelay@' ':result:i32:i64:' "$cases/bad-result.ab"
# The program's own calls of its exported symbol are direct calls to the function, not calls of the exported alias (so they
# are inlined, and the argument ABI optimized, like any internal call); the C symbol itself is still exported.
"$compiler" --emit-llvm "$cases/match.ab" > "$output_directory/match.ll" 2> "$output_directory/match.ll.err" ||
    { echo "extern-export: match.ab did not emit LLVM"; cat "$output_directory/match.ll.err"; exit 1; }
grep -qE "^@mockDelay = alias" "$output_directory/match.ll" || { echo "extern-export: the exported symbol mockDelay is gone"; exit 1; }
if grep -qF "@mockDelay(" "$output_directory/match.ll"; then
    echo "extern-export: a call still goes through the exported alias @mockDelay"; exit 1
fi
echo "extern export: ok"
