#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-"$project_root/build/ablac"}
output_directory="$project_root/build/native-library-test"

mkdir -p "$output_directory"
"$compiler" build --project \
    "$project_root/tests/cases/native-library-project" \
    -o "$output_directory/valid" --no-cache
set +e
"$output_directory/valid"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'manifest native-library probe returned %s, expected 42\n' \
        "$status" >&2
    exit 1
fi
llvm-readelf -d "$output_directory/valid" |
    rg -q 'Shared library: \[libssl'

if "$compiler" build --project \
    "$project_root/tests/cases/native-library-invalid" \
    -o "$output_directory/invalid" --no-cache \
    >"$output_directory/invalid.log" 2>&1; then
    printf '%s\n' 'invalid nativeLibraries manifest unexpectedly built' >&2
    exit 1
fi
rg -q 'error\[E_NATIVE_LIBRARY_MANIFEST\]' \
    "$output_directory/invalid.log"

for invalid_project in native-library-malformed native-library-duplicate; do
    if "$compiler" build --project \
        "$project_root/tests/cases/$invalid_project" \
        -o "$output_directory/$invalid_project" --no-cache \
        >"$output_directory/$invalid_project.log" 2>&1; then
        printf '%s unexpectedly built\n' "$invalid_project" >&2
        exit 1
    fi
    rg -q 'error\[E_NATIVE_LIBRARY_MANIFEST\]' \
        "$output_directory/$invalid_project.log"
done

printf '%s\n' \
    'manifest native libraries: linked dependency and rejected unsafe, malformed, and duplicate declarations'
