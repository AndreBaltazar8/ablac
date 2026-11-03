#!/usr/bin/env bash
set -euo pipefail
# A build writes each file it publishes beside its name and renames it over it,
# so a build stopped anywhere (killed, or stopped by a panic) leaves each output
# whole, the earlier build's file or its own, and temporaries the next build of
# that output removes. Builds are killed at several points; then every output is
# one of the two builds' files, and the next build leaves no temporary and no
# scratch directory of the killed one. Transactions that compilers up to 0.2.32
# left in build/ are removed once their process has gone, outputs untouched.

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler=$project_root/$compiler
cases="$project_root/tests/cases/build-killed"
work="$project_root/build/build-killed"
rm -rf "$work"
mkdir -p "$work/out" "$work/sets"
cd "$work"
fail() {
    echo "build killed: $1" >&2
    exit 1
}
build() { # source output
    "$compiler" build "$cases/$1.ab" -o "out/$2" --fast --no-cache
}
outputs=(app app.abi.json app.o)
save_set() { # name
    mkdir -p "sets/$1"
    for output in "${outputs[@]}"; do cp "out/$output" "sets/$1/$output"; done
}
# Each output is the first or the second program's.
whole() {
    local output
    for output in "${outputs[@]}"; do
        [[ -f out/$output ]] || return 1
        cmp -s "sets/one/$output" "out/$output" || cmp -s "sets/two/$output" "out/$output" ||
            return 1
    done
}
temporaries() {
    compgen -G "out/*.tmp.*" || compgen -G "out/*.publish.*" || true
}
# Scratch directories in build/ of a process that has gone.
abandoned() {
    local entry owner
    for entry in build/.abla-*; do
        [[ -e $entry ]] || continue
        owner=${entry##*-}
        if [[ $owner =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then echo "$entry"; fi
    done
}

build two app
# Intermediate text is optional on the held-module path.
if [[ -f out/app.ll ]]; then outputs+=(app.ll); fi
save_set two
build one app
save_set one

# Kill points: just started, the new LLVM text written, the object on its way,
# the object written, the executable written (the build may also end first).
kill_points=(started app.o.tmp app.o app)
if [[ -f out/app.ll ]]; then kill_points=(started app.ll app.o.tmp app.o app); fi
reached() { # point
    case $1 in
        started) (($(date +%s%N) - started_at > 50000000)) ;;
        app.o.tmp) compgen -G "out/app.o.tmp.*" > /dev/null ;;
        *) [[ out/$1 -nt stamp ]] ;;
    esac
}
index=0
left_temporaries=0
for point in "${kill_points[@]}"; do
    signal=KILL
    if [[ $point == app.ll || $point == app.o ]]; then signal=TERM; fi
    touch stamp
    started_at=$(date +%s%N)
    setsid "$compiler" build "$cases/two.ab" -o out/app --fast --no-cache \
        > "kill-$index.log" 2>&1 &
    pid=$!
    deadline=$((SECONDS + 120))
    while kill -0 "$pid" 2>/dev/null && ! reached "$point" && ((SECONDS < deadline)); do
        sleep 0.002
    done
    pkill "-$signal" -s "$pid" || true
    { wait "$pid"; } 2>/dev/null || true
    whole || fail "a build killed at $point ($signal) left an output that is neither build's: $(ls out)"
    set +e
    out/app
    status=$?
    set -e
    [[ $status -eq 1 || $status -eq 2 ]] || fail "after a kill at $point the program exited $status"
    [[ -z $(temporaries) ]] || left_temporaries=$((left_temporaries + 1))
    # The next build of the output removes what the killed one left.
    build one app
    [[ -z $(temporaries) ]] || fail "temporaries left after the build following a kill at $point: $(temporaries)"
    [[ -z $(abandoned) ]] || fail "scratch left after the build following a kill at $point: $(abandoned)"
    for output in "${outputs[@]}"; do
        cmp -s "sets/one/$output" "out/$output" || fail "rebuilding after a kill at $point changed $output"
    done
    index=$((index + 1))
done
((left_temporaries > 0)) || fail "no kill landed while a temporary was on its way"

# Old transactions and scratch directories: removed once their process has gone,
# leaving the outputs they name as they are; kept while it runs.
mkdir -p files
printf 'new x' > files/x
sleep 60 &
alive=$!
dead=999999999
for owner in "$dead" "$dead-1" "$alive"; do
    mkdir -p "build/.abla-build-transaction-$owner"
    printf '%s' "$work/files/x" > "build/.abla-build-transaction-$owner/0.path"
    printf 1 > "build/.abla-build-transaction-$owner/0.existed"
    printf 'old x' > "build/.abla-build-transaction-$owner/0.data"
done
mkdir -p "build/.abla-program-requests-$dead" "build/.abla-compile-outputs-$alive"
build other other
[[ ! -e build/.abla-build-transaction-$dead && ! -e build/.abla-build-transaction-$dead-1 ]] ||
    fail "an old transaction of a process that has gone is left"
[[ $(cat files/x) == "new x" ]] || fail "removing an old transaction changed its output"
[[ ! -e build/.abla-program-requests-$dead ]] || fail "a scratch directory of a process that has gone is left"
[[ -e build/.abla-build-transaction-$alive/0.data ]] || fail "a running process's transaction was removed"
[[ -d build/.abla-compile-outputs-$alive ]] || fail "a running process's scratch directory was removed"
kill "$alive"
{ wait "$alive"; } 2>/dev/null || true
build other other
[[ -z $(compgen -G "build/.abla-build-transaction-*") ]] || fail "an old transaction is left once its process has gone"
[[ ! -e build/.abla-compile-outputs-$alive ]] || fail "a scratch directory is left once its process has gone"

build two app
for output in "${outputs[@]}"; do
    cmp -s "sets/two/$output" "out/$output" || fail "the last build's $output differs from the second program's"
done
[[ -z $(temporaries) ]] || fail "a finished build left temporaries: $(temporaries)"
echo "build killed: every output whole, the next build removes what a killed one left"
