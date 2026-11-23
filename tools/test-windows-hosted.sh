#!/usr/bin/env bash
# Hosted Windows programs (W1c, docs/design/windows-target.md): the Abla runtime and standard library over kernel32 through
# platform/windows, cross-built on Linux with `--target x86_64-windows-hosted` (--fast and release), linked by lld-link. Each program
# in tests/cases/windows/hosted must
#   - import only what tools/windows-imports-allowlist.txt allows, and no C runtime under any name;
#   - print what the same program prints built natively for Linux, with the same arguments, when run under Wine (skipped with a
#     message when Wine is not installed; tools/windows/wine-run.sh runs it headless).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/windows-hosted
rm -rf "$out"
mkdir -p "$out"
fail() { echo "windows-hosted: $1" >&2; exit 1; }
for tool in lld-link llvm-readobj; do
    command -v "$tool" > /dev/null || { echo "windows-hosted: skipped ($tool is not installed)"; exit 0; }
done
allowed=$(grep -v '^#' tools/windows-imports-allowlist.txt | grep -v '^$' || true)
ran=0
skipped=0
arguments=(one "two words" three)
export ABLA_WINDOWS_TEST="two words and = signs"
export ABLA_WINDOWS_UNICODE="héllo €"
for source in tests/cases/windows/hosted/*.ab; do
    name=$(basename -- "$source" .ab)
    "$compiler" build "$source" -o "$out/$name.native" --fast --no-cache > "$out/$name.native.log" 2>&1 ||
        { cat "$out/$name.native.log" >&2; fail "$name did not build for Linux"; }
    "$out/$name.native" "${arguments[@]}" > "$out/$name.expected"
    for mode in fast release; do
        # A known crash of a seed-built stage 1 compiler: the in-process fast build of this larger module (sockets, with the process code
        # in its graph) segfaults or hangs, while release and a stage 2 build it (ablac-e8 has the repro). It is skipped until that is fixed.
        [[ $name == sockets && $mode == fast && -n ${ABLA_WINDOWS_STAGE1:-} ]] && continue
        flags=(--no-cache)
        [[ $mode == fast ]] && flags+=(--fast)
        exe=$out/$name.$mode.exe
        "$compiler" build "$source" --target x86_64-windows-hosted -o "$exe" "${flags[@]}" > "$exe.log" 2>&1 ||
            { cat "$exe.log" >&2; fail "$name ($mode) did not build for Windows"; }
        imports=$(llvm-readobj --coff-imports "$exe" | awk '/^ *Name:/ { dll = $2 } /^ *Symbol:/ { print dll, $2 }')
        ! grep -qiE 'msvcrt|ucrtbase|vcruntime|api-ms-win-crt' <<< "$imports" || fail "$name ($mode): a C runtime import: $imports"
        # A program that uses nothing of the optional DLLs imports the same ones as hello does (tools/windows-hello-dlls.txt): crypt32, which
        # the system roots need, is loaded when they are first asked for (system call 4006), not linked into every program.
        if [[ $name == hello ]]; then
            dlls=$(awk '{ print $1 }' <<< "$imports" | sort -u)
            [[ $dlls == "$(cat tools/windows-hello-dlls.txt)" ]] ||
                fail "hello ($mode) imports other DLLs than tools/windows-hello-dlls.txt lists: $(tr '\n' ' ' <<< "$dlls")"
        fi
        while read -r dll function; do
            [[ -z $dll ]] || grep -qxF "$dll $function" <<< "$allowed" ||
                fail "$name ($mode): import not in tools/windows-imports-allowlist.txt: $dll $function"
        done <<< "$imports"
        status=0
        tools/windows/wine-run.sh "$exe" "${arguments[@]}" > "$out/$name.$mode.actual" 2> "$out/$name.$mode.err" || status=$?
        if [[ $status == 125 ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        [[ $status == 0 ]] || { cat "$out/$name.$mode.err" >&2; fail "$name ($mode): exit status $status under Wine"; }
        cmp -s "$out/$name.expected" "$out/$name.$mode.actual" ||
            { diff "$out/$name.expected" "$out/$name.$mode.actual" >&2 || true; fail "$name ($mode): the output under Wine differs from the native Linux run"; }
        ran=$((ran + 1))
    done
done
# What a Windows runner needs to run the same programs natively (tools/windows/test-hosted.ps1, the windows-run job in ci.yml): the
# images, the Linux outputs they must print and their hashes, so the runner checks it runs what was built here.
(cd "$out" && sha256sum -- ./*.exe ./*.expected | sed 's|  \./|  |' > SHA256SUMS)
if ((skipped > 0)); then
    echo "windows-hosted: built, imports within the allowlist, no C runtime; $skipped runs skipped (Wine is not installed)"
else
    echo "windows-hosted: $ran runs under Wine print what the native Linux programs print; imports within the allowlist, no C runtime"
fi
