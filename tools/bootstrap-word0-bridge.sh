#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
compiler="$project_root/${1:-build/bootstrap-ablac}"
chain="$project_root/build/bootstrap-chain"
mkdir -p "$chain"
# These source snapshots teach the seed compound assignment and then array
# truncation before those features are used by the next compiler's own sources.
for revision in 069fb3662ccbd188fe06cb41d272711331424b1e da73843f44d86b5be28c7f1e74b8e35f604b5145; do
    source_root="$chain/$revision"
    mkdir -p "$source_root"
    git archive "$revision" | tar -x -C "$source_root"
    if [[ $revision == da73843* ]]; then
        (cd "$source_root" && patch -p1 < "$project_root/tools/bootstrap-array-compat.patch")
    fi
    output="$chain/$revision.compiler"
    printf -v command 'cd %q && ABLA_SYSROOT=%q %q build src/orc_main.ab -o %q --fast --no-cache' \
        "$source_root" "$source_root" "$compiler" "$output"
    if [[ $(uname -s) == Darwin ]]; then
        ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=600 tools/run-limited.sh /bin/bash -c "$command"
    else
        ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=600 tools/run-limited.sh nix-shell shell.nix --run "$command"
    fi
    compiler="$output"
done
cp "$compiler" build/bootstrap-bridge
chmod +x build/bootstrap-bridge
