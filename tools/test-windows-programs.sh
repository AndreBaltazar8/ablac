#!/usr/bin/env bash
# Standard-library test programs on a hosted Windows target: every program listed in tests/cases/windows/programs.txt (collections, text,
# date, files, process exit, loopback HTTP and WebSocket, threads, ...) is built --fast with `--target x86_64-windows-hosted`, linked by
# lld-link, and must
#   - import only what tools/windows-imports-allowlist.txt allows, and no C runtime under any name;
#   - exit with the status the list gives and print what the same program prints built natively for Linux, when run under Wine (skipped
#     with a message when Wine is not installed; tools/windows/wine-run.sh runs it headless).
# The images, the Linux outputs and statuses, and their hashes are left in build/windows-stdlib for the Windows runner
# (tools/windows/test-hosted.ps1 -Programs build/windows-stdlib, the windows-run job in ci.yml), which is the truth Wine only approximates.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/windows-stdlib
rm -rf "$out"
mkdir -p "$out"
fail() { echo "windows-programs: $1" >&2; exit 1; }
for tool in lld-link llvm-readobj; do
    command -v "$tool" > /dev/null || { echo "windows-programs: skipped ($tool is not installed)"; exit 0; }
done
allowed=$(grep -v '^#' tools/windows-imports-allowlist.txt | grep -v '^$' || true)
ran=0
skipped=0
count=0
runner=0
while read -r source status where; do
    [[ -z $source || $source == '#'* ]] && continue
    [[ -f $source ]] || fail "$source (tests/cases/windows/programs.txt) does not exist"
    count=$((count + 1))
    name=$(echo "${source#tests/cases/}" | sed 's|\.ab$||; s|[/.]|-|g')
    # The Linux run: in a directory of its own (a program may write files), with no arguments.
    "$compiler" build "$source" -o "$out/$name.native" --fast --no-cache > "$out/$name.native.log" 2>&1 ||
        { cat "$out/$name.native.log" >&2; fail "$name did not build for Linux"; }
    mkdir -p "$out/$name.dir"
    native=$(cd "$out/$name.dir" && timeout 120 "../$name.native" > "../$name.expected" 2> /dev/null < /dev/null; echo $?)
    [[ $native == "$status" ]] || fail "$name: the Linux program exits $native, tests/cases/windows/programs.txt says $status"
    echo "$status" > "$out/$name.status"
    exe=$out/$name.exe
    "$compiler" build "$source" --target x86_64-windows-hosted -o "$exe" --fast --no-cache > "$exe.log" 2>&1 ||
        { cat "$exe.log" >&2; fail "$name did not build for Windows"; }
    imports=$(llvm-readobj --coff-imports "$exe" | awk '/^ *Name:/ { dll = $2 } /^ *Symbol:/ { print dll, $2 }')
    ! grep -qiE 'msvcrt|ucrtbase|vcruntime|api-ms-win-crt' <<< "$imports" || fail "$name: a C runtime import: $imports"
    while read -r dll function; do
        [[ -z $dll ]] || grep -qxF "$dll $function" <<< "$allowed" ||
            fail "$name: import not in tools/windows-imports-allowlist.txt: $dll $function"
    done <<< "$imports"
    # A program marked `runner` (one Wine cannot check) is built and left for the Windows runner only.
    if [[ $where == runner ]]; then
        runner=$((runner + 1))
        continue
    fi
    mkdir -p "$out/$name.wine"
    code=0
    (cd "$out/$name.wine" && "$root/tools/windows/wine-run.sh" "$root/$exe" > "../$name.actual" 2> "../$name.err" < /dev/null) || code=$?
    if [[ $code == 125 ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    [[ $code == "$status" ]] || { cat "$out/$name.err" >&2; fail "$name: exit status $code under Wine, expected $status"; }
    cmp -s "$out/$name.expected" "$out/$name.actual" ||
        { diff "$out/$name.expected" "$out/$name.actual" >&2 || true; fail "$name: the output under Wine differs from the native Linux run"; }
    ran=$((ran + 1))
done < tests/cases/windows/programs.txt
((count > 0)) || fail 'tests/cases/windows/programs.txt lists no program'
(cd "$out" && sha256sum -- ./*.exe ./*.expected ./*.status | sed 's|  \./|  |' > SHA256SUMS)
if ((skipped > 0)); then
    echo "windows-programs: $count programs built, imports within the allowlist, no C runtime; $skipped runs skipped (Wine is not installed)"
else
    echo "windows-programs: $ran programs under Wine exit and print what the native Linux programs do ($runner more for the Windows runner only); imports within the allowlist, no C runtime"
fi
