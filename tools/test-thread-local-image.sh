#!/usr/bin/env bash
# Initialized thread-locals in x86-64 Linux executables linked without libc (#829): abla_tls_init must copy the .tdata
# image to tp - roundup(p_memsz, p_align), where the linker addressed it (since v0.2.57 it copied it to the block's start,
# and a site's initial bytes read as zeros whenever the 64-byte rounding of the thread pointer differed). Each program
# must link without libc (no PT_INTERP), and exit 42: tests/cases/thread-local-image (three written sites, the main
# thread and a new one) and tests/cases/modules/thread-local-bytes.ab.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/thread-local-image"
rm -rf "$output_directory"
mkdir -p "$output_directory"

case $(uname -sm) in
    "Linux x86_64") ;;
    *) echo "thread-local image: not x86-64 Linux, skipped"; exit 0 ;;
esac

for program in "tests/cases/thread-local-image/main.ab" "tests/cases/modules/thread-local-bytes.ab"; do
    name=$(basename "$(dirname "$program")")-$(basename "$program" .ab)
    for mode in release fast; do
        flags=()
        [[ $mode == release ]] || flags=(--fast)
        "$compiler" build "$project_root/$program" -o "$output_directory/$name-$mode" --no-cache "${flags[@]}" \
            > "$output_directory/$name-$mode.log" 2>&1 ||
            { echo "thread-local image: $program ($mode) did not build" >&2; cat "$output_directory/$name-$mode.log" >&2; exit 1; }
        if readelf -lW "$output_directory/$name-$mode" | grep -q INTERP; then
            echo "thread-local image: $program ($mode) linked libc; the libc-free start is what this tests" >&2; exit 1
        fi
        status=0
        "$project_root/tools/run-limited.sh" "$output_directory/$name-$mode" || status=$?
        [[ $status == 42 ]] ||
            { echo "thread-local image: $program ($mode) exited $status, not 42" >&2; exit 1; }
    done
done
echo "thread-local image: initialized thread-locals read their initial bytes on every thread, release and --fast"
