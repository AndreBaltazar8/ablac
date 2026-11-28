#!/usr/bin/env bash
# Standard-library test programs on a hosted Windows target: every program listed in tests/cases/windows/programs.txt (collections, text,
# date, files, process exit, loopback HTTP and WebSocket, threads, ...) is built --fast with `--target x86_64-windows`, linked by
# lld-link, and must
#   - import only what tools/windows-imports-allowlist.txt allows, and no C runtime under any name;
#   - exit with the status the list gives and print what the same program prints built natively for Linux, when run under Wine (skipped
#     with a message when Wine is not installed; tools/windows/wine-run.sh runs it headless).
# The images, the Linux outputs and statuses, and their hashes are left in build/windows-stdlib for the Windows runner
# (tools/windows/test-hosted.ps1 -Programs build/windows-stdlib, the windows-run job in ci.yml), which is the truth Wine only approximates.
#
# tools/test-windows-programs.sh [compiler [target]]: with the target aarch64-windows (the ARM64 hosted runtime) the same programs are built for
# ARM64 into build/windows-arm64-stdlib, and nothing runs here (Wine has no ARM64): the Windows ARM64 runner runs them
# (the windows-arm64-run job). A program that does not build is reported at the end, and the others are still built.
set -euo pipefail
compiler=${1:-build/ablac}
target=${2:-x86_64-windows}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/windows-stdlib
[[ $target == aarch64-windows ]] && out=build/windows-arm64-stdlib
rm -rf "$out" build/windows-debug build/windows-arm64-debug
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
unbuilt=""
# A program marked `wine` passes under Wine only: it is not left for the Windows runner (also when Wine is not installed here)...
wine_only_finish() {
    [[ $where == wine ]] || return 0
        rm -f "$exe" "$out/$name.expected" "$out/$name.status"
        # ... but a --backtrace build of it goes to build/windows-debug, and the Windows job runs that one and prints
        # what happens to it (tools/windows/debug-programs.ps1: output, status, the symbolized stack of a crash).
        mkdir -p build/windows-debug
        "$compiler" build "$source" --target x86_64-windows -o "build/windows-debug/$name.exe" --fast --backtrace --no-cache \
            > "build/windows-debug/$name.log" 2>&1 || { cat "build/windows-debug/$name.log" >&2; fail "$name did not build with --backtrace"; }
        # --fast builds name the functions of a stack; a release one also has its file:line (<name>-release.exe.debug).
        "$compiler" build "$source" --target x86_64-windows -o "build/windows-debug/$name-release.exe" --backtrace --no-cache \
            > "build/windows-debug/$name-release.log" 2>&1 || { cat "build/windows-debug/$name-release.log" >&2; fail "$name did not build with --backtrace for release"; }
        wineonly=$((wineonly + 1))
}
wineonly=0
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
    if [[ $target == aarch64-windows ]]; then
        # Wine-only programs are not run on a runner, and ARM64 has no Wine
        if [[ $where == wine ]]; then
            rm -f "$out/$name.status" "$out/$name.expected"
            continue
        fi
        "$compiler" build "$source" --target "$target" -o "$exe" --fast --no-cache > "$exe.log" 2>&1 || {
            tail -5 "$exe.log" >&2
            echo "windows-programs: $name did not build for $target" >&2
            unbuilt="$unbuilt $name"
            rm -f "$out/$name.status" "$out/$name.expected"
            continue
        }
    else
        "$compiler" build "$source" --target "$target" -o "$exe" --fast --no-cache > "$exe.log" 2>&1 ||
            { cat "$exe.log" >&2; fail "$name did not build for Windows"; }
    fi
    imports=$(llvm-readobj --coff-imports "$exe" | awk '/^ *Name:/ { dll = $2 } /^ *Symbol:/ { print dll, $2 }')
    ! grep -qiE 'msvcrt|ucrtbase|vcruntime|api-ms-win-crt' <<< "$imports" || fail "$name: a C runtime import: $imports"
    while read -r dll function; do
        [[ -z $dll ]] || grep -qxF "$dll $function" <<< "$allowed" ||
            fail "$name: import not in tools/windows-imports-allowlist.txt: $dll $function"
    done <<< "$imports"
    # A program marked `runner` (one Wine cannot check) is built and left for the Windows runner only; so is every program for ARM64.
    if [[ $target == aarch64-windows ]]; then
        # Windows ends a program that reads ID_AA64ISAR0_EL1 (mrs, system register S3_0_C0_C6_0) with STATUS_ILLEGAL_INSTRUCTION: the CPU
        # probe of abla/simd/target must not emit it for this target (the ARM64 https-loopback died of it in aesGcmKeyOwner).
        llvm-objdump -d "$exe" > "$exe.asm" 2>/dev/null || fail "$name: llvm-objdump could not disassemble $exe"
        ! grep -qE 'mrs[[:space:]].*(S3_0_C0_C6_0|ID_AA64ISAR0_EL1)' "$exe.asm" || fail "$name: reads ID_AA64ISAR0_EL1, which Windows refuses to user code"
        rm -f "$exe.asm"
        if grep -qxF "$source" tests/cases/windows/arm64-debug.txt; then
            mkdir -p build/windows-arm64-debug
            "$compiler" build "$source" --target "$target" -o "build/windows-arm64-debug/$name.exe" --fast --backtrace --no-cache \
                > "build/windows-arm64-debug/$name.log" 2>&1 || { tail -5 "build/windows-arm64-debug/$name.log" >&2; fail "$name did not build with --backtrace for $target"; }
            "$compiler" build "$source" --target "$target" -o "build/windows-arm64-debug/$name-release.exe" --backtrace --no-cache \
                > "build/windows-arm64-debug/$name-release.log" 2>&1 || { tail -5 "build/windows-arm64-debug/$name-release.log" >&2; fail "$name did not build with --backtrace (release) for $target"; }
        fi
        runner=$((runner + 1))
        continue
    fi
    if [[ $where == runner ]]; then
        runner=$((runner + 1))
        continue
    fi
    mkdir -p "$out/$name.wine"
    code=0
    (cd "$out/$name.wine" && "$root/tools/windows/wine-run.sh" "$root/$exe" > "../$name.actual" 2> "../$name.err" < /dev/null) || code=$?
    if [[ $code == 125 ]]; then
        skipped=$((skipped + 1))
        wine_only_finish
        continue
    fi
    [[ $code == "$status" ]] || { cat "$out/$name.err" >&2; fail "$name: exit status $code under Wine, expected $status"; }
    cmp -s "$out/$name.expected" "$out/$name.actual" ||
        { diff "$out/$name.expected" "$out/$name.actual" >&2 || true; fail "$name: the output under Wine differs from the native Linux run"; }
    ran=$((ran + 1))
    wine_only_finish
done < tests/cases/windows/programs.txt
((count > 0)) || fail 'tests/cases/windows/programs.txt lists no program'
(cd "$out" && sha256sum -- ./*.exe ./*.expected ./*.status | sed 's|  \./|  |' > SHA256SUMS)
if [[ $target == aarch64-windows ]]; then
    if [[ -n $unbuilt ]]; then
        echo "windows-programs: not built for $target:$unbuilt" >&2
        exit 1
    fi
    echo "windows-programs: $runner programs built for $target, imports within the allowlist, no C runtime; the ARM64 runner runs them"
elif ((skipped > 0)); then
    echo "windows-programs: $count programs built, imports within the allowlist, no C runtime; $skipped runs skipped (Wine is not installed)"
else
    echo "windows-programs: $ran programs under Wine exit and print what the native Linux programs do ($runner more for the Windows runner only); imports within the allowlist, no C runtime"
fi
