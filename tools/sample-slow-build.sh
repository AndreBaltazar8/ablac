#!/usr/bin/env bash
# Started in the background by a CI step that runs a build in the foreground. While a process whose command line
# matches <pattern> lives, it waits; once the wall clock passes each given time (seconds since it started) it prints
# `sample` stacks of every ablac/clang process, so a build that hangs, or is only slow, leaves evidence of where it
# was instead of being killed blind at its time limit. It never stops the build. Ends when no such process is left.
# macOS only (`sample`).
# Usage: tools/sample-slow-build.sh <pattern> <seconds>...      e.g. tools/sample-slow-build.sh build-self-hosted 420 900
set -uo pipefail
pattern=${1:?usage: sample-slow-build.sh <pattern> <seconds>...}
shift
[[ $(uname -s) == Darwin ]] || exit 0
mkdir -p build/probe
SECONDS=0
pending=("$@")
sleep 3
while pgrep -f "$pattern" > /dev/null && (( ${#pending[@]} > 0 )); do
    if (( SECONDS >= pending[0] )); then
        mark=${pending[0]}
        pending=("${pending[@]:1}")
        echo "SAMPLER: the build is still running after $SECONDS s (sample point $mark s)"
        ps -axo pid,ppid,stat,etime,%cpu,command | grep -E 'ablac|clang|llc|lld|/ld |defunct| Z' | grep -v grep || true
        for pid in $(pgrep -f 'ablac|clang'); do
            [[ $pid == $$ ]] && continue
            sample "$pid" 5 -file "build/probe/sample-$mark-$pid.txt" > /dev/null 2>&1 || continue
            echo "== SAMPLER: process $pid ($(ps -p "$pid" -o command= | cut -c1-120)), first 50 lines"
            sed -n '1,50p' "build/probe/sample-$mark-$pid.txt"
        done
    fi
    sleep 5
done
exit 0
