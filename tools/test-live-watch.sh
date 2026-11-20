#!/usr/bin/env bash
# `ablac run --watch` (src/live_watch.ab): a copy of tests/cases/live-watch/program.ab runs, and this script edits it
# the way an editor saves (a new file renamed over the old one).
# - edit: value() returns 2 after the save; the program sees it and exits 42; the reload's outcome is on stderr.
# - cached: the same run again starts from the object cache and is reloaded on a save too.
# - broken: a save that does not compile keeps the program running its code (stderr says so), a file of the same
#   directory that is not the program's (an output) reloads nothing, and the next good save is applied (exit 42).
# - moved: renaming label()'s parameter applies (nothing takes it as a value), and a line names its redefined callers.
# - restart: a save the running code cannot take (tests/cases/live-watch/restart.ab: a result type changes) restarts
#   the run; the restarted run does not restart again for the same refusal, and the next good save is applied.
# x86-64 Linux and macOS (an ablac that runs on AArch64 Linux is not built). Usage: tools/test-live-watch.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) == Linux && $(uname -m) != x86_64 ]]; then
    echo "live watch: skipped ($(uname -s) $(uname -m): no ablac is built for it)"
    exit 0
fi
out=$root/build/live-watch
rm -rf "$out"
mkdir -p "$out"
export ABLA_CACHE_DIR=$out/cache
# The program's main runs on a thread of the compiler's, which the compiler counts as in native code while the
# program runs: a collection of the compiler's (during a reload's compile) never waits for it in vain. Under
# ABLA_GC_TRACE=1 a stop that gives up says "stop abandoned"; none may (checked at the end).
export ABLA_GC_TRACE=1

pid=
trap '[[ -n $pid ]] && kill "$pid" 2> /dev/null || true' EXIT

start() {   # start NAME [FILE]: runs a fresh copy of FILE (program.ab) under --watch and waits until main started
    local name=$1
    mkdir -p "$out/$name"
    cp "$root/tests/cases/live-watch/${2:-program.ab}" "$out/$name/program.ab"
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

save() {   # save EXPRESSION FILE: FILE edited by the sed EXPRESSION, written next to it and renamed over it
    sed "$1" "$2" > "$2.saving"
    mv "$2.saving" "$2"
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
save 's|= 1 // value-marker|= 2 // value-marker|' "$out/edit/program.ab"
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
save 's|= 1 // value-marker|= 2 // value-marker|' "$out/edit/program.ab"
finish edit
grep -q '^ablac run --watch: applied: value' "$out/edit/stderr" ||
    { echo 'live watch (cached): the save was not applied' >&2; cat "$out/edit/stderr" >&2; exit 1; }

# moved: a changed signature that applies (label's parameter renamed; nothing takes it as a value) says which
# redefined callers it reaches through: main, which never returns, keeps its old body.
start moved
save 's|fun label(x: int): int = x \* 0 // label-marker|fun label(y: int): int = y * 0 // label-marker|' "$out/moved/program.ab"
wait_lines moved 1
grep -q "^live: label's signature changed; callers redefined: main (it applies when they are entered again)$" \
    "$out/moved/stderr" ||
    { echo 'live watch (moved): no note on the changed signature and its callers' >&2; cat "$out/moved/stderr" >&2; exit 1; }
save 's|= 1 // value-marker|= 2 // value-marker|' "$out/moved/program.ab"
finish moved

# broken
start broken
save 's|= 1 // value-marker|= ) // value-marker|' "$out/broken/program.ab"
wait_lines broken 1
grep -q 'the program keeps running its code' "$out/broken/stderr" ||
    { echo 'live watch (broken): the failed reload was not reported' >&2; cat "$out/broken/stderr" >&2; exit 1; }
kill -0 "$pid" 2> /dev/null || { echo 'live watch (broken): the program ended after a broken save' >&2; exit 1; }
echo output > "$out/broken/output.txt"
sleep 1
[[ $(lines broken) -eq 1 ]] || { echo 'live watch (broken): a file that is not the program reloaded it' >&2; cat "$out/broken/stderr" >&2; exit 1; }
save 's|= ) // value-marker|= 2 // value-marker|' "$out/broken/program.ab"
finish broken
grep -q '^ablac run --watch: applied: value' "$out/broken/stderr" ||
    { echo 'live watch (broken): the good save was not applied' >&2; cat "$out/broken/stderr" >&2; exit 1; }

# restart: a save the running code cannot take (value()'s result type changes, E_LIVE_SIGNATURE) restarts the run, the
# same process with the same arguments, on the saved source (one line on stderr says why). The restarted run's first
# reload, refused for the same reason (the type changed back), does not restart again: it says so and keeps running
# its code, and a later save it can take is applied (exit 42).
start restart restart.ab
first=$pid
rm -f "$out/restart/started"
save 's|^fun value(): int = 1 // value-marker|fun value(): i32 = 3 // value-marker|' "$out/restart/program.ab"
for _ in $(seq 600); do
    [[ $(cat "$out/restart/started" 2> /dev/null) == 'started 3' ]] && break
    kill -0 "$pid" 2> /dev/null || break
    sleep 0.1
done
[[ $(cat "$out/restart/started" 2> /dev/null) == 'started 3' ]] ||
    { echo 'live watch (restart): the program did not start again on the saved source' >&2; cat "$out/restart/stderr" >&2; exit 1; }
[[ $(grep -c '^ablac run --watch: restarting the program: E_LIVE_SIGNATURE: value' "$out/restart/stderr") -eq 1 ]] ||
    { echo 'live watch (restart): no one line naming the refused function' >&2; cat "$out/restart/stderr" >&2; exit 1; }
[[ $pid == "$first" ]] && kill -0 "$pid" 2> /dev/null ||
    { echo 'live watch (restart): the run did not stay the same process' >&2; exit 1; }
rm -f "$out/restart/started"
save 's|^fun value(): i32 = 3 // value-marker|fun value(): int = 1 // value-marker|' "$out/restart/program.ab"
wait_lines restart 2
grep -q '^ablac run --watch: refused again after a restart, not restarting; the program keeps running its code: E_LIVE_SIGNATURE: value' "$out/restart/stderr" ||
    { echo 'live watch (restart): the same refusal after a restart restarted again' >&2; cat "$out/restart/stderr" >&2; exit 1; }
sleep 1
[[ ! -e $out/restart/started ]] || { echo 'live watch (restart): the program started a third time' >&2; exit 1; }
save 's|^fun value(): int = 1 // value-marker|fun value(): i32 = 2 // value-marker|' "$out/restart/program.ab"
finish restart
grep -q '^ablac run --watch: applied: value' "$out/restart/stderr" ||
    { echo 'live watch (restart): the save after the refusal was not applied' >&2; cat "$out/restart/stderr" >&2; exit 1; }
if grep -l 'stop abandoned' "$out"/*/stderr > /dev/null 2>&1; then
    echo 'live watch: a collection of the compiler gave up waiting for the thread that runs the program' >&2
    grep -h 'stop abandoned' "$out"/*/stderr | head -n 5 >&2
    exit 1
fi
echo "live watch: a save is applied while the program runs; a broken one keeps it running; a refused one restarts it, once for the same reason; the compiler collects meanwhile"
