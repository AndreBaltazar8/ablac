#!/usr/bin/env bash
# `ablac symbolize`: the stack a crashed program with debug information printed (here a release build with -g, an
# index out of bounds, 8 of 3, two calls deep) comes back with its frames' functions and file:line, the inlined ones
# included: the runtime's panic and the program's own line. Skipped without llvm-symbolizer (or atos on macOS).
# A --backtrace build answers the same from the <output>.debug (Linux) or <output>.dSYM (macOS) the build wrote beside it.
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
# On macOS the program's debug map names objects the build removes: its DWARF is in crash.dSYM beside it.
if [[ $(uname -s) == Darwin && ! -s $out/crash.dSYM/Contents/Resources/DWARF/crash ]]; then
    echo 'symbolize: a -g build wrote no crash.dSYM' >&2; ls -la "$out" >&2; exit 1
fi
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
# A --backtrace build (ELF) ships without DWARF: its line tables are in <output>.debug beside it, under the same build
# id, which symbolize follows (the program's debug link); without that file the same stack has no file:line.
if [[ $(uname -s) == Linux ]]; then
    "$compiler" build "$project_root/tests/cases/symbolize/crash.ab" -o "$out/release" --backtrace --no-cache
    [[ -s $out/release.debug ]] || { echo 'symbolize: --backtrace wrote no release.debug' >&2; exit 1; }
    ! llvm-readelf -S "$out/release" | grep debug_line > /dev/null ||
        { echo 'symbolize: the --backtrace program kept its DWARF' >&2; exit 1; }
    program_id=$(llvm-readelf -n "$out/release" | grep 'Build ID')
    debug_id=$(llvm-readelf -n "$out/release.debug" 2> /dev/null | grep 'Build ID')
    [[ -n $program_id && $program_id == "$debug_id" ]] ||
        { echo "symbolize: build ids differ: '$program_id' and '$debug_id'" >&2; exit 1; }
    set +e
    "$out/release" > /dev/null 2> "$out/release.txt"
    set -e
    "$compiler" symbolize "$out/release" "$out/release.txt" > "$out/release-symbolized.txt"
    [[ $(< "$out/release-symbolized.txt") == *'crash.ab:7'* ]] ||
        { echo 'symbolize: no crash.ab:7 from release.debug' >&2; cat "$out/release.txt" "$out/release-symbolized.txt" >&2; exit 1; }
    mv "$out/release.debug" "$out/release.moved"
    "$compiler" symbolize "$out/release" "$out/release.txt" > "$out/release-without.txt"
    [[ $(< "$out/release-without.txt") != *'crash.ab:7'* ]] ||
        { echo 'symbolize: file:line without release.debug' >&2; exit 1; }
fi
# A --backtrace build (macOS) ships without its debug map: its DWARF is in <output>.dSYM beside it, under the image's
# UUID, which symbolize gives atos; without the bundle the same stack has no file:line.
if [[ $(uname -s) == Darwin ]]; then
    "$compiler" build "$project_root/tests/cases/symbolize/crash.ab" -o "$out/release" --backtrace --no-cache
    dwarf="$out/release.dSYM/Contents/Resources/DWARF/release"
    [[ -s $dwarf ]] || { echo 'symbolize: --backtrace wrote no release.dSYM' >&2; ls -R "$out" >&2; exit 1; }
    ! nm -ap "$out/release" | grep -E ' (OSO|SO) ' > /dev/null ||
        { echo 'symbolize: the --backtrace program kept its debug map' >&2; nm -ap "$out/release" | grep ' OSO ' >&2; exit 1; }
    program_uuid=$(dwarfdump --uuid "$out/release" | awk '{ print $2 }')
    debug_uuid=$(dwarfdump --uuid "$dwarf" | awk '{ print $2 }')
    [[ -n $program_uuid && $program_uuid == "$debug_uuid" ]] ||
        { echo "symbolize: UUIDs differ: '$program_uuid' and '$debug_uuid'" >&2; exit 1; }
    set +e
    "$out/release" > /dev/null 2> "$out/release.txt"
    status=$?
    set -e
    [[ $status -eq 101 ]] || { echo "symbolize: the --backtrace probe exited $status" >&2; cat "$out/release.txt" >&2; exit 1; }
    "$compiler" symbolize "$out/release" "$out/release.txt" > "$out/release-symbolized.txt"
    [[ $(< "$out/release-symbolized.txt") == *'crash.ab:7'* ]] ||
        { echo 'symbolize: no crash.ab:7 from release.dSYM' >&2; cat "$out/release.txt" "$out/release-symbolized.txt" >&2; exit 1; }
    mv "$out/release.dSYM" "$out/release.moved"
    "$compiler" symbolize "$out/release" "$out/release.txt" > "$out/release-without.txt" || true
    [[ $(< "$out/release-without.txt") != *'crash.ab:7'* ]] ||
        { echo 'symbolize: file:line without release.dSYM' >&2; cat "$out/release-without.txt" >&2; exit 1; }
fi
# A text with no stack says so.
if printf 'panic: boom\n' | "$compiler" symbolize "$out/crash" > /dev/null 2> "$out/none.err"; then
    echo 'symbolize: a text without a stack was accepted' >&2
    exit 1
fi
grep -q 'no stack' "$out/none.err" || { echo 'symbolize: no reason for a text without a stack' >&2; exit 1; }
echo 'symbolize: a crash stack comes back with its functions and file:line, the inlined frames included'
