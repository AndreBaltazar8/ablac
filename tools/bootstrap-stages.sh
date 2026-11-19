#!/usr/bin/env bash
# The bootstrap check of a tree: stage 1 is the compiler built by <bootstrap> from src/orc_main.ab, stage 2 the
# compiler stage 1 builds, and stage 2 must emit for its own source exactly what stage 1 emitted, or the compiler is
# not a fixed point. Prints `stage2 == stage3` only when that holds, else fails.
#
#   tools/bootstrap-stages.sh <bootstrap-compiler> <directory> [--full]
#
# By default stage 3 is only the compiler run: stage 2 is built keeping the bitcode its compiler handed opt
# (ABLA_COMPILER_BITCODE), stage 2 then emits that bitcode again and stops (ABLA_COMPILER_BITCODE_ONLY=1), and the two
# are compared byte for byte. Equal bitcode gives the same executable because opt and code generation are
# deterministic, which tools/test-reproducible-build.sh checks on its own; they are 43 of a stage's 54 s.
# --full builds stage 3 whole and compares the executables as well (the release gate's mode).
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 || ( $# -eq 3 && $3 != --full ) ]]; then
    printf 'usage: %s <bootstrap-compiler> <directory> [--full]\n' "$0" >&2
    exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bootstrap=$(realpath -- "$1")
directory=$(realpath -m -- "$2")
full=${3:-}
cd "$project_root"
mkdir -p -- "$directory"
rm -f -- "$directory/stage2.bc" "$directory/stage3.bc" "$directory/stage3"
TIMEFORMAT='%R s'

stage() { # stage <compiler> <output> [environment...]
    local compiler=$1 output=$2
    shift 2
    echo "bootstrap-stages: $(basename -- "$output") from $(basename -- "$compiler")"
    time env "$@" tools/build-self-hosted-release.sh "$compiler" "$output" src/orc_main.ab
}

stage "$bootstrap" "$directory/stage1"
stage "$directory/stage1" "$directory/stage2" ABLA_COMPILER_BITCODE="$directory/stage2.bc"
if [[ $full == --full ]]; then
    stage "$directory/stage2" "$directory/stage3" ABLA_COMPILER_BITCODE="$directory/stage3.bc"
else
    stage "$directory/stage2" "$directory/stage3" \
        ABLA_COMPILER_BITCODE="$directory/stage3.bc" ABLA_COMPILER_BITCODE_ONLY=1
fi

for bitcode in stage2.bc stage3.bc; do
    if [[ ! -s $directory/$bitcode ]]; then
        echo "bootstrap-stages: no $bitcode: the build kept no compiler bitcode" >&2
        exit 1
    fi
done
if ! cmp -- "$directory/stage2.bc" "$directory/stage3.bc"; then
    echo "bootstrap-stages: stage 2 emits other bitcode for its own source than stage 1 did" >&2
    exit 1
fi
if [[ $full == --full ]] && ! cmp -- "$directory/stage2" "$directory/stage3"; then
    echo "bootstrap-stages: the bitcode is the same but the executables differ: opt or code generation is not deterministic" >&2
    exit 1
fi
if [[ $full == --full ]]; then
    echo 'stage2 == stage3'
else
    echo 'stage2 == stage3 (stage 2 emits the bitcode it was built from; stage 3 not built)'
fi
