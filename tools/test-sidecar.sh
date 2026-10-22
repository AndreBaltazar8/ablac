#!/usr/bin/env bash
# A hosted release executable's relocatable object sidecar (`<output>.o`) is built
# only on request: a default build writes none, `--sidecar` (or ABLA_SIDECAR=1)
# writes it, `--no-sidecar` declines it whatever the environment asks, and the
# executable is byte-identical either way.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/sidecar-test"
rm -rf "$output_directory"
mkdir -p "$output_directory"
source="$project_root/tests/cases/build-removed-outputs/hosted.ab"
program="$output_directory/program"

fail() {
    echo "sidecar: $1" >&2
    exit 1
}

"$compiler" build "$source" -o "$program" --no-cache
[[ ! -e $program.o ]] || fail "a default release build wrote $program.o"
cp "$program" "$output_directory/default"

"$compiler" build "$source" -o "$program" --no-cache --sidecar
[[ -s $program.o ]] || fail "--sidecar wrote no $program.o"
cmp -s "$program" "$output_directory/default" ||
    fail "the executable differs with the sidecar"

rm -f "$program.o"
ABLA_SIDECAR=1 "$compiler" build "$source" -o "$program" --no-cache
[[ -s $program.o ]] || fail "ABLA_SIDECAR=1 wrote no $program.o"

ABLA_SIDECAR=1 "$compiler" build "$source" -o "$program" --no-cache --no-sidecar
[[ ! -e $program.o ]] || fail "--no-sidecar kept $program.o"
cmp -s "$program" "$output_directory/default" ||
    fail "the executable differs without the sidecar"

echo "sidecar: built only on request (--sidecar, ABLA_SIDECAR=1); the executable is the same either way"
