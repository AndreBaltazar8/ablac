#!/usr/bin/env bash
# Builds macOS stage 1 (the pinned bootstrap compiling the current sources) under a watchdog: after <seconds> it
# samples every compiler/clang process (macOS `sample`), prints their stacks and the build log's tail, and stops the
# build, so a hang names the code it hangs in instead of burning the job's whole time limit.
# Usage: tools/probe/stage1-watchdog.sh <seconds> <bootstrap-compiler> <output-compiler>
set -uo pipefail
seconds=${1:?usage: stage1-watchdog.sh <seconds> <bootstrap> <output>}
bootstrap=${2:?}
output=${3:?}
mkdir -p build/probe
tools/build-self-hosted-current.sh "$bootstrap" "$output" > build/probe/stage1.log 2>&1 &
build=$!
elapsed=0
while kill -0 "$build" 2>/dev/null; do
    if (( elapsed >= seconds )); then
        echo "stage 1 is still running after $elapsed s: sampling"
        ps -axo pid,ppid,etime,%cpu,command | grep -E 'ablac|clang|llc|lld|ld64|/ld ' | grep -v grep || true
        for pid in $(pgrep -f 'ablac|clang') ; do
            [[ $pid == $$ ]] && continue
            sample "$pid" 5 -file "build/probe/sample-$pid.txt" > /dev/null 2>&1 || continue
            echo "== sample of process $pid ($(ps -p "$pid" -o command= | cut -c1-120))"
            sed -n '1,60p' "build/probe/sample-$pid.txt"
        done
        echo "== tail of the build log"
        tail -n 40 build/probe/stage1.log
        pkill -P "$build" || true
        kill "$build" 2>/dev/null || true
        exit 3
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
wait "$build"
status=$?
echo "stage 1 finished in about $elapsed s with status $status"
tail -n 5 build/probe/stage1.log
exit $status
