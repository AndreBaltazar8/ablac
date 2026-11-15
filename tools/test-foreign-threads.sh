#!/usr/bin/env bash
# #811: a shared library of the default x86-64 Linux target is entered from threads it did not start, at the same time
# (a host's UI thread and workers): 1, 4 and 8 pthreads call one export that allocates (so the collector runs between
# calls: with and without ABLA_GC_STRESS=1, a collection at every safe point), and a nested export runs while the
# library's globals initialize (a global's initializer calls the host, which calls an export). Each caller's strings
# must survive the others' garbage. Without the enter/leave guards in the export thunks this crashes (SIGSEGV from four
# callers on). The Android library gets the same checks under bionic's linker in tools/test-android-run.sh.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then echo 'foreign threads: x86-64 Linux only'; exit 0; fi
out=build/foreign-threads
rm -rf "$out"
mkdir -p "$out"
fail() { echo "foreign threads: $1" >&2; exit 1; }
"$compiler" build tests/cases/foreign-threads/lib.ab --emit shared-library -o "$out/lib.so" --no-cache > "$out/build.log" 2>&1 \
    || { cat "$out/build.log" >&2; fail 'the library did not build'; }
clang tests/cases/android-run/driver.c -o "$out/driver" -ldl -lpthread -Wl,--export-dynamic || fail 'the driver did not build'
status=0
"$out/driver" "$PWD/$out/lib.so" abla_run_seed 78 abla_run_nested 77 > "$out/nested.out" 2>&1 < /dev/null || status=$?
[[ $status -eq 0 ]] || { cat "$out/nested.out" >&2; fail "a nested export during initialization failed ($status)"; }
for stress in 0 1; do
    for count in 1 4 8; do
        status=0
        ABLA_GC_STRESS=$stress timeout 300 "$out/driver" "$PWD/$out/lib.so" -t "$count" abla_run_churn 1 \
            > "$out/threads-$stress-$count.out" 2>&1 < /dev/null || status=$?
        [[ $status -eq 0 ]] || { cat "$out/threads-$stress-$count.out" >&2; fail "$count threads, GC stress $stress: status $status"; }
    done
done
echo 'foreign threads: concurrent callers of a shared library and a nested export during initialization'
