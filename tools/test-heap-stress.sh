#!/usr/bin/env bash
# Eight threads hammering the heap (tests/cases/heap-stress), repeated, under a watchdog: a run that does not finish in
# <seconds> (default 120) is a hang (a lost wakeup on the heap's lock, say); on macOS its processes are sampled
# (`sample`), on Linux its threads' kernel stacks are printed (/proc/<pid>/task/*/stack when readable), and the
# script fails. Built release and --fast. Usage: tools/test-heap-stress.sh [compiler] [seconds] [repeats]
set -uo pipefail
compiler=${1:-build/ablac}
limit=${2:-120}
repeats=${3:-3}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/heap-stress"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build "$project_root/tests/cases/heap-stress/main.ab" -o "$out/main.$mode" "${flags[@]}" || exit 1
    for repeat in $(seq 1 "$repeats"); do
        "$out/main.$mode" > "$out/run.$mode.$repeat.out" 2>&1 &
        pid=$!
        waited=0
        while kill -0 "$pid" 2> /dev/null; do
            if (( waited >= limit )); then
                echo "heap stress ($mode, run $repeat): still running after $waited s: a hang" >&2
                if [[ $(uname -s) == Darwin ]]; then
                    sample "$pid" 5 -file "$out/hang.$mode.$repeat.txt" > /dev/null 2>&1 && sed -n '1,120p' "$out/hang.$mode.$repeat.txt" >&2
                else
                    for task in /proc/"$pid"/task/*; do
                        echo "thread ${task##*/}: $(cat "$task/stat" 2> /dev/null | cut -d' ' -f3) $(cat "$task/wchan" 2> /dev/null)" >&2
                    done
                fi
                kill -9 "$pid" 2> /dev/null
                exit 1
            fi
            sleep 1
            waited=$((waited + 1))
        done
        wait "$pid"
        status=$?
        if [[ $status -ne 0 || $(tail -n 1 "$out/run.$mode.$repeat.out") != 'heap stress ok' ]]; then
            echo "heap stress ($mode, run $repeat): exit $status" >&2
            head -n 10 "$out/run.$mode.$repeat.out" >&2
            exit 1
        fi
    done
done
echo "heap stress ok ($repeats runs each, release and --fast)"
