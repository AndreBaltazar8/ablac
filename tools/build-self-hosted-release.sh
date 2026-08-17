#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'usage: %s <compiler> <output> [entry]\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
output=$2
entry=${3:-src/orc_main.ab}
build_memory_mb=${ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB:-4096}
build_seconds=${ABLA_RELEASE_SELFHOST_BUILD_SECONDS:-600}
host_os=$(uname -s)

cd "$project_root"
export ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root}
mkdir -p -- "$(dirname -- "$output")"

printf -v build_command \
    '%q build %q -o %q --no-cache' \
    "$compiler" "$entry" "$output"

# A self-hosted compiler is built through the same LLVM-native path as every
# other Abla executable. The runtime sources are part of that LLVM module; no
# separately compiled runtime object, header, shim, or adapter exists.
if [[ $host_os == Darwin ]]; then
    ABLA_MAX_MEMORY_MB=$build_memory_mb ABLA_MAX_SECONDS=$build_seconds \
        "$project_root/tools/run-limited.sh" /bin/bash -c "$build_command"
else
    ABLA_MAX_MEMORY_MB=$build_memory_mb ABLA_MAX_SECONDS=$build_seconds \
        "$project_root/tools/run-limited.sh" \
        nix-shell "$project_root/shell.nix" --run "$build_command"
fi

[[ -x $output && -s $output.ll ]]
