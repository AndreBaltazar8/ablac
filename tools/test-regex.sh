#!/usr/bin/env bash
# abla/regex: unit and pathological-pattern cases in fast and release builds,
# the release build again under GC stress, and 6000 pattern and text pairs
# checked against recorded results of Python's re (tests/cases/regex/corpus.tsv.gz).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/regex"
mkdir -p "$out"
cd "$root"
for mode in --fast release; do
    options=()
    [[ $mode == release ]] || options+=(--fast)
    "$compiler" build "$root/tests/cases/regex/main.ab" -o "$out/main-$mode" --no-cache "${options[@]}"
    # The pathological patterns must finish quickly: that is linear time.
    timeout 60 "$out/main-$mode" | grep -x ok >/dev/null
done
ABLA_GC_STRESS=1 timeout 300 "$out/main-release" | grep -x ok >/dev/null
"$compiler" build "$root/tests/cases/regex/corpus.ab" -o "$out/corpus" --no-cache --fast
zcat "$root/tests/cases/regex/corpus.tsv.gz" >"$out/corpus.tsv"
timeout 300 "$out/corpus" "$out/corpus.tsv"
echo "regex: ok"
