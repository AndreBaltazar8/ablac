#!/usr/bin/env bash
# The manifest and lock readers against BurntSushi/toml (#1139 area 2, round 2): tools/fuzz/manifest/run.sh [COMPILER] [COUNT] [SEED]
# Builds readers.ab (the compiler's own readers on generated abla.toml and abla.lock files) and manifestdiff (the generator and the TOML reference, Go, needs the module
# BurntSushi/toml v1.4.0 from go.sum) and prints, per reader, the ghost (the reader sees what TOML does not), different, missed and taken differences with one minimal file each.
set -euo pipefail
compiler=${1:-build/ablac}
count=${2:-3000}
seed=${3:-1}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$root"
command -v go > /dev/null || { echo "manifest diff: no go; skipped"; exit 0; }
out=build/manifest-diff
mkdir -p "$out"
"$compiler" build tools/fuzz/manifest/readers.ab -o "$out/readers" --fast --no-cache
(cd tools/fuzz/manifest && go build -o "$root/$out/manifestdiff" .)
"$out/manifestdiff" -readers "$out/readers" -dir "$out/cases" -count "$count" -seed "$seed" -examples 1
