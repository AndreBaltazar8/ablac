#!/usr/bin/env bash
# `ablac symbolize`: the stack a crashed program with debug information printed (here a release build with -g, an
# index out of bounds, 8 of 3, two calls deep) comes back with its frames' functions and file:line, the inlined ones
# included: the runtime's panic and the program's own line. Skipped without llvm-symbolizer (or atos on macOS).
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
if [[ $(uname -s) == Darwin ]]; then tool=atos; else tool=llvm-symbolizer; fi
if ! command -v "$tool" >/dev/null 2>&1; then
    echo "symbolize: skipped (no $tool)"
    exit 0
fi
out="$project_root/build/symbolize-test"
rm -rf "$out"
mkdir -p "$out"
"$compiler" build "$project_root/tests/cases/symbolize/crash.ab" -o "$out/crash" -g --no-cache
set +e
"$out/crash" > /dev/null 2> "$out/crash.txt"
status=$?
set -e
[[ $status -eq 101 ]] || { echo "symbolize: the probe exited $status" >&2; cat "$out/crash.txt" >&2; exit 1; }
grep -q '^panic: index 8 out of bounds for array of size 3$' "$out/crash.txt" ||
    { echo 'symbolize: the probe did not panic as expected' >&2; cat "$out/crash.txt" >&2; exit 1; }
"$compiler" symbolize "$out/crash" "$out/crash.txt" > "$out/symbolized.txt"
# From standard input too.
"$compiler" symbolize "$out/crash" < "$out/crash.txt" > "$out/symbolized-input.txt"
cmp -s "$out/symbolized.txt" "$out/symbolized-input.txt" ||
    { echo 'symbolize: standard input gave another answer' >&2; exit 1; }
symbolized=$(< "$out/symbolized.txt")
for expected in '#0 ' '__ablaRuntimePanicArrayIndex' 'crash.ab:7'; do
    [[ $symbolized == *"$expected"* ]] ||
        { echo "symbolize: no \"$expected\" in the symbolized stack" >&2; cat "$out/crash.txt" "$out/symbolized.txt" >&2; exit 1; }
done
# A text with no stack says so.
if printf 'panic: boom\n' | "$compiler" symbolize "$out/crash" > /dev/null 2> "$out/none.err"; then
    echo 'symbolize: a text without a stack was accepted' >&2
    exit 1
fi
grep -q 'no stack' "$out/none.err" || { echo 'symbolize: no reason for a text without a stack' >&2; exit 1; }
echo 'symbolize: a crash stack comes back with its functions and file:line, the inlined frames included'
