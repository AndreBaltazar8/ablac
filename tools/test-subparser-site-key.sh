#!/usr/bin/env bash
# parserSiteKey(cursor) names a `$name` site after the method, function or
# global that holds it and its offset there, so what a subparser names after
# its site doesn't move when a line or an import is added above the
# declaration: the program built from the same files with lines added atop
# each is the same program, byte for byte, with the same keys.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/subparser-site-key"
output_directory="$project_root/build/subparser-site-key"
rm -rf "$output_directory"
mkdir -p "$output_directory/case"

fail() {
    echo "subparser site key: $1" >&2
    exit 1
}

expected='atTop_20 first_22 second_41 second_61 Holder_inMethod_25'
# Both builds read the files at the same paths: a module's path is part of
# some names, which this test isn't about.
cp "$cases"/*.ab "$output_directory/case/"
for build in plain shifted; do
    if [[ $build == shifted ]]; then
        for file in "$output_directory"/case/*.ab; do
            { printf '\n// a line above every declaration\n'; cat "$file"; } > "$file.next"
            mv "$file.next" "$file"
        done
    fi
    # One file name: a signed executable's signature names it.
    mkdir -p "$output_directory/$build"
    "$compiler" build "$output_directory/case/main.ab" \
        -o "$output_directory/$build/main" --no-cache
    set +e
    output=$("$output_directory/$build/main")
    status=$?
    set -e
    [[ $status -eq 42 && $output == "$expected" ]] ||
        fail "$build: status $status, output: $output"
done
cmp -s "$output_directory/plain/main" "$output_directory/shifted/main" ||
    fail "the program changed with lines added above its declarations"
echo "subparser site key: keys from the holding declaration; lines above change nothing"
