#!/usr/bin/env bash
# Runs the test suite's commands (the recipe of `make test-serial`) several at a
# time: `make test`, or
#
#   tools/run-tests.sh [compiler]
#
# Each command runs in the repository root, with its output in a log of its
# own. The commands that can't run beside test-self-hosted.sh (listed in
# serial_reason below) start once it has ended. The longest commands of the last
# run start first.
#
# Scripts in tools/test-fast-builds.txt build at --fast; RUN_TESTS_FULL=1
# (`make test-full`) builds them for release.
#
# The suite's builds carry no DWARF line tables (ABLA_DEBUG=0, unless the caller sets
# ABLA_DEBUG): a --fast build's debug information is 7% to 9% of its compile time and
# no test but a few reads it. The scripts that read it (test-ct.sh,
# test-programmable-build.sh, test-wasm-debug-reproducible.sh) set ABLA_DEBUG=1 for
# themselves, and others build with an explicit -g. RUN_TESTS_DEBUG=default leaves
# ABLA_DEBUG unset (--fast builds carry debug information, release builds do not), the
# way the suite ran before; RUN_TESTS_DEBUG=1 sets ABLA_DEBUG=1 for every build. To triage
# a failing command, re-run it with RUN_TESTS_DEBUG=1: a crash then prints a stack with
# source locations, which a build without debug information cannot.
#
# Environment:
#   JOBS                 concurrent command slots (default: the number of CPUs)
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
# Results: <output>/results.tsv (n, exit status, seconds, command, CPU seconds
# of the command and what it ran; n is the command's place in the recipe), <output>/<n>.log, and <output>/failures.txt
# (one line per failed command). Exits 1 when any command failed.
set -uo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
case ${RUN_TESTS_DEBUG:-} in
    default) ;;
    1) export ABLA_DEBUG=1 ;;
    *) export ABLA_DEBUG=${ABLA_DEBUG:-0} ;;
esac
compiler=${1:-build/ablac}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
# A test that runs commands of its own at once (test-self-hosted, the compile-time parity harness) takes 2 workers
# under the suite, not one per CPU on top of these jobs: ABLA_SUITE_JOBS says it is running here.
export ABLA_SUITE_JOBS=$jobs
min_free=${RUN_TESTS_MIN_FREE:-25}
output=${RUN_TESTS_OUTPUT:-$project_root/build/test-results/suite}
filter=${RUN_TESTS_FILTER:-}
exclude=${RUN_TESTS_EXCLUDE:-}
history_file=$project_root/build/test-results/suite-history.tsv
history=${RUN_TESTS_HISTORY:-$history_file}
# A tree that has not run the suite yet has no history: tools/test-times.tsv (a results.tsv of a whole run, refreshed
# now and then) orders the longest commands first there too.
[[ -s $history ]] || history=$project_root/tools/test-times.tsv
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "JOBS must be a positive integer, got $jobs" >&2; exit 2; }
[[ $output == /* ]] || output=$PWD/$output

cd "$project_root" || exit 1
rm -rf "$output"
mkdir -p "$output"

# The suite's builds share the default cache, so a rerun reuses what the same
# compiler built. Its entries key on the compiler: another one's are only garbage.
# A caller may pass the payload itself. readlink -f also accepts a missing
# final component, so only select a companion that actually exists.
compiler_payload=$compiler
[[ ! -f $compiler.bin ]] || compiler_payload=$compiler.bin
compiler_stamp=$(cksum <"$compiler_payload" 2>/dev/null || true)
stamp_file=$project_root/build/.abla-cache.compiler
if [[ -z $compiler_stamp || ! -f $stamp_file || $(<"$stamp_file") != "$compiler_stamp" ]]; then
    rm -rf "$project_root/build/.abla-cache"
    printf '%s\n' "$compiler_stamp" >"$stamp_file"
fi

# Why a command waits for test-self-hosted.sh (empty: it needn't), whose driver
# reruns these suite scripts in the same build directories.
serial_reason() { # command
    case $1 in
        *tools/test-borrow-lifetimes.sh* | *tools/test-floating-point.sh* | \
        *tools/test-nominal-scalars.sh* | *tools/test-unsafe-stack-memory.sh* | \
        *tools/test-local-shadowing.sh* | *tools/test-eval-steps.sh* | \
        *tools/test-borrow-duplicates.sh*)
            echo "test-self-hosted.sh reruns it in the same build directory" ;;
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

# Cache command text and self-hosted membership once, including blank recipe lines.
# Indexed arrays keep this compatible with the macOS system Bash (3.2).
commands=()
self_hosted_commands=()
while IFS= read -r command; do
    commands+=("$command")
    if [[ $command == *tools/test-self-hosted.sh* ]]; then
        self_hosted_commands[${#commands[@]}]=1
    fi
done <"$output/commands.txt"

# RUN_TESTS_SHARD=i/n runs shard i of n (1-based). The largest wall-time commands start on separate shards. The remaining units
# are dealt out by CPU seconds, else wall seconds, else 20, largest first to the cheapest shard so far. test-self-hosted.sh and
# the commands that wait for it are one unit (they share its build directories).
# The same history file (tools/test-times.tsv, or the last run's) makes the same split on every machine of a CI matrix: a run's history must not
# decide it, so a sharded run reads tools/test-times.tsv only. tools/test-shards.sh checks the split.
shard_index=1
shard_count=1
if [[ -n ${RUN_TESTS_SHARD:-} ]]; then
    [[ $RUN_TESTS_SHARD =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] || { echo "RUN_TESTS_SHARD must look like 1/2, got $RUN_TESTS_SHARD" >&2; exit 2; }
    shard_index=${BASH_REMATCH[1]}
    shard_count=${BASH_REMATCH[2]}
    ((shard_index <= shard_count)) || { echo "RUN_TESTS_SHARD: shard $shard_index of $shard_count" >&2; exit 2; }
    history=$project_root/tools/test-times.tsv
fi
# A release-mode run (RUN_TESTS_FULL=1: the release's static suite, gate-release) splits by tools/test-times-release.tsv where it
# knows a command: release-mode builds cost differently, and a test such as test-image-identity.sh is long only there (1,420 s
# in release run 45983722873, where the fast-mode table's split put it on test-self-hosted.sh's shard).
shard_release_times=
if [[ -n ${RUN_TESTS_FULL:-} && -s $project_root/tools/test-times-release.tsv ]]; then shard_release_times=$project_root/tools/test-times-release.tsv; fi
shard_filter() { # "n<TAB>command<TAB>group" lines in, the lines of this shard out
    if ((shard_count == 1)); then cat; return; fi
    awk -F'\t' -v history="$project_root/tools/test-times.tsv" -v release="$shard_release_times" -v idx="$shard_index" -v count="$shard_count" '
        function key(command) { gsub(/[^ ;]*ablac[^ ;]*/, "COMPILER", command); return command }
        function read_times(file,    line, field, k) {
            while ((getline line < file) > 0) {
                split(line, field, "\t")
                if (field[3] ~ /^[0-9.]+$/) {
                    k = key(field[4]); wall[k] = field[3] + 0
                    cost[k] = (field[5] + 0 > 0 ? field[5] + 0 : wall[k])
                }
            }
            close(file)
        }
        BEGIN {
            read_times(history)
            if (release != "") read_times(release)
        }
        {
            lines++; number[lines] = $1; text[lines] = $0
            k = key($2); u = ($3 == 1 ? 0 : lines)
            unit[lines] = u; unitcost[u] += (k in cost ? cost[k] : 20)
            w = (k in wall ? wall[k] : 20)
            if (w > unitwall[u]) unitwall[u] = w
            if (!(u in first)) first[u] = lines
        }
        END {
            # The units by cost, longest first (ties: the earlier command).
            for (u in unitcost) order[++units] = u + 0
            for (i = 1; i <= units; i++) for (j = i + 1; j <= units; j++) {
                a = order[i]; b = order[j]
                if (unitcost[b] > unitcost[a] || (unitcost[b] == unitcost[a] && first[b] < first[a])) { order[i] = b; order[j] = a }
            }
            for (s = 1; s <= count; s++) load[s] = 0
            # Keep the longest indivisible commands apart before balancing CPU work.
            for (s = 1; s <= count && s <= units; s++) {
                leader = -1
                for (i = 1; i <= units; i++) {
                    u = order[i]
                    if (u in shard) continue
                    if (leader < 0 || unitwall[u] > unitwall[leader] ||
                        (unitwall[u] == unitwall[leader] && first[u] < first[leader])) leader = u
                }
                shard[leader] = s; load[s] = unitcost[leader]
            }
            for (i = 1; i <= units; i++) {
                if (order[i] in shard) continue
                best = 1
                for (s = 2; s <= count; s++) if (load[s] < load[best]) best = s
                shard[order[i]] = best; load[best] += unitcost[order[i]]
            }
            for (l = 1; l <= lines; l++) if (shard[unit[l]] == idx) print text[l]
        }' | cut -f1,2
}

# "<seconds> <n>" for every selected command, the longest of the last run
# first (unknown ones keep the recipe's order, after the known ones).
order() {
    local n=0 command
    while IFS= read -r command; do
        n=$((n + 1))
        [[ -z $command ]] && continue
        [[ -z $filter || $command =~ $filter ]] || continue
        [[ -n $exclude && $command =~ $exclude ]] && continue
        # The third column is 1 for what must run in the same shard as test-self-hosted.sh (it and the commands that wait for it).
        group=0
        [[ $command == *tools/test-self-hosted.sh* || -n $(serial_reason "$command") ]] && group=1
        printf '%s\t%s\t%s\n' "$n" "$command" "$group"
    done <"$output/commands.txt" | shard_filter |
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
            # test-self-hosted.sh goes first of all: the commands in serial_reason wait for it, so a late start
            # of it leaves them (and the run) waiting at the end.
            { k = key($2); rank = (k in known ? known[k] : -1); if ($2 ~ /tools\/test-self-hosted\.sh/) rank = 1000000
              print rank "\t" $1 }' |
        sort -t "$(printf '\t')" -k1,1nr -k2,2n | cut -f2
}

parallel=()
serial=()
while IFS= read -r n; do
    command=${commands[n-1]}
    if [[ -n $(serial_reason "$command") ]]; then
        serial+=("$n")
    else
        parallel+=("$n")
    fi
done < <(order)

# RUN_TESTS_LIST=1: print the numbers of the selected commands, one per line (the parallel ones, then the ones waiting for test-self-hosted.sh), and stop.
if [[ -n ${RUN_TESTS_LIST:-} ]]; then printf '%s\n' ${parallel[@]+"${parallel[@]}"} ${serial[@]+"${serial[@]}"}; exit 0; fi

# The playground test builds two release archives concurrently, and the
# editor stress requests can use parallel marking. Reserve slots for some
# of that internal work when the suite is already oversubscribed.
source "$project_root/tools/suite-wall-limit.sh"
suite_cpus=$(suite_cpu_count "$jobs")
command_slots=()
if [[ $suite_cpus =~ ^[1-9][0-9]*$ ]] && ((jobs > suite_cpus)); then
    for n in ${parallel[@]+"${parallel[@]}"} ${serial[@]+"${serial[@]}"}; do
        case ${commands[n-1]} in
            *tools/test-playground-build.sh*) slots=3 ;;
            *tools/test-image-identity.sh*) slots=3 ;;   # three compiler-sized builds at once
            *tools/test-analysis-gc-stress.sh*) slots=2 ;;
            *) continue ;;
        esac
        if ((slots > jobs)); then slots=$jobs; fi
        command_slots[n]=$slots
        printf 'suite: %s CPUs, reserving %s of %s slots for %s\n' \
            "$suite_cpus" "$slots" "$jobs" "${commands[n-1]}"
    done
fi

running_pids=()
running_ns=()
running_slots=0
failed=0
passed=0
started_at=$(seconds_now)

# Starts command n in the background; it writes "<status> <seconds>" to
# <output>/<n>.done when it ends.
start() { # n
    local n=$1 command
    command=${commands[n-1]}
    (
        begin=$(seconds_now)
        fast_builds=
        if [[ -z ${RUN_TESTS_FULL:-} && $command =~ (test-[[:alnum:]-]+) ]] &&
            grep -qx "${BASH_REMATCH[1]}" "$project_root/tools/test-fast-builds.txt"; then
            fast_builds=1
        fi
        # The network guard: gh, curl and wget refuse anything beyond file:// and the loopback host
        # (tools/lib/net-guard/curl), unless tools/test-network-allowed.txt names the command's script.
        # A guard already on PATH (this runner run by a test under another runner) is taken off first, so only this
        # runner's guard and list decide.
        unguarded_path=
        IFS=: read -r -a path_entries <<<"$PATH"
        for entry in "${path_entries[@]}"; do
            [[ $entry == */tools/lib/net-guard || $entry == */tools/lib/net-guard/ ]] ||
                unguarded_path=${unguarded_path:+$unguarded_path:}$entry
        done
        guard_path=$project_root/tools/lib/net-guard:$unguarded_path
        network_log=$output/$n.network
        : >"$network_log"
        if [[ $command =~ (tools/test-[[:alnum:]-]+\.sh) ]] &&
            awk '!/^#/ { print $1 }' "$project_root/tools/test-network-allowed.txt" | grep -xF "${BASH_REMATCH[1]}" >/dev/null; then
            guard_path=$unguarded_path
        fi
        # perl runs the command and reports the user and system seconds of the
        # command and everything it ran (`times` of the waited children).
        PATH=$guard_path ABLA_NET_GUARD_LOG=$network_log ABLA_TEST_FAST_BUILDS=$fast_builds perl -e '
            my $status = system("bash", "-c", $ARGV[0]);
            my @t = times;
            open(my $f, ">", $ARGV[1]) or exit 1;
            printf $f "%.1f\n", $t[2] + $t[3];
            exit($status == -1 ? 127 : ($status & 127) ? 128 + ($status & 127) : $status >> 8);
        ' "$command" "$output/$n.cpu" >"$output/$n.log" 2>&1 </dev/null
        status=$?
        # A refused network call fails the command (exit 97) even when the test swallowed the error.
        if [[ -s $network_log ]]; then
            { echo "run-tests: this command reached for the network (refused; tools/lib/net-guard/curl):"; cat "$network_log"; } >>"$output/$n.log"
            status=97
        fi
        rm -f "$network_log"
        end=$(seconds_now)
        cpu=$(cat "$output/$n.cpu" 2>/dev/null || echo 0)
        rm -f "$output/$n.cpu"
        printf '%s %s %s\n' "$status" "$(awk -v b="$begin" -v e="$end" 'BEGIN { printf "%.1f", e - b }')" "${cpu:-0}" \
            >"$output/$n.done.next"
        mv -f "$output/$n.done.next" "$output/$n.done"
    ) &
    running_pids+=("$!")
    running_ns+=("$n")
    running_slots=$((running_slots + ${command_slots[n]:-1}))
}

# Records every command that has ended; keeps the rest running.
reap() {
    local index pids=() ns=() n status seconds cpu command
    ((${#running_ns[@]} > 0)) || return 0
    for index in "${!running_ns[@]}"; do
        n=${running_ns[$index]}
        if [[ -f $output/$n.done ]]; then
            wait "${running_pids[$index]}" 2>/dev/null
            running_slots=$((running_slots - ${command_slots[n]:-1}))
            read -r status seconds cpu <"$output/$n.done"
            rm -f "$output/$n.done"
            command=${commands[n-1]}
            printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$status" "$seconds" "$command" "${cpu:-0}" >>"$output/results.tsv"
            if [[ $status -eq 0 ]]; then
                passed=$((passed + 1))
                printf 'PASS %6ss %7scpu  %s\n' "$seconds" "${cpu:-0}" "$command"
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

# Whether test-self-hosted.sh is still to run or running (run_all's `pending`).
self_hosted_active() {
    local n
    for n in ${pending[@]+"${pending[@]}"} ${running_ns[@]+"${running_ns[@]}"}; do
        [[ ${self_hosted_commands[n]:-} == 1 ]] && return 0
    done
    return 1
}

# Runs the given commands, at most `limit` at a time.
run_all() { # limit n...
    local limit=$1
    shift
    local pending=("$@") free next
    while ((${#pending[@]} > 0 || ${#running_ns[@]} > 0 || ${#serial[@]} > 0)); do
        reap
        if ((${#serial[@]} > 0)) && ! self_hosted_active; then
            # They are short (a minute together) and have waited: ahead of what is left, not behind it.
            pending=("${serial[@]}" ${pending[@]+"${pending[@]}"})
            serial=()
        fi
        while ((${#pending[@]} > 0 && running_slots < limit)); do
            next=${pending[0]}
            ((running_slots + ${command_slots[next]:-1} <= limit)) || break
            if ((${#running_ns[@]} > 0 && min_free > 0)); then
                free=$(free_percent)
                ((free >= min_free)) || break
            fi
            start "$next"
            pending=(${pending[@]+"${pending[@]:1}"})
        done
        ((${#running_ns[@]} > 0)) && sleep 0.2
    done
}

echo "running ${#parallel[@]} commands, $jobs at a time, and ${#serial[@]} once test-self-hosted.sh ends ($output)"
run_all "$jobs" ${parallel[@]+"${parallel[@]}"}

sort -n -o "$output/results.tsv" "$output/results.tsv" 2>/dev/null
# A whole run only: a filtered run or a command file of its own (make test-quick) would leave the next run its order
# for the few commands it ran.
if [[ -z $filter && -z ${RUN_TESTS_COMMANDS:-} && -z ${RUN_TESTS_SHARD:-} && -s $output/results.tsv ]]; then
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
