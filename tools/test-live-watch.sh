#!/usr/bin/env bash
# `ablac run --watch` (src/live_watch.ab): a copy of tests/cases/live-watch/program.ab runs, and this script edits it
# the way an editor saves (a new file renamed over the old one, `sed -i`).
# - edit: value() returns 2 after the save; the program sees it and exits 42; the reload's outcome is on stderr.
# - cached: the same run again starts from the object cache and is reloaded on a save too.
# - broken: a save that does not compile keeps the program running its code (stderr says so), a file of the same
#   directory that is not the program's (an output) reloads nothing, and the next good save is applied (exit 42).
# x86-64 Linux, where live mode is tested. Usage: tools/test-live-watch.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo "live watch: skipped ($(uname -s) $(uname -m): live mode is tested on x86-64 Linux)"
    exit 0
fi
out=$root/build/live-watch
rm -rf "$out"
mkdir -p "$out"
export ABLA_CACHE_DIR=$out/cache

pid=
trap '[[ -n $pid ]] && kill "$pid" 2> /dev/null || true' EXIT

start() {   # start NAME: runs a fresh copy under --watch and waits until main started
    local name=$1
    mkdir -p "$out/$name"
    cp "$root/tests/cases/live-watch/program.ab" "$out/$name/program.ab"
    "$compiler" run --watch "$out/$name/program.ab" -- "$out/$name/started" \
        > "$out/$name/stdout" 2> "$out/$name/stderr" &
    pid=$!
    for _ in $(seq 600); do
        [[ -f $out/$name/started ]] && return 0
        kill -0 "$pid" 2> /dev/null || break
        sleep 0.1
    done
    echo "live watch ($name): the program did not start" >&2
    cat "$out/$name/stderr" >&2
    exit 1
}

finish() {   # finish NAME: waits for the program, which must exit 42
    local name=$1
    local status=0
    wait "$pid" || status=$?
    pid=
    if [[ $status -ne 42 ]]; then
        echo "live watch ($name): exit $status, not 42" >&2
        cat "$out/$name/stdout" "$out/$name/stderr" >&2
        exit 1
    fi
}

lines() {   # lines NAME: the reload outcomes so far
    grep -c '^ablac run --watch: ' "$out/$1/stderr" || true
}

wait_lines() {   # wait_lines NAME COUNT: until COUNT outcomes were printed
    for _ in $(seq 600); do
        [[ $(lines "$1") -ge $2 ]] && return 0
        sleep 0.1
    done
    echo "live watch ($1): no reload outcome after a save (expected $2)" >&2
    cat "$out/$1/stderr" >&2
    exit 1
}

# edit
start edit
sed -i 's|= 1 // value-marker|= 2 // value-marker|' "$out/edit/program.ab"
finish edit
grep -q '^ablac run --watch: applied: value' "$out/edit/stderr" ||
    { echo 'live watch (edit): no "applied: value" on stderr' >&2; cat "$out/edit/stderr" >&2; exit 1; }
[[ $(lines edit) -eq 1 ]] || { echo "live watch (edit): $(lines edit) reloads for one save" >&2; cat "$out/edit/stderr" >&2; exit 1; }

# cached: the same program at the same path again starts from the object cache (the files to watch come from the
# cache's record, not from a compile) and is still reloaded on a save.
rm -f "$out/edit/started"
export ABLA_JIT_CACHE_TRACE=1
start edit
unset ABLA_JIT_CACHE_TRACE
grep -q '^\[jit-cache\] hit ' "$out/edit/stderr" ||
    { echo 'live watch (cached): the second run did not start from the cache' >&2; cat "$out/edit/stderr" >&2; exit 1; }
sed -i 's|= 1 // value-marker|= 2 // value-marker|' "$out/edit/program.ab"
finish edit
grep -q '^ablac run --watch: applied: value' "$out/edit/stderr" ||
    { echo 'live watch (cached): the save was not applied' >&2; cat "$out/edit/stderr" >&2; exit 1; }

# broken
start broken
sed -i 's|= 1 // value-marker|= ) // value-marker|' "$out/broken/program.ab"
wait_lines broken 1
grep -q 'the program keeps running its code' "$out/broken/stderr" ||
    { echo 'live watch (broken): the failed reload was not reported' >&2; cat "$out/broken/stderr" >&2; exit 1; }
kill -0 "$pid" 2> /dev/null || { echo 'live watch (broken): the program ended after a broken save' >&2; exit 1; }
echo output > "$out/broken/output.txt"
sleep 1
[[ $(lines broken) -eq 1 ]] || { echo 'live watch (broken): a file that is not the program reloaded it' >&2; cat "$out/broken/stderr" >&2; exit 1; }
sed -i 's|= ) // value-marker|= 2 // value-marker|' "$out/broken/program.ab"
finish broken
grep -q '^ablac run --watch: applied: value' "$out/broken/stderr" ||
    { echo 'live watch (broken): the good save was not applied' >&2; cat "$out/broken/stderr" >&2; exit 1; }
echo "live watch: a save is applied while the program runs; a broken one keeps it running"
