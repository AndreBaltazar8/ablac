#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}
output_directory="$project_root/build/compile-effect-path"
mkdir -p "$output_directory"
"$compiler" build "$project_root/tests/cases/compiler/compile-effect-path.ab" \
    -o "$output_directory/regression" --fast --no-cache
set +e
ABLA_MAX_SECONDS=5 ABLA_MAX_MEMORY_MB=256 \
    "$project_root/tools/run-limited.sh" "$output_directory/regression"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'compile-effect graph regression returned %s, expected 42\n' "$status" >&2
    exit 1
fi
for kind in filesystem environment network write clock; do
    set +e
    ABLA_MAX_SECONDS=30 "$project_root/tools/run-limited.sh" "$compiler" \
        build "$project_root/tests/cases/bootstrap/invalid-compile-effect-$kind.ab" \
        -o "$output_directory/denied" --fast --no-cache \
        > "$output_directory/$kind.log" 2>&1
    status=$?
    set -e
    if [[ $status -eq 0 || $status -eq 124 ]]; then
        printf 'expected bounded compile-effect rejection: %s (status %s)\n' "$kind" "$status" >&2
        exit 1
    fi
    rg -q 'compile.effect-denied:' "$output_directory/$kind.log"
done
printf '%s\n' 'compile-effect paths: recursive graph bounded, real effect paths and denial checks preserved'
