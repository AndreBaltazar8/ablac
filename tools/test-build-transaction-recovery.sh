#!/usr/bin/env bash
set -euo pipefail
# A build stopped before it ends its transaction (killed, or stopped by a panic)
# leaves the transaction in build/; the next build in that directory ends it and
# removes it. Builds of one program are killed at several points, each followed
# by a build of another program in the same directory: afterwards no transaction
# is left and the first program's outputs are all of one build, the earlier one
# or the killed one. Hand-made transactions check the rest: a commit under way is
# finished, any other dead transaction rolled back, a locked (running) one left
# alone, and an older compiler's (named by its process id alone) and other
# per-process scratch directories removed only once no process has their id.

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler=$project_root/$compiler
cases="$project_root/tests/cases/build-transaction-recovery"
work="$project_root/build/build-transaction-recovery"
rm -rf "$work"
mkdir -p "$work/out" "$work/sets"
cd "$work"
fail() {
    echo "build transaction recovery: $1" >&2
    exit 1
}
build() { # source output
    "$compiler" build "$cases/$1.ab" -o "out/$2" --fast --no-cache
}
outputs=(app app.abi.json app.ll app.o app.host.o app.raw-runtime.o app.o.bc)
save_set() { # name
    mkdir -p "sets/$1"
    for output in "${outputs[@]}"; do
        if [[ -e out/$output ]]; then cp "out/$output" "sets/$1/$output"; fi
    done
}
same_set() { # name
    local output
    for output in "${outputs[@]}"; do
        if [[ -e sets/$1/$output ]]; then
            cmp -s "sets/$1/$output" "out/$output" || return 1
        else
            [[ ! -e out/$output ]] || return 1
        fi
    done
}
transactions() {
    compgen -G "build/.abla-build-transaction-*" || true
}

build two app
save_set two
build one app
save_set one
set +e
out/app
status=$?
set -e
[[ $status -eq 1 ]] || fail "the first program exited $status"

# Kill points: the transaction just begun, and the new LLVM text, object and
# executable written (the build may also end first).
kill_points=(transaction app.ll app.o app)
signals=(KILL TERM KILL TERM)
reached() { # point
    if [[ $1 == transaction ]]; then
        compgen -G "build/.abla-build-transaction-*" > /dev/null
    else
        [[ out/$1 -nt stamp ]]
    fi
}
index=0
for point in "${kill_points[@]}"; do
    signal=${signals[$index]}
    touch stamp
    setsid "$compiler" build "$cases/two.ab" -o out/app --fast --no-cache \
        > "kill-$index.log" 2>&1 &
    pid=$!
    deadline=$((SECONDS + 120))
    while kill -0 "$pid" 2>/dev/null && ! reached "$point" && ((SECONDS < deadline)); do
        sleep 0.005
    done
    pkill "-$signal" -s "$pid" || true
    { wait "$pid"; } 2>/dev/null || true
    left=$(transactions)
    build other other
    [[ -z $(transactions) ]] ||
        fail "a transaction is left after a build killed at $point ($signal): $(transactions)"
    if same_set one; then
        expected=1
    elif same_set two; then
        expected=2
    else
        fail "a build killed at $point ($signal) left mixed outputs (transaction left: ${left:-none})"
    fi
    set +e
    out/app
    status=$?
    set -e
    [[ $status -eq $expected ]] || fail "after a kill at $point the program exited $status"
    # Back to the first program's outputs for the next point.
    build one app
    same_set one || fail "rebuilding the first program changed its outputs"
    index=$((index + 1))
done

# Hand-made journals: entries x (replaced), y (moved aside and not rebuilt), z
# (removed on purpose) and w (new).
journal() { # directory
    mkdir -p "$1"
    local index=0 name
    for name in x y z w; do
        printf '%s' "$work/files/$name" > "$1/$index.path"
        if [[ $name == w ]]; then
            printf 0 > "$1/$index.existed"
        else
            printf 1 > "$1/$index.existed"
            printf 'old %s' "$name" > "$1/$index.data"
        fi
        index=$((index + 1))
    done
    printf 1 > "$1/2.dropped"
    rm -rf files
    mkdir files
    printf 'new x' > files/x
    printf 'new w' > files/w
}
content() { # name
    if [[ -e files/$1 ]]; then cat "files/$1"; else printf missing; fi
}
dead=999999999
journal "build/.abla-build-transaction-$dead-1"
: > "build/.abla-build-transaction-$dead-1/lock"
printf 1 > "build/.abla-build-transaction-$dead-1/committing"
build other other
[[ -z $(transactions) ]] || fail "a dead build's commit is left"
[[ "$(content x),$(content y),$(content z),$(content w)" == "new x,old y,missing,new w" ]] ||
    fail "a dead build's commit was not finished: $(content x),$(content y),$(content z),$(content w)"

journal "build/.abla-build-transaction-$dead-2"
: > "build/.abla-build-transaction-$dead-2/lock"
build other other
[[ -z $(transactions) ]] || fail "a dead build's transaction is left"
[[ "$(content x),$(content y),$(content z),$(content w)" == "old x,old y,old z,missing" ]] ||
    fail "a dead build's transaction was not rolled back: $(content x),$(content y),$(content z),$(content w)"

# A running build's transaction (its lock held) stays, whatever its id.
journal "build/.abla-build-transaction-$dead-3"
flock -o "build/.abla-build-transaction-$dead-3/lock" sleep 60 &
holder=$!
while ! [[ -e build/.abla-build-transaction-$dead-3/lock ]]; do sleep 0.01; done
sleep 0.2
build other other
[[ -e build/.abla-build-transaction-$dead-3/0.data ]] || fail "a running build's transaction was touched"
[[ "$(content x),$(content w)" == "new x,new w" ]] || fail "a running build's outputs were touched"
kill "$holder"
wait "$holder" || true
build other other
[[ -z $(transactions) ]] || fail "a transaction is left after its lock was let go"

# An older compiler's transaction: removed, outputs untouched, once its process
# has gone; kept while a process has its id. So are scratch directories.
sleep 60 &
alive=$!
journal "build/.abla-build-transaction-$dead"
mkdir -p "build/.abla-build-transaction-$alive" \
    "build/.abla-program-requests-$dead" "build/.abla-compile-outputs-$alive"
printf x > "build/.abla-build-transaction-$alive/0.path"
printf x > "build/.abla-program-requests-$dead/0.name"
build other other
[[ ! -e build/.abla-build-transaction-$dead ]] || fail "an older compiler's dead transaction is left"
[[ "$(content x),$(content y),$(content w)" == "new x,missing,new w" ]] ||
    fail "removing an older compiler's transaction changed outputs"
[[ ! -e build/.abla-program-requests-$dead ]] || fail "a dead build's scratch directory is left"
[[ -e build/.abla-build-transaction-$alive/0.path ]] || fail "a live process's transaction was removed"
[[ -d build/.abla-compile-outputs-$alive ]] || fail "a live process's scratch directory was removed"
kill "$alive"
wait "$alive" || true
build other other
[[ -z $(transactions) ]] || fail "an older compiler's transaction is left once its process has gone"
[[ ! -e build/.abla-compile-outputs-$alive ]] || fail "a scratch directory is left once its process has gone"

# A build that stops on finding no runtime puts its outputs back and leaves no
# transaction.
if [[ -x $compiler.bin ]]; then
    mkdir -p no-runtime
    printf 'earlier' > no-runtime/m
    status=0
    (cd no-runtime && env -u ABLA_SYSROOT -u ABLA_STDLIB "$compiler.bin" build \
        "$cases/one.ab" -o m --no-cache) > no-runtime.log 2>&1 || status=$?
    [[ $status -ne 0 ]] && grep -q E_TOOLCHAIN_ROOT no-runtime.log ||
        fail "a build with no runtime in reach did not stop on it"
    [[ -z $(compgen -G "no-runtime/build/.abla-build-transaction-*") ]] ||
        fail "a build with no runtime in reach left its transaction"
    [[ $(cat no-runtime/m) == earlier ]] ||
        fail "a build with no runtime in reach did not put its output back"
fi

build two app
same_set two || fail "the last build's outputs differ from the second program's"
[[ -z $(transactions) ]] || fail "a finished build left its transaction"
echo "build transaction recovery: killed builds' transactions are ended by the next build, outputs whole"
