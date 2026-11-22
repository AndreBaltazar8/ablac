#!/usr/bin/env bash
# Crash reports of a hosted Windows program (x86_64-windows-hosted; src/backend/llvm/debug.ab, the Windows section): what
# tests/cases/windows/crash/crash.ab prints when it dies under Wine, built release, --backtrace and --fast -g:
#   - a panic: its message and exit status 101; a --backtrace build names the stack's frames (main among them), a --fast -g
#     one prints them unnamed, a release build prints none;
#   - a bad store (address 16): "fatal signal: a bad memory access at 0x0000000000000010" from the vectored exception
#     handler, then the stack from the faulting instruction (--backtrace: named, the handler's own frame not among them),
#     and the access violation's status (0xC0000005, whose low byte Wine's exit status is), not winedbg;
#   - unbounded recursion: "panic: stack overflow", status 101;
#   - a panic on a thread: a --backtrace stack through the thread's entry;
#   - `ablac symbolize` on the stacks: file:line from the DWARF a --fast -g program keeps and a --backtrace one leaves in
#     <program>.debug.
# A release build imports only the handler's two functions beyond what the runtime does (not the unwinder's). Wine runs
# are skipped with a message when Wine is not installed (tools/windows/wine-run.sh runs it headless).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/windows-crash
rm -rf "$out"
mkdir -p "$out"
fail() { echo "windows-crash: $1" >&2; exit 1; }
for tool in lld-link llvm-readobj llvm-symbolizer; do
    command -v "$tool" > /dev/null || { echo "windows-crash: skipped ($tool is not installed)"; exit 0; }
done
source=tests/cases/windows/crash/crash.ab
for mode in release backtrace fast; do
    flags=(--no-cache)
    [[ $mode == backtrace ]] && flags+=(--backtrace)
    # (-g: the suite builds with ABLA_DEBUG=0, which makes a bare --fast build one without debug information.)
    [[ $mode == fast ]] && flags+=(--fast -g)
    "$compiler" build "$source" --target x86_64-windows-hosted -o "$out/crash-$mode.exe" "${flags[@]}" > "$out/$mode.log" 2>&1 ||
        { cat "$out/$mode.log" >&2; fail "crash.ab ($mode) did not build"; }
done
imports() { llvm-readobj --coff-imports "$1" | awk '/^ *Symbol:/ { print $2 }'; }
release_imports=$(imports "$out/crash-release.exe")
for function in AddVectoredExceptionHandler TerminateProcess; do
    grep -qx "$function" <<< "$release_imports" || fail "a release build does not import $function"
done
! grep -qE '^Rtl(CaptureContext|LookupFunctionEntry|VirtualUnwind)$' <<< "$release_imports" ||
    fail "a release build imports the unwinder: $(grep '^Rtl' <<< "$release_imports" | tr '\n' ' ')"
grep -qx RtlVirtualUnwind <<< "$(imports "$out/crash-backtrace.exe")" || fail "a --backtrace build does not import RtlVirtualUnwind"

# run <mode> <argument>: the program's standard error in $out/<mode>-<argument>.err, its status in $status.
run() {
    status=0
    tools/windows/wine-run.sh "$out/crash-$1.exe" "$2" > "$out/$1-$2.out" 2> "$out/$1-$2.err" || status=$?
    [[ $status != 125 ]] || { echo "windows-crash: built; runs skipped (Wine is not installed)"; exit 0; }
    if grep -qE 'WineDbg|Unhandled (page fault|exception)' "$out/$1-$2.err"; then
        fail "$1 $2: the exception reached Wine's debugger: $(head -3 "$out/$1-$2.err")"
    fi
    return 0
}
stack_of() { sed -n '/^stack /,/^load address /p' "$out/$1-$2.err"; }

for mode in release backtrace fast; do
    run "$mode" panic
    [[ $status == 101 ]] || fail "a panic ($mode) exited $status"
    grep -qx 'panic: index 5 out of bounds for array of size 3' "$out/$mode-panic.err" ||
        fail "a panic ($mode): $(head -3 "$out/$mode-panic.err")"
    run "$mode" store
    [[ $status == 5 ]] || fail "a bad store ($mode) exited $status, not the access violation's 5"
    grep -qx 'fatal signal: a bad memory access at 0x0000000000000010' "$out/$mode-store.err" ||
        fail "a bad store ($mode): $(head -3 "$out/$mode-store.err")"
    run "$mode" overflow
    [[ $status == 101 ]] || fail "unbounded recursion ($mode) exited $status"
    grep -qx 'panic: stack overflow' "$out/$mode-overflow.err" || fail "unbounded recursion ($mode): $(head -3 "$out/$mode-overflow.err")"
done
! grep -q '^stack ' "$out/release-panic.err" "$out/release-store.err" || fail "a release build printed a stack"
for argument in panic store; do
    frames=$(stack_of fast "$argument" | grep -c '^0x' || true)
    ((frames >= 3)) || fail "a --fast $argument printed $frames frames: $(head -8 "$out/fast-$argument.err")"
    stack_of backtrace "$argument" | grep '^0x[0-9a-f]* in main$' > /dev/null ||
        fail "a --backtrace $argument named no main: $(head -12 "$out/backtrace-$argument.err")"
    stack_of backtrace "$argument" | grep '^load address 0x' > /dev/null || fail "a --backtrace $argument printed no load address"
done
stack_of backtrace panic | grep '^0x[0-9a-f]* in [^ ]*__ablaRuntimePanicArrayIndex$' > /dev/null ||
    fail "a --backtrace panic named no panicking function: $(head -12 "$out/backtrace-panic.err")"
stack_of backtrace store | sed -n 2p | grep '^0x[0-9a-f]* in [^ ]* (the faulting instruction)$' > /dev/null ||
    fail "a --backtrace bad store named no faulting function: $(head -8 "$out/backtrace-store.err")"
! grep -q 'abla_runtime_windows_fault' "$out/backtrace-store.err" || fail "a --backtrace bad store walked the handler's frame"
run backtrace thread-panic
[[ $status == 101 ]] || fail "a panic on a thread exited $status"
stack_of backtrace thread-panic | grep '^0x[0-9a-f]* in abla_runtime_thread_entry$' > /dev/null ||
    fail "a --backtrace panic on a thread named no thread entry: $(head -12 "$out/backtrace-thread-panic.err")"

# file:line: a --backtrace program ships without its DWARF or a symbol table, which are in crash-backtrace.exe.debug beside
# it (its debug link); `ablac symbolize` reads that for the stack the program printed, and without it has no file:line.
# A --fast -g program keeps its DWARF.
[[ -s $out/crash-backtrace.exe.debug ]] || fail "--backtrace wrote no crash-backtrace.exe.debug"
! llvm-readobj --sections "$out/crash-backtrace.exe" | grep -E 'Name: \.debug_(info|line)' > /dev/null ||
    fail "the --backtrace program kept its DWARF"
[[ $(llvm-readobj --file-headers "$out/crash-backtrace.exe" | awk '/SymbolCount:/ { print $2 }') == 0 ]] ||
    fail "the --backtrace program kept a symbol table"
symbolized() { "$compiler" symbolize "$out/crash-$1.exe" "$out/$1-$2.err" > "$out/$1-$2.symbolized" 2>&1 || true; }
for mode in backtrace fast; do
    symbolized "$mode" store
    grep 'crash\.ab:11:' "$out/$mode-store.symbolized" > /dev/null ||
        fail "symbolize: no crash.ab:11 for the --$mode bad store: $(cat "$out/$mode-store.symbolized")"
    # (The index is line 17, in pick; optimized, pick is inlined and the frame is main's call of it, line 22.)
    symbolized "$mode" panic
    grep -E 'crash\.ab:(17|22):' "$out/$mode-panic.symbolized" > /dev/null ||
        fail "symbolize: no crash.ab:17 or :22 for the --$mode panic: $(cat "$out/$mode-panic.symbolized")"
done
# Wine loads the program at its preferred base; Windows moves it (ASLR). The same stack, as if loaded at 0x7ff6a0000000:
# symbolize takes each address less the load address at the image's base, so file:line is the same.
moved=$((0x7ff6a0000000 - 0x140000000))
while read -r first rest; do
    if [[ $first =~ ^0x[0-9a-f]{16}$ && $first != 0x00006f* ]]; then printf '0x%016x %s\n' $((first + moved)) "$rest"
    elif [[ $first == load ]]; then printf 'load address 0x%016x\n' $((0x140000000 + moved))
    else printf '%s %s\n' "$first" "$rest"; fi
done < "$out/backtrace-store.err" > "$out/aslr-store.err"
grep '^load address 0x00007ff6a0000000$' "$out/aslr-store.err" > /dev/null || fail "the moved stack: $(cat "$out/aslr-store.err")"
"$compiler" symbolize "$out/crash-backtrace.exe" "$out/aslr-store.err" > "$out/aslr-store.symbolized" 2>&1 || true
grep 'crash\.ab:11:' "$out/aslr-store.symbolized" > /dev/null ||
    fail "symbolize: no crash.ab:11 for a stack loaded at 0x7ff6a0000000: $(cat "$out/aslr-store.symbolized")"
mv "$out/crash-backtrace.exe.debug" "$out/crash-backtrace.exe.moved"
symbolized backtrace store
! grep 'crash\.ab:' "$out/backtrace-store.symbolized" > /dev/null || fail "symbolize: file:line without crash-backtrace.exe.debug"
mv "$out/crash-backtrace.exe.moved" "$out/crash-backtrace.exe.debug"
echo "windows-crash: panics, a bad store and a stack overflow report as on Linux under Wine (release, --backtrace, --fast), and symbolize gives their file:line"
