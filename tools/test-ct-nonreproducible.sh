#!/usr/bin/env bash
# Non-reproducible `#` sites (decision #82 B, tests/cases/ct-nonreproducible): a site that can reach the clock gets a
# note and is listed in `<output>.abi.json` ("nonReproducible"); a pure site gets neither; a build that may use the
# cache prints the same notes as one that may not.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-nonreproducible
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-nonreproducible"
export ABLA_CACHE_DIR=$out/cache
fail() { echo "ct nonreproducible: $1" >&2; exit 1; }
notes() { grep 'non-reproducible' "$1" || true; }
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build pure.ab -o "$out/pure-$mode" --fast --no-cache > "$out/pure-$mode.log" 2>&1 ||
        { cat "$out/pure-$mode.log" >&2; fail "$mode: pure.ab did not build"; }
    [[ -z $(notes "$out/pure-$mode.log") ]] || fail "$mode: pure.ab got a note: $(notes "$out/pure-$mode.log")"
    ! grep -q nonReproducible "$out/pure-$mode.abi.json" || fail "$mode: pure.ab's manifest lists a site"

    ABLA_COMPILE_EVAL=$mode "$compiler" build clock.ab -o "$out/clock-$mode" --fast --no-cache > "$out/clock-$mode.log" 2>&1 ||
        { cat "$out/clock-$mode.log" >&2; fail "$mode: clock.ab did not build"; }
    expected='note: non-reproducible: clock.ab:7 `#(compilerClockMilliseconds() > 0)` reached clock'
    [[ $(notes "$out/clock-$mode.log") == "$expected" ]] ||
        fail "$mode: clock.ab's notes are '$(notes "$out/clock-$mode.log")', not '$expected'"
    grep -q '"site":"clock.ab:7","expression":"#(compilerClockMilliseconds() > 0)","capabilities":\["clock"\]' \
        "$out/clock-$mode.abi.json" || { cat "$out/clock-$mode.abi.json" >&2; fail "$mode: clock.ab's manifest lacks its site"; }
    "$out/clock-$mode" && status=0 || status=$?
    [[ $status == 42 ]] || fail "$mode: clock.ab's program exited $status, not 42"

    # With the cache (twice: the second may be a hit), the same notes; pure.ab's second build stays silent.
    for round in 1 2; do
        ABLA_COMPILE_EVAL=$mode "$compiler" build clock.ab -o "$out/clock-$mode-cached" --fast > "$out/clock-$mode-cached-$round.log" 2>&1 ||
            { cat "$out/clock-$mode-cached-$round.log" >&2; fail "$mode: clock.ab did not build with the cache"; }
        [[ $(notes "$out/clock-$mode-cached-$round.log") == "$expected" ]] ||
            fail "$mode: clock.ab with the cache (round $round): '$(notes "$out/clock-$mode-cached-$round.log")'"
        ABLA_COMPILE_EVAL=$mode "$compiler" build pure.ab -o "$out/pure-$mode-cached" --fast > "$out/pure-$mode-cached-$round.log" 2>&1 ||
            { cat "$out/pure-$mode-cached-$round.log" >&2; fail "$mode: pure.ab did not build with the cache"; }
        [[ -z $(notes "$out/pure-$mode-cached-$round.log") ]] || fail "$mode: pure.ab with the cache got a note"
    done
    echo "ok   $mode"
done
echo "ct nonreproducible: a clock site is noted and listed in the manifest, a pure one isn't, cached or not"
