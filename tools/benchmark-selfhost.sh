#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/bootstrap/ablac2}
source_file=${2:-bootstrap/compiler/main.ab}
output_directory=${3:-build/benchmark}
c_compiler=${CC:-cc}

mkdir -p "$output_directory"
generated="$output_directory/selfhost.c"
executable="$output_directory/selfhost"

start_emit=$(date +%s%N)
"$compiler" "$source_file" > "$generated"
end_emit=$(date +%s%N)

start_native=$(date +%s%N)
"$c_compiler" \
    -std=c11 -O2 -Iruntime \
    "$generated" runtime/abla_runtime.c runtime/abla_runtime_host.c \
    -o "$executable"
end_native=$(date +%s%N)

emit_ms=$(((end_emit - start_emit) / 1000000))
native_ms=$(((end_native - start_native) / 1000000))
total_ms=$(((end_native - start_emit) / 1000000))

printf 'selfhost emit:   %d ms\n' "$emit_ms"
printf 'native build:   %d ms\n' "$native_ms"
printf 'source-to-bin:  %d ms\n' "$total_ms"
