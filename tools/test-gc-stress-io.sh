#!/usr/bin/env bash
# Programs that hand addresses of collected memory to the system (#829): process, file and loopback-network cases,
# built once and run twice, as they are and under ABLA_GC_STRESS=1, which collects at every safe point and fills
# what it frees with 0xDB bytes. An address kept only as an integer across a safe point (a nativeCStringAddress
# copy in a table, a field or a local) then points at poison, not at the bytes a freed block keeps until it is
# reused, so the program fails at once instead of under rare pressure. Each must exit 42 both ways. The list is
# fixed so the step stays short. tests/cases/gc-stress-io/ct-process.ab is the compiler's own process capture,
# which every `#` site with process.io runs; native-argv.ab is the argv it hands LLVM's in-process option parser.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/gc-stress-io"
rm -rf "$output_directory"
mkdir -p "$output_directory/run/build/process-exec-strings"

case $(uname -s) in
    Linux) ;;
    *) echo "gc stress io: not Linux, skipped"; exit 0 ;;
esac

cases=(
    tests/cases/process-exec-strings/main.ab
    tests/cases/gc-stress-io/ct-process.ab
    tests/cases/gc-stress-io/native-argv.ab
    tests/cases/modules/process-capture.ab
    tests/cases/modules/linux-process.ab
    tests/cases/modules/host-process-configured.ab
    tests/cases/modules/filesystem.ab
    tests/cases/modules/linux-filesystem.ab
    tests/cases/modules/linux-net.ab
    tests/cases/modules/udp-ephemeral.ab
    tests/cases/modules/http-event.ab
    tests/cases/modules/websocket-live.ab
)

name_of() { # source
    local source=$1
    echo "$(basename "$(dirname "$source")")-$(basename "$source" .ab)"
}

# A run that is still going after $stuck_after seconds (a plain run takes seconds) gets its threads written next to its output:
# what each is waiting for (wchan) and the processor time it has used, twice, so a deadlock shows as the same wait and the same
# time, and a slow run as time that grows. A hang under stress otherwise sits at run-limited's 600 s with nothing to read (#1040).
stuck_after=${GC_STRESS_IO_STUCK_AFTER:-120}
stuck_report() { # binary report
    local binary=$1 report=$2 pass pid task
    sleep "$stuck_after" > /dev/null 2>&1 < /dev/null   # an orphan of a killed watcher holds no output open
    : > "$report"
    for pass in 1 2; do
        for exe in /proc/[0-9]*/exe; do
            [[ $(readlink "$exe" 2> /dev/null) == "$binary" ]] || continue
            pid=${exe#/proc/}; pid=${pid%/exe}
            echo "still running after ${stuck_after} s: process $pid, pass $pass" >> "$report"
            for task in /proc/$pid/task/*; do
                echo "  thread ${task##*/} $(cat "$task/comm" 2> /dev/null) wait=$(cat "$task/wchan" 2> /dev/null) cpu-ticks=$(awk '{print $14 + $15}' "$task/stat" 2> /dev/null)" >> "$report"
            done
        done
        [[ $pass == 2 ]] || sleep 5 > /dev/null 2>&1 < /dev/null
    done
}

jobs=${GC_STRESS_IO_JOBS:-4}
for source in "${cases[@]}"; do
    while (( $(jobs -rp | wc -l) >= jobs )); do wait -n || true; done
    name=$(name_of "$source")
    ( "$compiler" build "$project_root/$source" -o "$output_directory/$name" --no-cache \
        > "$output_directory/$name.build.log" 2>&1 || echo failed > "$output_directory/$name.build-failed" ) &
done
wait

failures=0
for source in "${cases[@]}"; do
    name=$(name_of "$source")
    if [[ -e $output_directory/$name.build-failed ]]; then
        echo "gc stress io: $source did not build" >&2
        cat "$output_directory/$name.build.log" >&2
        failures=$((failures + 1))
        continue
    fi
    # From a directory of their own: the cases write under build/ relative to where they run.
    plain=0
    (cd "$output_directory/run" && "$project_root/tools/run-limited.sh" "$output_directory/$name" \
        > "$output_directory/$name.plain.out" 2>&1 < /dev/null) || plain=$?
    stressed=0
    rm -f "$output_directory/$name.stuck"
    stuck_report "$output_directory/$name" "$output_directory/$name.stuck" &
    watcher=$!
    (cd "$output_directory/run" && ABLA_GC_STRESS=1 "$project_root/tools/run-limited.sh" \
        "$output_directory/$name" > "$output_directory/$name.stress.out" 2>&1 < /dev/null) || stressed=$?
    kill "$watcher" 2> /dev/null || true
    wait "$watcher" 2> /dev/null || true
    if [[ $plain != 42 || $stressed != 42 ]]; then
        echo "gc stress io: $source exited $plain, and $stressed under ABLA_GC_STRESS=1 (42 both ways expected)" >&2
        tail -n 5 "$output_directory/$name.stress.out" >&2
        [[ ! -s $output_directory/$name.stuck ]] || cat "$output_directory/$name.stuck" >&2
        failures=$((failures + 1))
    fi
done
(( failures == 0 )) || exit 1
echo "gc stress io: ${#cases[@]} programs exit 42 with a collection at every safe point and poisoned frees"
