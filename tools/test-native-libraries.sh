#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-"$project_root/build/ablac"}
output_directory="$project_root/build/native-library-test"
fixture="$project_root/tests/cases/native-library-project"
host=$(uname -s)

mkdir -p "$output_directory"
if [[ $host == Darwin ]]; then
    library="$output_directory/libabla_native_probe.dylib"
    clang -dynamiclib -install_name "$library" "$fixture/probe.c" -o "$library"
else
    library="$output_directory/libabla_native_probe.so"
    clang -shared -fPIC "$fixture/probe.c" -o "$library"
fi
LIBRARY_PATH="$output_directory${LIBRARY_PATH:+:$LIBRARY_PATH}" \
    "$compiler" build --project "$fixture" -o "$output_directory/valid" --no-cache

status=0
if [[ $host == Darwin ]]; then
    "$output_directory/valid" || status=$?
else
    LD_LIBRARY_PATH="$output_directory${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$output_directory/valid" || status=$?
fi
if [[ $status -ne 42 ]]; then
    printf 'manifest native-library probe returned %s, expected 42\n' \
        "$status" >&2
    exit 1
fi
if [[ $host == Darwin ]]; then
    otool -L "$output_directory/valid" | rg -F "$library" >/dev/null
else
    llvm-readelf -d "$output_directory/valid" |
        rg -F 'Shared library: [libabla_native_probe.so]' >/dev/null
fi

if "$compiler" build --project \
    "$project_root/tests/cases/native-library-invalid" \
    -o "$output_directory/invalid" \
    >"$output_directory/invalid.log" 2>&1; then
    printf '%s\n' 'invalid nativeLibraries manifest unexpectedly built' >&2
    exit 1
fi
rg -q 'error\[E_NATIVE_LIBRARY_MANIFEST\]' \
    "$output_directory/invalid.log"

for invalid_project in native-library-malformed native-library-duplicate; do
    if "$compiler" build --project \
        "$project_root/tests/cases/$invalid_project" \
        -o "$output_directory/$invalid_project" \
        >"$output_directory/$invalid_project.log" 2>&1; then
        printf '%s unexpectedly built\n' "$invalid_project" >&2
        exit 1
    fi
    # A manifest the grammar of src/manifest_grammar.ab refuses (the unterminated list) never reaches the native library reader: E_PACKAGE_MANIFEST names its line.
    rg -q 'error\[E_(NATIVE_LIBRARY|PACKAGE)_MANIFEST\]' \
        "$output_directory/$invalid_project.log"
done

printf '%s\n' \
    'manifest native libraries: linked dependency and rejected unsafe, malformed, and duplicate declarations'
