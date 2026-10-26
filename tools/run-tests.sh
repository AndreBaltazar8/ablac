#!/usr/bin/env bash
# Runs the test suite's commands (the recipe of `make test-serial`) several at a
# time: `make test`, or
#
#   tools/run-tests.sh [compiler]
#
# Each command runs in the repository root, with its output in a log of its
# own. The commands that can't share the machine with the others (listed in
# serial_reason below) run afterwards, one at a time. The longest commands of
# the last run start first.
#
# Environment:
#   JOBS                 commands run at once (default: the number of CPUs)
#   RUN_TESTS_MIN_FREE   no command starts while the system's free memory is
#                        under this percentage, unless none is running
#                        (default 25; 0 turns the check off)
#   RUN_TESTS_OUTPUT     the results directory (default build/test-results/suite;
#                        emptied first)
#   RUN_TESTS_COMMANDS   a file of commands, one per line, to run instead of the
#                        recipe (with $(COMPILER) already substituted)
#   RUN_TESTS_FILTER     an extended regex: run only the commands it matches
#   RUN_TESTS_EXCLUDE    an extended regex: leave out the commands it matches
#                        (a step a caller already runs on its own)
#   RUN_TESTS_HISTORY    the results of an earlier run (a results.tsv) whose
#                        times order this one (default: the last run's, kept in
#                        build/test-results/suite-history.tsv)
#
# Results: <output>/results.tsv (n, exit status, seconds, command; n is the
# command's place in the recipe), <output>/<n>.log, and <output>/failures.txt
# (one line per failed command). Exits 1 when any command failed.
set -uo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
min_free=${RUN_TESTS_MIN_FREE:-25}
output=${RUN_TESTS_OUTPUT:-$project_root/build/test-results/suite}
filter=${RUN_TESTS_FILTER:-}
exclude=${RUN_TESTS_EXCLUDE:-}
history_file=$project_root/build/test-results/suite-history.tsv
history=${RUN_TESTS_HISTORY:-$history_file}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "JOBS must be a positive integer, got $jobs" >&2; exit 2; }
[[ $output == /* ]] || output=$PWD/$output

cd "$project_root" || exit 1
rm -rf "$output"
mkdir -p "$output"

# Why a command must run alone (empty: it runs alongside the others).
serial_reason() { # command
    case $1 in
        *tools/test-self-hosted.sh*)
            # Its driver reruns several of the suite's own scripts
            # (test-nominal-scalars, test-unsafe-stack-memory, ...) in the
            # same build directories, and runs eight tests at a time itself.
            echo "reruns suite scripts in their build directories; parallel itself" ;;
        *tools/test-compile-time-parity.sh*)
            echo "builds PARITY_JOBS cases at a time itself" ;;
    esac
}

# The system's free memory, in percent (100 where it can't be read).
free_percent() {
    if command -v memory_pressure >/dev/null 2>&1; then
        memory_pressure 2>/dev/null |
            awk -F': ' '/free percentage/ { gsub("%", "", $2); print $2 + 0; found = 1 }
                END { if (!found) print 100 }'
    elif [[ -r /proc/meminfo ]]; then
        awk '/^MemTotal:/ { total = $2 } /^MemAvailable:/ { available = $2 }
            END { print (total > 0 ? int(available * 100 / total) : 100) }' /proc/meminfo
    else
        echo 100
    fi
}

seconds_now() { perl -MTime::HiRes=time -e 'printf "%.1f\n", time'; }

# The commands, one per line.
if [[ -n ${RUN_TESTS_COMMANDS:-} ]]; then
    cp "$RUN_TESTS_COMMANDS" "$output/commands.txt"
else
    MAKEFLAGS= MFLAGS= make -s -n -o ablac -o "$compiler" test-serial \
        COMPILER="$compiler" >"$output/commands.txt" || exit 2
fi

# "<seconds> <n>" for every selected command, the longest of the last run
# first (unknown ones keep the recipe's order, after the known ones).
order() {
    local n=0 command
    while IFS= read -r command; do
        n=$((n + 1))
        [[ -z $command ]] && continue
        [[ -z $filter || $command =~ $filter ]] || continue
        [[ -n $exclude && $command =~ $exclude ]] && continue
        printf '%s\t%s\n' "$n" "$command"
    done <"$output/commands.txt" |
        awk -F'\t' -v history="$history" -v compiler="$compiler" '
            function key(command) {
                # The compiler differs between runs; the command does not.
                gsub(/[^ ;]*ablac[^ ;]*/, "COMPILER", command)
                return command
            }
            BEGIN {
                while ((getline line < history) > 0) {
                    split(line, field, "\t")
                    if (field[3] ~ /^[0-9.]+$/) known[key(field[4])] = field[3]
                }
            }
            { k = key($2); print (k in known ? known[k] : -1) "\t" $1 }' |
        sort -t "$(printf '\t')" -k1,1nr -k2,2n | cut -f2
}

parallel=()
serial=()
while IFS= read -r n; do
    command=$(sed -n "${n}p" "$output/commands.txt")
    if [[ -n $(serial_reason "$command") ]]; then
        serial+=("$n")
    else
        parallel+=("$n")
    fi
done < <(order)

running_pids=()
running_ns=()
failed=0
passed=0
started_at=$(seconds_now)

# Starts command n in the background; it writes "<status> <seconds>" to
# <output>/<n>.done when it ends.
start() { # n
    local n=$1 command
    command=$(sed -n "${n}p" "$output/commands.txt")
    (
        begin=$(seconds_now)
        bash -c "$command" >"$output/$n.log" 2>&1 </dev/null
        status=$?
        end=$(seconds_now)
        printf '%s %s\n' "$status" "$(awk -v b="$begin" -v e="$end" 'BEGIN { printf "%.1f", e - b }')" \
            >"$output/$n.done.next"
        mv -f "$output/$n.done.next" "$output/$n.done"
    ) &
    running_pids+=("$!")
    running_ns+=("$n")
}

# Records every command that has ended; keeps the rest running.
reap() {
    local index pids=() ns=() n status seconds command
    ((${#running_ns[@]} > 0)) || return 0
    for index in "${!running_ns[@]}"; do
        n=${running_ns[$index]}
        if [[ -f $output/$n.done ]]; then
            wait "${running_pids[$index]}" 2>/dev/null
            read -r status seconds <"$output/$n.done"
            rm -f "$output/$n.done"
            command=$(sed -n "${n}p" "$output/commands.txt")
            printf '%s\t%s\t%s\t%s\n' "$n" "$status" "$seconds" "$command" >>"$output/results.tsv"
            if [[ $status -eq 0 ]]; then
                passed=$((passed + 1))
                printf 'PASS %6ss  %s\n' "$seconds" "$command"
            else
                failed=$((failed + 1))
                printf 'FAIL %6ss  %s (exit %s, log %s)\n' "$seconds" "$command" "$status" "$output/$n.log"
                printf '%s\t%s\t%s\n' "$n" "$status" "$command" >>"$output/failures.txt"
            fi
        else
            pids+=("${running_pids[$index]}")
            ns+=("$n")
        fi
    done
    running_pids=(${pids[@]+"${pids[@]}"})
    running_ns=(${ns[@]+"${ns[@]}"})
}

stop() {
    local pid
    for pid in ${running_pids[@]+"${running_pids[@]}"}; do
        pkill -TERM -P "$pid" 2>/dev/null
        kill -TERM "$pid" 2>/dev/null
    done
    exit 130
}
trap stop INT TERM

# Runs the given commands, at most `limit` at a time.
run_all() { # limit n...
    local limit=$1
    shift
    local pending=("$@") free
    while ((${#pending[@]} > 0 || ${#running_ns[@]} > 0)); do
        reap
        while ((${#pending[@]} > 0 && ${#running_ns[@]} < limit)); do
            if ((${#running_ns[@]} > 0 && min_free > 0)); then
                free=$(free_percent)
                ((free >= min_free)) || break
            fi
            start "${pending[0]}"
            pending=(${pending[@]+"${pending[@]:1}"})
        done
        ((${#running_ns[@]} > 0)) && sleep 0.2
    done
}

echo "running ${#parallel[@]} commands, $jobs at a time, then ${#serial[@]} alone ($output)"
run_all "$jobs" ${parallel[@]+"${parallel[@]}"}
for n in ${serial[@]+"${serial[@]}"}; do
    echo "alone: $(sed -n "${n}p" "$output/commands.txt") ($(serial_reason "$(sed -n "${n}p" "$output/commands.txt")"))"
done
run_all 1 ${serial[@]+"${serial[@]}"}

sort -n -o "$output/results.tsv" "$output/results.tsv" 2>/dev/null
if [[ -z $filter && -s $output/results.tsv ]]; then
    mkdir -p "$(dirname "$history_file")" && cp "$output/results.tsv" "$history_file"
fi
elapsed=$(awk -v b="$started_at" -v e="$(seconds_now)" 'BEGIN { printf "%d", e - b }')
echo
echo "$passed passed, $failed failed in ${elapsed}s (JOBS=$jobs)"
if [[ $failed -gt 0 ]]; then
    while IFS=$'\t' read -r n status command; do
        echo "--- FAIL (exit $status) $command: $output/$n.log"
        tail -n 5 "$output/$n.log"
    done <"$output/failures.txt"
    exit 1
fi
