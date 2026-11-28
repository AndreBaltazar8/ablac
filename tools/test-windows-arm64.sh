#!/usr/bin/env bash
# Cross-build with the Linux static compiler and retain the inspected artifacts for the ARM runner.
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac-static}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
cd "$root"
out="$root/build/windows-arm64-programs"
mkdir -p "$out"
tools=$(mktemp -d "$root/build/windows-arm64-tools.XXXXXX")
trap 'rm -rf -- "$tools"' EXIT
fail() { printf 'windows-arm64: %s\n' "$*" >&2; exit 1; }

# A split backtrace uses objcopy. With only objcopy on PATH, opt, llc and
# lld-link have to come from the compiler itself.
objcopy=$(command -v llvm-objcopy) || fail 'llvm-objcopy is required'
ln -s "$objcopy" "$tools/llvm-objcopy"
unset ABLA_LLVM_TOOLS ABLA_TEST_FAST_BUILDS ABLA_DEBUG
export ABLA_SYSROOT="$root"

allowed=$(cat tools/windows-imports-allowlist.txt)
build_pe() {
    local name=$1 source=$2 exe dll function
    shift 2
    exe="$out/$name.exe"
    PATH="$tools" "$compiler" build "tests/cases/$source.ab" --target aarch64-windows \
        --no-cache -o "$exe" "$@" > "$out/$name.build.log" 2>&1 ||
        { cat "$out/$name.build.log" >&2; fail "$name did not build"; }
    llvm-readobj --file-headers --coff-imports --coff-tls-directory --coff-basereloc --unwind \
        "$exe" > "$out/$name.pe"
    grep -q 'Machine: IMAGE_FILE_MACHINE_ARM64 (0xAA64)' "$out/$name.pe" || fail "$name has the wrong machine"
    grep -q 'Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI' "$out/$name.pe" || fail "$name has the wrong subsystem"
    grep -Eq 'AddressOfEntryPoint: 0x[0-9A-Fa-f]*[1-9A-Fa-f]' "$out/$name.pe" || fail "$name lacks an entry point"
    grep -q 'TLSDirectory {' "$out/$name.pe" || fail "$name lacks loader TLS"
    grep -q 'Type: DIR64' "$out/$name.pe" || fail "$name lacks 64-bit base relocations"
    grep -q 'RuntimeFunction {' "$out/$name.pe" || fail "$name lacks ARM64 unwind data"
    local imports
    imports=$(awk '/^ *Name:/ { dll = $2 } /^ *Symbol:/ { print dll, $2 }' "$out/$name.pe")
    grep -qxF 'kernel32.dll ExitProcess' <<< "$imports" || fail "$name lacks ExitProcess"
    while read -r dll function; do
        grep -qxF "$dll $function" <<< "$allowed" ||
            fail "$name imports $dll $function outside the Windows allowlist"
    done <<< "$imports"
}

build_pe hello-fast windows/hosted/hello --fast
for name in hello args environment files threads; do
    build_pe "$name" "windows/hosted/$name"
done
build_pe tls thread-local-image/main
build_pe stm stm/basic
build_pe stack-probe windows/arm64/stack-probe
build_pe crash windows/crash/crash --backtrace
# The compile-time guard's Windows half (fault-guard, watchdog, preempt: docs/design/windows-jit.md §4, §5), run with the
# argument "arm64" so they write ARM64 code into executable memory; with them scrub-near-limit (ctScrubStack8192 with
# less than a page committed under it), which reads StackLimit with ARM64 code there.
for name in fault-guard watchdog preempt scrub-near-limit; do
    build_pe "$name" "windows/$name" --fast
done
grep -q 'Symbol: RtlVirtualUnwind' "$out/crash.pe" || fail 'backtrace omitted the Windows unwinder'
[[ -s $out/crash.exe.debug ]] || fail 'backtrace omitted split debug info'
llvm-readobj --unwind "$out/threads.exe.o" > "$out/threads.unwind"
for stub in abla_win_thread_start pthread_create pthread_join; do
    grep -q "Function: $stub (" "$out/threads.unwind" || fail "$stub lacks unwind data"
done
llvm-readobj --relocations "$out/stack-probe.exe.o" > "$out/stack-probe.relocations"
grep -q 'IMAGE_REL_ARM64_BRANCH26 __chkstk' "$out/stack-probe.relocations" ||
    fail 'the stack fixture did not call __chkstk'

# The links above ran lld's COFF driver inside the compiler (only llvm-objcopy is on PATH: there is no lld-link to start). The
# same program linked by the external lld-link (ABLA_LINK_INPROCESS=0, lld-link on PATH) must be the same image, byte for
# byte, for either Windows machine: the in-process link is the external one's, not an approximation of it.
lld_link=$(command -v lld-link) || fail 'lld-link is required for the comparison with the external link'
external=$(mktemp -d "$root/build/windows-link-tools.XXXXXX")
trap 'rm -rf -- "$tools" "$external"' EXIT
ln -s "$objcopy" "$external/llvm-objcopy"
ln -s "$lld_link" "$external/lld-link"
for target in aarch64-windows x86_64-windows; do
    PATH="$tools" "$compiler" build tests/cases/windows/hosted/hello.ab --target "$target" --no-cache \
        -o "$out/link-inprocess.$target.exe" > "$out/link-inprocess.$target.log" 2>&1 ||
        { cat "$out/link-inprocess.$target.log" >&2; fail "$target: the in-process link failed"; }
    PATH="$external" ABLA_LINK_INPROCESS=0 "$compiler" build tests/cases/windows/hosted/hello.ab --target "$target" --no-cache \
        -o "$out/link-external.$target.exe" > "$out/link-external.$target.log" 2>&1 ||
        { cat "$out/link-external.$target.log" >&2; fail "$target: the external lld-link failed"; }
    cmp "$out/link-inprocess.$target.exe" "$out/link-external.$target.exe" ||
        fail "$target: the in-process link and the external lld-link wrote different images"
    rm -f "$out/link-inprocess.$target".* "$out/link-external.$target".*
done

native="$out/files.native"
"$compiler" build tests/cases/windows/hosted/files.ab --fast --no-cache -o "$native" > "$out/files.native.log" 2>&1 ||
    { cat "$out/files.native.log" >&2; fail 'could not build the Linux files fixture'; }
(cd "$out" && "$native") > "$out/files.expected"
(cd "$out" && sha256sum -- ./*.exe ./crash.exe.debug ./files.expected | sed 's|  \./|  |' > SHA256SUMS)
echo 'windows-arm64: 13 ARM64 PE programs passed structural checks; the compiler'"'"'s own lld-link writes the external one'"'"'s images (x64 and ARM64)'
