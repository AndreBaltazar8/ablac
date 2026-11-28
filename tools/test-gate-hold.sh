#!/usr/bin/env bash
# tools/gate-hold.sh: a gate's suite lends its slot hold only while it runs. A mark of a live holder is lent; a stale mark
# (its holder dead), a reused PID (another start time), a garbled mark and a missing one are not; and a borrowed command
# dies when its holder ends, its child processes too.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hold=$root/tools/gate-hold.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/gate-hold.XXXXXXXX")
pids=()
cleanup() {
    for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2> /dev/null || true; done
    rm -rf -- "$work"
}
trap cleanup EXIT
fail() { echo "test-gate-hold: $*" >&2; exit 1; }
mark=$work/hold.slot9

sleep 300 &
holder=$!
pids+=("$holder")
"$hold" mark "$mark" "$holder"
"$hold" live "$mark" || fail "a running holder's mark is not live"

# The same PID with another start time: a PID the system reused after the holder ended.
read -r pid start < "$mark"
printf '%s %s\n' "$pid" "$((start + 1))" > "$work/reused"
"$hold" live "$work/reused" && fail "a mark whose start time differs from its PID's process is live"
# A stale mark: its holder ended without removing it.
sleep 300 &
gone=$!
"$hold" mark "$work/stale" "$gone"
kill "$gone"
wait "$gone" 2> /dev/null || true
"$hold" live "$work/stale" && fail "a mark of a dead holder is live"
printf 'not a mark\n' > "$work/garbled"
"$hold" live "$work/garbled" && fail "a garbled mark is live"
"$hold" live "$work/missing" && fail "a missing mark is live"
# Only a regular file of this user's is a mark: a symlink to a live one is not (one in a shared directory could be anyone's).
ln -s "$mark" "$work/linked"
"$hold" live "$work/linked" && fail "a symlink to a live mark is live"
# A large file in the mark's place: only its first bytes are read.
head -c 1048576 /dev/zero | tr '\0' 7 > "$work/large"
"$hold" live "$work/large" && fail "a large file is a live mark"
status=0
"$hold" borrow "$work/stale" true || status=$?
[[ $status == 75 ]] || fail "a stale mark lent its hold (status $status)"

# A borrowed command runs to its end while the holder lives, with its own status.
status=0
"$hold" borrow "$mark" sh -c 'exit 3' || status=$?
[[ $status == 3 ]] || fail "a borrowed command's status was not kept (status $status)"
# The holder ends: the borrowed command and its children are killed, and borrow says it was cut (75).
sleep 300 &
short=$!
pids+=("$short")
"$hold" mark "$work/short" "$short"
( sleep 2; kill "$short" ) &
began=$(date +%s)
status=0
"$hold" borrow "$work/short" sh -c "sleep 300 & echo \$! > '$work/grandchild'; wait" || status=$?
[[ $status == 75 ]] || fail "a borrowed command outlived its holder (status $status)"
(($(date +%s) - began < 30)) || fail "a borrowed command took too long to stop"
grandchild=$(cat "$work/grandchild")
for _ in 1 2 3 4 5; do kill -0 "$grandchild" 2> /dev/null || break; sleep 1; done
kill -0 "$grandchild" 2> /dev/null && fail "a borrowed command's child outlived the holder"

# tools/gate.sh on a made-up tree, with fair-flock, nix-shell and make replaced by recorders: the suite marks its hold and
# removes the mark; builds with no live mark queue for both locks; builds with a live mark take no lock; builds whose
# holder ends first are cut and then queue for both locks.
tree=$work/tree
mkdir -p "$tree/tools" "$work/bin"
cp "$root/tools/gate.sh" "$hold" "$tree/tools/"
touch "$tree/shell.nix" "$tree/tools/run-limited-compiler.sh"
cat > "$tree/tools/bootstrap-compiler.sh" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$tree/tools/bootstrap-stages.sh" <<'SH'
#!/bin/sh
# --stages-1-2 | --stage-3
if [ "$3" = --stages-1-2 ]; then sleep "${FAKE_BUILD_SECONDS:-0}"; touch "$2/stage1" "$2/stage2"; echo stages built; fi
exit 0
SH
cat > "$tree/tools/test-pure-self-rebuild.sh" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$tree/tools/run-tests.sh" <<'SH'
#!/bin/sh
cat "$GATE_HOLD_MARK" > "$FAKE_SEEN_MARK" 2> /dev/null || true
echo "1 passed, 0 failed in 0s"
SH
cat > "$work/bin/fair-flock" <<'SH'
#!/bin/sh
[ "$1" = --close ] && shift
echo "$1" >> "$FAKE_LOCKS"
shift
exec "$@"
SH
cat > "$work/bin/nix-shell" <<'SH'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != --run ]; do shift; done
exec bash -c "$2"
SH
cat > "$work/bin/make" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$work/bin/taskset" <<'SH'
#!/bin/sh
shift 2
exec "$@"
SH
chmod +x "$tree"/tools/*.sh "$work"/bin/*
gate_run() { # what...: run the fake gate on slot 9
    PATH=$work/bin:$PATH FAIR_FLOCK=$work/bin/fair-flock GATE_HOLD_MARK=$work/gate.mark FAKE_LOCKS=$work/locks \
        FAKE_SEEN_MARK=$work/seen "$@" bash "$tree/tools/gate.sh" "$tree" 9
}
log=$tree/build/gate/gate.log

: > "$work/locks"
gate_run env || fail "the made-up gate failed: $(cat "$log")"
# A mark the suite cannot write does not fail the gate: the hold is only not lent. (root writes anywhere.)
if [[ $(id -u) != 0 ]]; then
    mkdir -m 500 "$work/readonly"
    gate_run env GATE_HOLD_MARK="$work/readonly/gate.mark" || fail "a mark that cannot be written failed the gate: $(cat "$log")"
    grep -q "could not mark its hold" "$log" || fail "an unwritten mark was not reported"
fi
: > "$work/locks"
gate_run env || fail "the made-up gate failed: $(cat "$log")"
[[ $(grep -c novakind-full-test "$work/locks") == 2 && $(grep -c novakind-build "$work/locks") == 2 ]] ||
    fail "without a mark the builds and the suite do not each take both locks: $(cat "$work/locks")"
read -r seen_pid _ < "$work/seen" || fail "the suite did not mark its hold"
[[ $seen_pid =~ ^[0-9]+$ ]] || fail "the suite's mark names no process"
[[ ! -e $work/gate.mark ]] || fail "the suite's mark outlived it"
# A mark path with a space in it (a HOME with one): marked and removed all the same.
mkdir "$work/with space"
rm -f "$work/seen"
gate_run env GATE_HOLD_MARK="$work/with space/gate.mark" || fail "a mark path with a space failed the gate: $(cat "$log")"
[[ -s $work/seen ]] || fail "the suite did not mark its hold at a path with a space"
[[ ! -e "$work/with space/gate.mark" ]] || fail "the suite's mark at a path with a space outlived it"

: > "$work/locks"
sleep 300 &
lender=$!
pids+=("$lender")
"$hold" mark "$work/gate.mark" "$lender"
gate_run env || fail "the made-up gate failed in a lent hold: $(cat "$log")"
[[ $(grep -c novakind "$work/locks") == 2 ]] || fail "builds in a lent hold took a lock: $(cat "$work/locks")"
grep -q "granted .*: builds (inside the slot's running suite's hold)" "$log" || fail "the log does not say the builds were lent a hold"
kill "$lender"

: > "$work/locks"
sleep 300 &
lender=$!
pids+=("$lender")
"$hold" mark "$work/gate.mark" "$lender"
( sleep 2; kill "$lender" ) &
gate_run env FAKE_BUILD_SECONDS=6 || fail "the made-up gate failed after its lender ended: $(cat "$log")"
grep -q "the suite whose hold the builds were in ended first" "$log" || fail "a cut build was not reported"
[[ $(grep -c novakind-full-test "$work/locks") == 2 && $(grep -c novakind-build "$work/locks") == 2 ]] ||
    fail "cut builds did not queue for both locks: $(cat "$work/locks")"
[[ $(grep -c '^stages built' "$log") == 1 ]] || fail "the cut builds did not build again under the locks"
echo "test-gate-hold: a live holder lends its hold; a stale, reused, garbled or missing mark does not; a borrowed command dies with its holder; gate.sh's builds borrow a live suite's hold, queue without one, and queue again when cut"
