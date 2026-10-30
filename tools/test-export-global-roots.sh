#!/usr/bin/env bash
# Globals of a library entered only through exports (never `main`) survive
# garbage collection: the export initializer publishes them as roots.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory=$project_root/build/export-global-roots
cases=$project_root/tests/cases/export-global-roots
mkdir -p "$output_directory"

library=$output_directory/libroots.so
if [[ $(uname -s) == Darwin ]]; then library=$output_directory/libroots.dylib; fi
"$compiler" build "$cases/library.ab" --emit shared-library -o "$library" --no-cache
clang "$cases/caller.c" -L"$output_directory" -lroots \
    -Wl,-rpath,"$output_directory" -o "$output_directory/caller"
ABLA_MAX_MEMORY_MB=256 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" "$output_directory/caller"
