#!/usr/bin/env bash
# Manual benchmark, not a pass/fail performance threshold. Pin this script with
# taskset when measuring; compare all modes in the same invocation/environment.
set -euo pipefail
compiler=${1:-build/ablac}
iterations=${2:-50000}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/bench-regex-literals
mkdir -p "$out"
"$compiler" build tools/bench-regex-literals/main.ab --no-cache -o "$out/main"
: > "$out/times.tsv"
TIMEFORMAT='%R'
for round in 1 2 3 4 5; do
    modes='compile literal cached'
    ((round % 2)) || modes='cached literal compile'
    for mode in $modes; do
        { time "$out/main" "$mode" '([a-z]+)-(\d+)' "$iterations" >"$out/count"; } 2>"$out/time"
        [[ $(cat "$out/count") == "$((iterations / 2 + iterations % 2))" ]]
        printf '%s\t%s\t%s\n' "$round" "$mode" "$(cat "$out/time")" >> "$out/times.tsv"
    done
done
printf 'iterations=%s, five runs per mode, median wall seconds (includes process startup):\n' "$iterations"
for mode in compile literal cached; do
    median=$(awk -v mode="$mode" '$2 == mode {print $3}' "$out/times.tsv" | sort -n | sed -n '3p')
    printf '%s\t%s\n' "$mode" "$median"
done
