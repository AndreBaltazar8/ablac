#!/usr/bin/env bash
# #811: a shared library of the default x86-64 Linux target, or a macOS dylib, is entered from threads it did not start,
# at the same time (a host's UI thread and workers): 1, 4 and 8 pthreads call one export that allocates (so the collector
# runs between calls: with and without ABLA_GC_STRESS=1, a collection at every safe point), and a nested export runs while
# the library's globals initialize (a global's initializer calls the host, which calls an export). Each caller's strings
# must survive the others' garbage. Without the enter/leave guards in the export thunks this crashes (SIGSEGV from four
# callers on). On macOS (both Macs, from tools/test-macos-host.sh) the library is a dylib: its @hostImport hook stays
# undefined (-U), bound at load to the driver's export, and a dylib calling a symbol that is not @hostImport must not
# link. The Android library gets the same checks under bionic's linker in tools/test-android-run.sh.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
case "$(uname -s) $(uname -m)" in
    "Linux x86_64") library=lib.so; driver_flags=(-ldl -lpthread -Wl,--export-dynamic) ;;
    Darwin*) library=lib.dylib; driver_flags=(-Wl,-export_dynamic) ;;
    *) echo 'foreign threads: x86-64 Linux and macOS only'; exit 0 ;;
esac
out=build/foreign-threads
rm -rf "$out"
mkdir -p "$out"
fail() { echo "foreign threads: $1" >&2; exit 1; }
# A wall-clock limit: GNU timeout where there is one, the repository's limiter elsewhere (the Mac runners have no timeout).
limited() {
    if command -v timeout > /dev/null; then timeout 300 "$@"; else ABLA_MAX_SECONDS=300 tools/run-limited.sh "$@"; fi
}
"$compiler" build tests/cases/foreign-threads/lib.ab --emit shared-library -o "$out/$library" --no-cache > "$out/build.log" 2>&1 \
    || { cat "$out/build.log" >&2; fail 'the library did not build'; }
clang tests/cases/android-run/driver.c -o "$out/driver" "${driver_flags[@]}" || fail 'the driver did not build'
# @hostImport is for extern:"c" declarations only.
if "$compiler" build tests/cases/foreign-threads/misplaced.ab -o "$out/misplaced" --no-cache > "$out/misplaced.log" 2>&1 ||
    ! grep -q 'hostImport.extern:notAnImport' "$out/misplaced.log"; then
    cat "$out/misplaced.log" >&2; fail '@hostImport on an ordinary function was not refused'
fi
# Only the @hostImport symbols may stay undefined in a dylib: one that calls a symbol nobody defines must not link.
if [[ $library == lib.dylib ]]; then
    if "$compiler" build tests/cases/foreign-threads/missing.ab --emit shared-library -o "$out/missing.dylib" --no-cache \
        > "$out/missing.log" 2>&1 || ! grep -q 'abla_symbol_nobody_defines' "$out/missing.log"; then
        cat "$out/missing.log" >&2; fail 'a dylib with an undefined symbol that is not @hostImport linked'
    fi
fi
status=0
"$out/driver" "$PWD/$out/$library" abla_run_seed 78 abla_run_nested 77 > "$out/nested.out" 2>&1 < /dev/null || status=$?
[[ $status -eq 0 ]] || { cat "$out/nested.out" >&2; fail "a nested export during initialization failed ($status)"; }
for stress in 0 1; do
    for count in 1 4 8; do
        status=0
        ABLA_GC_STRESS=$stress ABLA_GC_TRACE=1 limited "$out/driver" "$PWD/$out/$library" -t "$count" abla_run_churn 1 \
            > "$out/threads-$stress-$count.out" 2>&1 < /dev/null || status=$?
        [[ $status -eq 0 ]] || { cat "$out/threads-$stress-$count.out" >&2; fail "$count threads, GC stress $stress: status $status"; }
        # The stress run really stresses: the library has no environment, the driver passes the variable on as a call.
        [[ $stress -eq 0 ]] || grep -q '^gc: stopped' "$out/threads-$stress-$count.out" \
            || fail "$count threads under GC stress: the library never collected (memorySetStress did not reach it)"
    done
done
# A thread blocked in the host's code inside an export counts as stopped for the collections of another thread (#811).
status=0
ABLA_GC_STRESS=1 limited "$out/driver" "$PWD/$out/$library" -b 1500 > "$out/blocked.out" 2>&1 < /dev/null || status=$?
[[ $status -eq 0 ]] || { cat "$out/blocked.out" >&2; fail "a thread blocked in the host was not stopped for a collection ($status)"; }
echo "foreign threads ($(uname -s)): concurrent callers of a shared library and a nested export during initialization"
