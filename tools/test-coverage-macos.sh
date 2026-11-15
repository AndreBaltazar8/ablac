#!/usr/bin/env bash
# --coverage-functions on a macOS executable (run from tools/test-macos-host.sh): the dump goes by the BSD system calls
# (getpid, open, write, close, rename, kill, sigaction, select), so the flag adds no libSystem import. The files a program
# ran are listed at main's return, exit(3), a panic and SIGTERM (status 143), %p is the pid, nothing is written without
# ABLA_COVERAGE_OUT, and two threads' hits reach the list. In --fast and release.
set -euo pipefail
if [[ $(uname -s) != Darwin ]]; then
    echo "coverage macos: Darwin only (Linux has tools/test-coverage.sh)"
    exit 0
fi
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
out="$project_root/build/coverage-macos"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root"
fixture=tests/cases/coverage/main.ab
fail() { echo "coverage macos: $1" >&2; [[ -z ${2:-} ]] || cat "$2" >&2; exit 1; }
expect_ran() {
    grep -qx 'tests/cases/coverage/main.ab' "$1" && grep -qx 'tests/cases/coverage/sub/used.ab' "$1" ||
        fail "missing a ran file in $1" "$1"
    ! grep -q 'unused.ab' "$1" || fail "unused.ab listed in $1" "$1"
    LC_ALL=C sort -c -u "$1" || fail "$1 is not sorted and unique" "$1"
    [[ ! -e $1.tmp ]] || fail "$1 left its .tmp"
}
for build in fast release; do
    flags=--fast; [[ $build == release ]] && flags=
    "$compiler" build "$fixture" -o "$out/flagged-$build" $flags --coverage-functions > "$out/build-$build.log" 2>&1 ||
        fail "the $build build failed" "$out/build-$build.log"
    imports=$(nm -u "$out/flagged-$build" | grep -E '^_(getenv|strstr|snprintf|getpid|open|close|write|rename|signal|raise|usleep)$' || true)
    [[ -z $imports ]] || fail "the $build dump imports from libSystem: $imports"
    for mode in return exit panic; do
        ABLA_COVERAGE_OUT="$out/$build-$mode.txt" "$out/flagged-$build" "$mode" > /dev/null 2>&1 || true
        expect_ran "$out/$build-$mode.txt"
    done
    ABLA_COVERAGE_OUT="$out/$build-pid-%p.txt" "$out/flagged-$build" return
    [[ $(ls "$out"/$build-pid-*.txt | wc -l) -eq 1 && ! -e "$out/$build-pid-%p.txt" ]] || fail "$build: %p was not the pid"
    (cd "$out" && env -u ABLA_COVERAGE_OUT "$out/flagged-$build" return)
    [[ -z $(ls "$out" | grep -v -e flagged -e '\.txt$' -e '\.log$') ]] || fail "$build wrote without the variable"
    # SIGTERM in --fast only: the fixture's wait is an empty loop, which a release build removes.
    [[ $build == fast ]] || continue
    ABLA_COVERAGE_OUT="$out/$build-term.txt" "$out/flagged-$build" wait & pid=$!
    sleep 1; kill -TERM "$pid"; status=0; wait "$pid" || status=$?
    [[ $status -eq 143 ]] || fail "$build: SIGTERM status $status, expected 143"
    expect_ran "$out/$build-term.txt"
done
"$compiler" build tests/cases/coverage/threads.ab -o "$out/threads" --fast --coverage-functions > "$out/threads.log" 2>&1 ||
    fail "the threads build failed" "$out/threads.log"
ABLA_COVERAGE_OUT="$out/threads.txt" "$out/threads" > /dev/null 2>&1 || true
grep -qx 'tests/cases/coverage/sub/third.ab' "$out/threads.txt" && grep -qx 'tests/cases/coverage/sub/used.ab' "$out/threads.txt" ||
    fail "a thread's file is missing" "$out/threads.txt"
echo "coverage macos: files listed at return, exit(), panic and SIGTERM (143), %p, threads; no libSystem import for the dump"
