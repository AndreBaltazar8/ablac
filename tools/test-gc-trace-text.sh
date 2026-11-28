#!/usr/bin/env bash
# ABLA_GC_TRACE=1 writes plain text: printable characters, tabs and newlines. Its lines are written as (text, length)
# pairs, and a length one past its message wrote the string's terminating NUL into the trace (" after, " 9, and the
# phases and adaptive lines), which made grep treat the trace as binary. tests/cases/gc-trace-text makes the collector
# print each kind of line (live, phases, the adaptive sweep; a --fast build's foreground collector prints the live
# lines), in release and --fast builds.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/gc-trace-text"
rm -rf "$out"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/gc-trace-text/main.ab -o "$out/trace-$mode" "${flags[@]}" > "$out/build-$mode.log" 2>&1 \
        || { cat "$out/build-$mode.log" >&2; echo "gc trace text: ($mode) did not build" >&2; exit 1; }
    status=0
    ABLA_GC_TRACE=1 "$out/trace-$mode" > "$out/run-$mode.out" 2> "$out/trace-$mode.txt" || status=$?
    [[ $status -eq 0 && $(cat "$out/run-$mode.out") == "gc trace text ok: 1350126000000 319999600000" ]] ||
        { echo "gc trace text ($mode): status $status: $(cat "$out/run-$mode.out")" >&2; exit 1; }
    # A --fast build has no background collector by default (tools/test-gc-default.sh), so no phases or adaptive lines.
    lines=('gc: live ')
    [[ $mode == release ]] && lines+=('gc: phases us, pages ' 'gc: adaptive, parallel ')
    for line in "${lines[@]}"; do
        LC_ALL=C grep -a -- "^$line" "$out/trace-$mode.txt" > /dev/null ||
            { echo "gc trace text ($mode): the trace has no \"$line\" line" >&2; exit 1; }
    done
    other=$(LC_ALL=C tr -d '\t\n -~' < "$out/trace-$mode.txt" | wc -c)
    [[ $other -eq 0 ]] ||
        { echo "gc trace text ($mode): $other bytes that are not printable text in the trace" >&2; exit 1; }
    echo "gc trace text ($mode): $(wc -l < "$out/trace-$mode.txt") lines of plain text"
done
