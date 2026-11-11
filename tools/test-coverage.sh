#!/usr/bin/env bash
# --coverage-functions: the files a program ran, written at exit; nothing without the flag or the variable; refusals;
# no partial file after SIGKILL; a flagged build differs from an unflagged one and the unflagged is untouched.
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
out="$project_root/build/coverage"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root"
fixture=tests/cases/coverage/main.ab
"$compiler" build "$fixture" -o "$out/flagged" --fast --coverage-functions
"$compiler" build "$fixture" -o "$out/plain" --fast --no-cache
expect_ran() { # file: main and used.ab listed, unused.ab not
    grep -qx 'tests/cases/coverage/main.ab' "$1" && grep -qx 'tests/cases/coverage/sub/used.ab' "$1" || { echo "coverage: missing a ran file in $1"; cat "$1"; exit 1; }
    ! grep -q 'unused.ab' "$1" || { echo "coverage: unused.ab listed in $1"; exit 1; }
}
sorted() { LC_ALL=C sort -c "$1" && [ "$(LC_ALL=C sort -u "$1" | wc -l)" = "$(wc -l < "$1")" ]; }

for mode in return exit panic; do
    status=0
    ABLA_COVERAGE_OUT="$out/$mode.txt" "$out/flagged" "$mode" || status=$?
    expect_ran "$out/$mode.txt"; sorted "$out/$mode.txt"
    [ ! -e "$out/$mode.txt.tmp" ] || { echo "coverage: $mode left its .tmp"; exit 1; }
done
# %p becomes the pid; the unflagged build and an unset variable write nothing.
ABLA_COVERAGE_OUT="$out/pid-%p.txt" "$out/flagged" return
[ "$(ls "$out"/pid-*.txt | wc -l)" = 1 ] && ! ls "$out"/pid-%p.txt 2>/dev/null
ABLA_COVERAGE_OUT="$out/plain.txt" "$out/plain" return
[ ! -e "$out/plain.txt" ] || { echo "coverage: an unflagged build wrote a file"; exit 1; }
(cd "$out" && "$out/flagged" return) ; [ -z "$(ls "$out" | grep -v -e flagged -e plain -e '\.txt$')" ]
# A function that never ran does not list its file.
status=0; ABLA_COVERAGE_OUT="$out/never.txt" "$out/flagged" never || status=$?
grep -qx 'tests/cases/coverage/sub/unused.ab' "$out/never.txt" || { echo "coverage: a called function's file is missing"; exit 1; }
# SIGTERM dumps (default disposition): the status is 143, the file is complete.
ABLA_COVERAGE_OUT="$out/term.txt" "$out/flagged" wait & pid=$!
sleep 0.5; kill -TERM "$pid"; status=0; wait "$pid" || status=$?
[ "$status" = 143 ] || { echo "coverage: SIGTERM status $status, expected 143"; exit 1; }
expect_ran "$out/term.txt"
# SIGKILL leaves neither the file nor a partial one.
ABLA_COVERAGE_OUT="$out/kill.txt" "$out/flagged" wait & pid=$!
sleep 0.5; kill -KILL "$pid"; wait "$pid" 2>/dev/null || true
[ ! -e "$out/kill.txt" ] && [ ! -e "$out/kill.txt.tmp" ] || { echo "coverage: SIGKILL left a file"; exit 1; }
# Hits from two threads and the main thread, one dump (one complete file, no .tmp).
"$compiler" build tests/cases/coverage/threads.ab -o "$out/threads" --fast --coverage-functions
ABLA_COVERAGE_OUT="$out/threads.txt" "$out/threads" || true
grep -qx 'tests/cases/coverage/threads.ab' "$out/threads.txt" && grep -qx 'tests/cases/coverage/sub/used.ab' "$out/threads.txt" \
    && grep -qx 'tests/cases/coverage/sub/unused.ab' "$out/threads.txt" && grep -qx 'tests/cases/coverage/sub/third.ab' "$out/threads.txt" \
    || { echo "coverage: a thread's file is missing"; cat "$out/threads.txt"; exit 1; }
sorted "$out/threads.txt"; [ ! -e "$out/threads.txt.tmp" ]
# Two processes on one path (no %p) never mix: the temporary is per process.
for round in 1 2 3 4 5 6; do
    ABLA_COVERAGE_OUT="$out/shared.txt" "$out/flagged" return & ABLA_COVERAGE_OUT="$out/shared.txt" "$out/flagged" exit &
    wait || true
    expect_ran "$out/shared.txt"; sorted "$out/shared.txt"
done
[ -z "$(ls "$out" | grep 'shared.txt.tmp')" ] || { echo "coverage: a temporary was left"; exit 1; }
# A path that does not fit is refused, not truncated: 2040 "./" segments (4080 bytes) and a 30-byte file name make
# 4110; a truncation to 4095 would leave the valid file name "abcdefghijklmn", which must not appear (the kernel
# would refuse the full path too, so this tells our refusal from the open() failing).
pad=$(printf './%.0s' $(seq 1 2040))
(cd "$out" && ABLA_COVERAGE_OUT="${pad}abcdefghijklmnopqrstuvwxyz.txt" "$out/flagged" return) || true
[ -z "$(ls "$out" | grep -e '^abcdefghijklmn')" ] || { echo "coverage: a path of 4096 bytes or more was truncated and written"; exit 1; }
(cd "$out" && ABLA_COVERAGE_OUT="./short-ok.txt" "$out/flagged" return) || true
[ -e "$out/short-ok.txt" ] || { echo "coverage: a short relative path was not written"; exit 1; }
# A compile-time call in a flagged build: it builds, runs and the list holds the program's files only.
"$compiler" build tests/cases/coverage/ct.ab -o "$out/ct" --fast --coverage-functions
ABLA_COVERAGE_OUT="$out/ct.txt" ABLA_COVERAGE_TEST=1 "$out/ct" || true
grep -qx 'tests/cases/coverage/ct.ab' "$out/ct.txt" || { echo "coverage: the compile-time fixture's list is wrong"; exit 1; }
# Refused where it does not apply.
if "$compiler" build "$fixture" -o "$out/refused" --fast --coverage-functions --target-triple wasm32-unknown-unknown --object-format wasm --emit object > "$out/refused.log" 2>&1; then
    echo "coverage: wasm accepted the flag"; exit 1
fi
grep -q 'E_COVERAGE_TARGET' "$out/refused.log" || { cat "$out/refused.log"; echo "coverage: the refusal has no code"; exit 1; }
if "$compiler" build "$fixture" -o "$out/refused-mac" --fast --coverage-functions --target x86_64-macos > "$out/refused-mac.log" 2>&1; then
    echo "coverage: macOS accepted the flag"; exit 1
fi
grep -q E_COVERAGE_TARGET "$out/refused-mac.log" || { cat "$out/refused-mac.log"; exit 1; }
echo "coverage: files listed at exit, exit(), panic and SIGTERM; nothing for SIGKILL, an unset variable or an unflagged build; wasm refused"
