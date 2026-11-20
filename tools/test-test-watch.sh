#!/usr/bin/env bash
# `ablac test --watch` (src/test_watch.ab): tests/cases/test-watch/check.ab runs, and runs again when helper.ab, which
# it imports, changes: broken (FAIL, "failed"), then fixed (PASS, "passed"). A save of other.ab, in the same directory
# but not imported, runs nothing. Each edit is a new file renamed over the old one, as an editor saves.
# x86-64 Linux and macOS. Usage: tools/test-test-watch.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/test-watch
rm -rf "$out"
mkdir -p "$out/case"
cp "$root"/tests/cases/test-watch/*.ab "$out/case/"
cd "$out"

pid=
trap '[[ -n $pid ]] && kill "$pid" 2> /dev/null || true' EXIT

save() {   # save EXPRESSION FILE: FILE edited by the sed EXPRESSION, written next to it and renamed over it
    sed "$1" "$2" > "$2.saving"
    mv "$2.saving" "$2"
}

runs() {   # runs: the runs that finished so far
    grep -c '^ablac test --watch: ' "$out/stderr" || true
}

wait_runs() {   # wait_runs COUNT: until COUNT runs finished
    for _ in $(seq 1200); do
        [[ $(runs) -ge $1 ]] && return 0
        kill -0 "$pid" 2> /dev/null || break
        sleep 0.1
    done
    echo "test watch: no run $1 (expected after a save)" >&2
    cat "$out/stdout" "$out/stderr" >&2
    exit 1
}

"$compiler" test --watch case/check.ab > "$out/stdout" 2> "$out/stderr" &
pid=$!
wait_runs 1
grep -q '^ablac test --watch: passed; watching 2 files$' "$out/stderr" ||
    { echo 'test watch: the first run did not pass watching check.ab and helper.ab' >&2; cat "$out/stdout" "$out/stderr" >&2; exit 1; }
save 's|= 42 // answer-marker|= 41 // answer-marker|' case/helper.ab
wait_runs 2
[[ $(grep -c '^ablac test --watch: failed' "$out/stderr") -eq 1 ]] && grep -q '^FAIL ' "$out/stdout" ||
    { echo 'test watch: breaking an imported file did not fail the run again' >&2; cat "$out/stdout" "$out/stderr" >&2; exit 1; }
save 's|= 1 // other-marker|= 2 // other-marker|' case/other.ab
sleep 2
[[ $(runs) -eq 2 ]] || { echo 'test watch: a file the test does not read ran it again' >&2; cat "$out/stderr" >&2; exit 1; }
save 's|= 41 // answer-marker|= 42 // answer-marker|' case/helper.ab
wait_runs 3
[[ $(grep -c '^ablac test --watch: passed' "$out/stderr") -eq 2 ]] ||
    { echo 'test watch: fixing the imported file did not pass again' >&2; cat "$out/stdout" "$out/stderr" >&2; exit 1; }
echo "test watch: a save of an imported file runs the tests again (fail, then pass); another file runs nothing"
