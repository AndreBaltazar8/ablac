#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
source_file=${2:-src/orc_main.ab}
output_directory=${3:-build/benchmark}

mkdir -p "$output_directory"
executable="$output_directory/selfhost"

start_ns=$(date +%s%N)
"$compiler" build "$source_file" -o "$executable" --no-cache
end_ns=$(date +%s%N)

elapsed_ms=$(((end_ns - start_ns) / 1000000))
bytes=$(stat -c %s "$executable")
printf 'self-hosted compiler rebuild: %d ms\n' "$elapsed_ms"
printf 'compiler size: %s bytes\n' "$bytes"
