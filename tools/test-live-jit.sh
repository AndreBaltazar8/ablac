#!/usr/bin/env bash
# A live `ablac run` (docs/design/live-jit.md, src/backend/llvm/live.ab): every function of the
# program's own files is called through the live table, so that a later generation can redefine
# it. tests/cases/live-jit/calls.ab reaches functions every way a call can (direct, recursive, by
# value, by closure, from a thread, a generator, a method; struct, string and scalar results) and
# must print the same lines and exit 42 live and with --no-live, release (--o1) and --fast. The
# live runs (the default on x86-64 Linux and macOS) must report that functions went through the table (ABLA_LIVE_TRACE),
# and a --no-live run must not. The object cache is off, so each run compiles.
# Then tests/cases/live-jit/reload.ab redefines its own functions while it runs (abla/live), also when
# the live run starts from the object cache, and tests/cases/live-jit/refuse.ab checks the refusals.
# Usage: tools/test-live-jit.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler != */* || $compiler == /* ]] || compiler=$PWD/$compiler
cd "$root"
out=build/live-jit
rm -rf "$out"
mkdir -p "$out"
export ABLA_JIT_CACHE=0 ABLA_LIVE_TRACE=1
# A wall-clock limit: GNU timeout where there is one, the repository's limiter elsewhere (the Mac runners have no timeout).
limited() {
    if command -v timeout > /dev/null; then timeout 300 "$@"; else ABLA_MAX_SECONDS=300 tools/run-limited.sh "$@"; fi
}
# A run killed by a signal: the step it was in (the program prints each check as it passes, so it died in the one
# after the last), and on macOS the crash report's exception and faulting thread (ReportCrash writes it a moment
# later, into ~/Library/Logs/DiagnosticReports).
started=$out/started
died() {   # died NAME STATUS OUTPUT
    local name=$1 status=$2 output=$3 last report
    ((status > 128 && status < 160)) || return 0
    last=$(grep ': ok' "$output" | tail -n 1 | sed 's/: ok.*//' || true)
    printf 'live jit (%s): killed by signal %s in the step after the check "%s"\n' "$name" "$((status - 128))" \
        "${last:-(none passed)}" >&2
    [[ $(uname -s) == Darwin ]] || return 0
    report=
    for _ in $(seq 30); do
        report=$(find "$HOME/Library/Logs/DiagnosticReports" -name "*.ips" -newer "$started" 2> /dev/null | xargs ls -t 2> /dev/null | head -n 1 || true)
        [[ -n $report ]] && break
        sleep 1
    done
    if [[ -z $report ]]; then
        echo "live jit ($name): no crash report" >&2
        return 0
    fi
    echo "live jit ($name): crash report $report" >&2
    grep -A 8 '"exception"' "$report" >&2 || true
    sed -n '/"triggered" : true/,/"triggered"/p' "$report" | head -n 200 >&2 || true
    grep -A 40 '"threadState"' "$report" | grep -E '"(pc|lr|far|esr)"' -A 1 >&2 || true
}
# under_lldb PROFILE: on macOS, the reload again under lldb (at most three times, until it stops other than by
# exiting 42): the trace naming where the code is (ABLA_LIVE_TRACE), then at the stop the backtrace, the
# registers and the code around the pc and the return address.
under_lldb() {
    [[ $(uname -s) == Darwin ]] && command -v lldb > /dev/null || return 0
    local binary=$compiler attempt
    [[ -f $compiler.bin ]] && binary=$compiler.bin
    for attempt in 1 2 3; do
        cp tests/cases/live-jit/reload.ab "$reload"
        limited lldb --batch -o run \
            -k 'thread backtrace' -k 'register read' \
            -k 'disassemble --start-address $pc-256 --count 96' \
            -k 'disassemble --start-address $lr-128 --count 48' -k kill \
            -- "$binary" run "--$1" --live "$reload" -- "$reload" > "$out/lldb.out" 2>&1 || true
        if grep -q 'stop reason' "$out/lldb.out" && ! grep -q 'exited with status = 42' "$out/lldb.out"; then
            echo "live jit (reload, $1, under lldb, attempt $attempt):" >&2
            grep -v ': ok (' "$out/lldb.out" | tail -n 600 >&2
            return 0
        fi
    done
    echo "live jit (reload, $1, under lldb): it did not stop in three attempts" >&2
    tail -n 20 "$out/lldb.out" >&2
}
touch "$started"
program=tests/cases/live-jit/calls.ab
run() {
    local name=$1
    shift
    local status=0
    "$compiler" run "$@" "$program" > "$out/$name.out" 2> "$out/$name.err" || status=$?
    if [[ $status -ne 42 ]]; then
        printf 'live jit (%s): exit status %s (42 expected)\n' "$name" "$status" >&2
        head -n 20 "$out/$name.out" "$out/$name.err" >&2
        died "$name" "$status" "$out/$name.out"
        exit 1
    fi
}
# `ablac run` is live by default on x86-64 Linux and macOS (decision #65): there the live run gives no flag, and
# elsewhere it asks with --live; --no-live runs it as before.
live_flags=()
[[ $(uname -s) == Darwin || $(uname -m) == x86_64 ]] || live_flags=(--live)
for profile in o1 fast; do
    run "plain-$profile" "--$profile" --no-live
    run "live-$profile" "--$profile" ${live_flags[@]+"${live_flags[@]}"}
    if ! cmp -s "$out/plain-$profile.out" "$out/live-$profile.out"; then
        echo "live jit ($profile): a live run prints differently" >&2
        diff "$out/plain-$profile.out" "$out/live-$profile.out" | head -n 20 >&2
        exit 1
    fi
    count=$(sed -n 's/^live: \([0-9]*\) functions through the table$/\1/p' "$out/live-$profile.err")
    if [[ -z $count || $count -lt 10 ]]; then
        printf 'live jit (%s): the live run reports %s functions through the table (10 or more expected)\n' \
            "$profile" "${count:-no}" >&2
        cat "$out/live-$profile.err" >&2
        exit 1
    fi
    if grep -q '^live:' "$out/plain-$profile.err"; then
        echo "live jit ($profile): a run with --no-live went through the table" >&2
        exit 1
    fi
done
calls="$(wc -l < "$out/live-o1.out" | tr -d ' ') lines alike live and with --no-live (--o1 and --fast), $count functions through the table"
# Redefinition (stage 2): tests/cases/live-jit/reload.ab edits a copy of itself and calls liveReload();
# see its header for the checks. With --no-live the same program must find reloading unavailable.
reload=$PWD/$out/reload/main.ab
mkdir -p "$out/reload"
for profile in o1 fast; do
    cp tests/cases/live-jit/reload.ab "$reload"
    status=0
    # The note on the code reloads leave (never freed): --fast with a limit of one byte must print it once for
    # its several applied reloads, --o1 under the default (256 MB) never.
    limit=268435456
    [[ $profile == fast ]] && limit=1
    # The --o1 run keeps its reload modules (ABLA_LIVE_DUMP_MODULE), for the thread-local check below.
    dump=
    [[ $profile == o1 ]] && dump=$PWD/$out/module
    (
        if [[ $profile == o1 ]]; then export ABLA_LIVE_DUMP_DISPATCHER=1; fi
        ABLA_LIVE_DUMP_MODULE=$dump ABLA_LIVE_NOTE_BYTES=$limit limited "$compiler" run "--$profile" --live "$reload" -- "$reload"
    ) \
        > "$out/reload-$profile.out" 2> "$out/reload-$profile.err" || status=$?
    if [[ $status -ne 42 ]] || grep -q ': FAIL' "$out/reload-$profile.out"; then
        printf 'live jit (reload, %s): exit status %s (42 expected)\n' "$profile" "$status" >&2
        cat "$out/reload-$profile.out" >&2
        grep '^live: ' "$out/reload-$profile.err" >&2 || true
        grep -v '^live: ' "$out/reload-$profile.err" | head -n 30 >&2 || true
        died "reload, $profile" "$status" "$out/reload-$profile.out"
        ((status > 128 && status < 160)) && under_lldb "$profile"
        exit 1
    fi
    notes=$(grep -c "^ablac run: the reloads of this live run have added " "$out/reload-$profile.err" || true)
    expected=0
    [[ $profile == fast ]] && expected=1
    if [[ $notes -ne $expected ]]; then
        printf "live jit (reload, %s): %s notes on the code reloads leave, %s expected\n" "$profile" "$notes" "$expected" >&2
        cat "$out/reload-$profile.err" >&2
        exit 1
    fi
done
# The dispatcher's forward to the generation that has a new lambda passes the output as sret, as every
# dispatcher takes it: AArch64 passes sret in x8, so without it the other dispatcher read the output where its
# closure belongs and trapped (arm64 Macs, runs 44586994389 to 44654107874). x86-64 passes sret as the first
# argument, so this reads the IR, which shows it on any host.
forward=$(awk '/IR of abla_llvm_call_indirect_live/ { inside = 1 } inside && /^live\.forward:/ { getline; print; exit }' \
    "$out/reload-o1.err")
if [[ $forward != *'(ptr sret(%AblaValue) '* ]]; then
    printf 'live jit (forward): the forward to a new lambda'"'"'s dispatcher is not sret: %s\n' \
        "${forward:-(no dispatcher printed)}" >&2
    exit 1
fi
# A reload brings its own copies of runtime functions the running program never emitted (the new variables'
# runtime entry and leave, among others). Their thread-local storage must be the running program's, named after
# its function (abla_thread_local_<function>_<n>): a name LLVM numbered in emission order named some other
# thread-local of the running program in the reload's module. Every thread-local a reload module has is named so.
# LLVM prints a thread-local as `thread_local(initialexec)` where the JIT uses initial-exec (Linux) and as plain
# `thread_local` in the general-dynamic model (macOS, where ORC then emulates it): both forms count.
modules=$(find "$out" -maxdepth 1 -name 'module-*.ll' | wc -l)
numbered=$(grep -hE ' thread_local[ (]' "$out"/module-*.ll 2> /dev/null | grep -Evc '^@(__abla_unit\.)?abla_thread_local_' || true)
named=$(grep -hE ' thread_local[ (]' "$out"/module-*.ll 2> /dev/null | grep -Ec '^@(__abla_unit\.)?abla_thread_local_' || true)
if [[ $modules -eq 0 || $named -eq 0 || $numbered -ne 0 ]]; then
    printf 'live jit (thread-locals): %s reload modules, %s thread-locals named after their function, %s not\n' \
        "$modules" "$named" "$numbered" >&2
    grep -hE ' thread_local[ (]' "$out"/module-*.ll 2> /dev/null | grep -Ev '^@(__abla_unit\.)?abla_thread_local_' | head -n 5 >&2
    exit 1
fi
rm -f "$out"/module-*.ll
# ABLA_LIVE_JIT_REPEAT=n: the cold --o1 reload n times more, for an intermittent failure in a new lambda's call
# (run 44586994389). Each round edits its own source and records its own stdout, diagnostics, and exit status.
run_repeat() {
    local round_dir=$out/repeat-$1 status=0
    local source=$PWD/$round_dir/main.ab
    mkdir -p "$round_dir"
    cp tests/cases/live-jit/reload.ab "$source"
    touch "$round_dir/started"
    limited "$compiler" run --o1 --live "$source" -- "$source" \
        > "$round_dir/stdout" 2> "$round_dir/stderr" || status=$?
    printf '%s\n' "$status" > "$round_dir/status"
}
repeat=${ABLA_LIVE_JIT_REPEAT:-0}
[[ $repeat =~ ^[0-9]+$ ]] || { echo "live jit: ABLA_LIVE_JIT_REPEAT must be a count, got $repeat" >&2; exit 1; }
if ((repeat > 0)); then
    workers=${JOBS:-1}
    [[ $workers =~ ^[1-9][0-9]*$ ]] || { echo "live jit: JOBS must be positive, got $workers" >&2; exit 1; }
    # A round runs the compiler and live threads. Leave CPUs for them even in a wide suite.
    ((workers <= 2)) || workers=2
    export -f limited run_repeat
    export compiler out
    seq "$repeat" | xargs -n 1 -P "$workers" bash -euo pipefail -c 'run_repeat "$1"' _
    failed=0
    for round in $(seq "$repeat"); do
        round_dir=$out/repeat-$round
        status=$(< "$round_dir/status")
        [[ $status -eq 42 ]] && ! grep -q ': FAIL' "$round_dir/stdout" && continue
        failed=$((failed + 1))
        printf 'live jit (repeat %s): exit status %s (42 expected)\n' "$round" "$status" >&2
        grep -v ': ok' "$round_dir/stdout" >&2 || true
        started=$round_dir/started died "repeat $round" "$status" "$round_dir/stdout"
    done
    echo "live jit: the reload again $repeat times, $failed failed"
    ((failed > 0)) && under_lldb o1
    ((failed == 0)) || exit 1
fi
# A live run from the object cache (stage 2c): the first run compiles and keeps the object with the
# compiler's record (<object>.live); the second, on a fresh copy, must start from the cache and still reload.
for round in compile cached; do
    cp tests/cases/live-jit/reload.ab "$reload"
    status=0
    ABLA_JIT_CACHE=1 ABLA_JIT_CACHE_TRACE=1 ABLA_CACHE_DIR=$PWD/$out/cache limited "$compiler" run --live "$reload" -- "$reload" \
        > "$out/reload-$round.out" 2> "$out/reload-$round.err" || status=$?
    if [[ $status -ne 42 ]] || grep -q ': FAIL' "$out/reload-$round.out"; then
        printf 'live jit (reload, %s): exit status %s (42 expected)\n' "$round" "$status" >&2
        cat "$out/reload-$round.out" >&2
        head -n 30 "$out/reload-$round.err" >&2
        died "reload, $round" "$status" "$out/reload-$round.out"
        exit 1
    fi
done
if ! grep -q '^\[jit-cache\] hit ' "$out/reload-cached.err"; then
    echo "live jit (reload, cached): the second live run did not start from the object cache" >&2
    cat "$out/reload-cached.err" >&2
    exit 1
fi
# The refusals (stage 2b): tests/cases/live-jit/refuse.ab, see its header.
refuse=$PWD/$out/reload/refuse.ab
cp tests/cases/live-jit/refuse.ab "$refuse"
cp tests/cases/live-jit/refuse_other.ab "$(dirname "$refuse")/refuse_other.ab"
status=0
limited "$compiler" run --live "$refuse" -- "$refuse" > "$out/refuse.out" 2> "$out/refuse.err" || status=$?
if [[ $status -ne 42 ]] || grep -q ": FAIL" "$out/refuse.out"; then
    printf 'live jit (refusals): exit status %s (42 expected)\n' "$status" >&2
    cat "$out/refuse.out" >&2
    head -n 30 "$out/refuse.err" >&2
    died refusals "$status" "$out/refuse.out"
    exit 1
fi
cp tests/cases/live-jit/reload.ab "$reload"
status=0
limited "$compiler" run --no-live "$reload" -- "$reload" > "$out/reload-plain.out" 2>&1 || status=$?
if [[ $status -eq 42 ]] || ! grep -q '^live available: FAIL' "$out/reload-plain.out"; then
    echo "live jit (reload with --no-live): reloading was not refused as unavailable (exit $status)" >&2
    cat "$out/reload-plain.out" >&2
    exit 1
fi
echo "live jit: $calls; reload: $(grep -c ': ok' "$out/reload-o1.out") checks (--o1 and --fast), $(grep -c ": ok" "$out/refuse.out") refusal checks, unavailable with --no-live"
