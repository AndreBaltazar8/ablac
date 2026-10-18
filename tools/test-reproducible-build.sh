#!/usr/bin/env bash
# The same program built twice gives the same bytes: the executable and its
# object, in a --fast, a default and a release (--no-sidecar) build. The builds
# are a second apart, so nothing may depend on the time (on macOS the debug
# map's object times feed the image's UUID and code signature).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/reproducible-build"
mkdir -p "$output_directory"
source="$project_root/tests/cases/modules/collections.ab"

for mode in --fast default --no-sidecar; do
    flags=()
    [[ $mode == default ]] || flags=("$mode")
    for run in 1 2; do
        "$compiler" build "$source" -o "$output_directory/program" --no-cache \
            ${flags[@]+"${flags[@]}"} >"$output_directory/build.log" 2>&1 ||
            { cat "$output_directory/build.log" >&2; exit 1; }
        cp "$output_directory/program" "$output_directory/program-$run"
        if [[ -f $output_directory/program.o ]]; then
            cp "$output_directory/program.o" "$output_directory/program-$run.o"
        else
            rm -f "$output_directory/program-$run.o"
        fi
        [[ $run == 2 ]] || sleep 1
    done
    if ! cmp -s "$output_directory/program-1" "$output_directory/program-2"; then
        echo "reproducible build: two $mode builds differ" >&2
        cmp -l "$output_directory/program-1" "$output_directory/program-2" | head -5 >&2 || true
        exit 1
    fi
    if [[ -f $output_directory/program-1.o ]] &&
        ! cmp -s "$output_directory/program-1.o" "$output_directory/program-2.o"; then
        echo "reproducible build: two $mode builds' objects differ" >&2
        exit 1
    fi
done
echo "reproducible build: the same program builds to the same bytes"
