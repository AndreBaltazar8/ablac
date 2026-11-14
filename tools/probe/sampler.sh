#!/usr/bin/env bash
# Started in the background by the step that runs the build in the foreground, exactly as ci.yml does: while the
# build script runs, wait; if it is still running after <seconds>, `sample` every compiler/clang process, print the
# stacks, and stop the build (so a hang names its code and the step fails soon). Ends when the build script is gone.
# Usage: tools/probe/sampler.sh <seconds>
set -uo pipefail
seconds=${1:?usage: sampler.sh <seconds>}
mkdir -p build/probe
elapsed=0
sleep 3
while pgrep -f build-self-hosted-current > /dev/null; do
    if (( elapsed >= seconds )); then
        echo "SAMPLER: the build is still running after $elapsed s"
        ps -axo pid,ppid,etime,%cpu,command | grep -E 'ablac|clang|llc|lld|/ld ' | grep -v grep || true
        for pid in $(pgrep -f 'ablac|clang'); do
            [[ $pid == $$ ]] && continue
            sample "$pid" 5 -file "build/probe/sample-$pid.txt" > /dev/null 2>&1 || continue
            echo "== SAMPLER: sample of process $pid ($(ps -p "$pid" -o command= | cut -c1-120))"
            sed -n '1,60p' "build/probe/sample-$pid.txt"
        done
        pkill -f build-self-hosted-current || true
        pkill -f 'ablac' || true
        exit 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
echo "SAMPLER: the build finished after about $elapsed s"
