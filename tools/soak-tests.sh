#!/usr/bin/env bash
# Repeat a suite selection, retaining every run's logs and reporting failures per command.
# Run inside nix-shell shell.nix and a fair-flock slot, just like run-tests.sh.
# Example: RUN_TESTS_FULL=1 tools/soak-tests.sh 20 'test-(mutex|stm)\.sh' [compiler] [new-output-directory]
# An empty regex selects the full suite. JOBS and the runner's other selection variables apply.
# Exit 0: all passed; 1: at least one failed; 2: invalid input or incomplete runner results.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
usage() { echo "usage: tools/soak-tests.sh N FILTER [compiler] [new-output-directory]" >&2; exit 2; }
[[ $# -ge 2 && $# -le 4 && $1 =~ ^[1-9][0-9]*$ ]] || usage
runs=$1
filter=$2
compiler=${3:-build/ablac}
printf '\n' | grep -E -- "$filter" >/dev/null && regex_status=0 || regex_status=$?
[[ $regex_status -le 1 ]] || usage
cd "$root"
if [[ $# == 4 ]]; then
    output=$4
    [[ $output == /* ]] || output=$root/$output
    mkdir -p -- "$(dirname -- "$output")"
    mkdir -- "$output" || { echo "soak: use a new output directory; existing evidence is never overwritten" >&2; exit 2; }
else
    mkdir -p build/test-results
    output=$(mktemp -d "$root/build/test-results/soak.XXXXXXXX")
fi
printf 'source\t%s\nruns\t%s\nfilter\t%s\ncompiler\t%s\nfull\t%s\njobs\t%s\n' \
    "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "$runs" "$filter" "$compiler" \
    "${RUN_TESTS_FULL:-}" "${JOBS:-default}" >"$output/manifest.tsv"
printf 'exclude\t%s\nshard\t%s\ncommands\t%s\n' "${RUN_TESTS_EXCLUDE:-}" \
    "${RUN_TESTS_SHARD:-}" "${RUN_TESTS_COMMANDS:-}" >>"$output/manifest.tsv"
git diff HEAD --stat >"$output/source-diff.txt" 2>/dev/null || true
: >"$output/results.tsv"
: >"$output/failures.tsv"
if ! RUN_TESTS_LIST=1 RUN_TESTS_FILTER=$filter RUN_TESTS_OUTPUT=$output/selection \
    "$root/tools/run-tests.sh" "$compiler" >"$output/expected-ids.txt" 2>"$output/selection.log"; then
    echo "soak: could not select commands; see $output/selection.log" >&2
    exit 2
fi
sed '/^$/d' "$output/expected-ids.txt" | LC_ALL=C sort >"$output/expected-ids.txt.next"
mv -- "$output/expected-ids.txt.next" "$output/expected-ids.txt"
[[ -s $output/expected-ids.txt ]] || { echo "soak: filter selected no commands" >&2; exit 2; }
failed=0
for ((iteration=1; iteration<=runs; iteration++)); do
    run=$output/run-$iteration
    echo "soak $iteration/$runs: $run"
    status=0
    RUN_TESTS_LIST='' RUN_TESTS_FILTER=$filter RUN_TESTS_OUTPUT=$run \
        "$root/tools/run-tests.sh" "$compiler" >"$output/run-$iteration.log" 2>&1 || status=$?
    printf '%s\t%s\n' "$iteration" "$status" >>"$output/runs.tsv"
    if [[ $status -gt 1 || ! -s $run/results.tsv ]]; then
        echo "soak: run $iteration incomplete or selected no commands; see $output/run-$iteration.log" >&2
        exit 2
    fi
    cut -f1 "$run/results.tsv" | LC_ALL=C sort >"$output/actual-ids.txt"
    if ! cmp -s "$output/expected-ids.txt" "$output/actual-ids.txt"; then
        echo "soak: missing or unexpected results in run $iteration; see $run" >&2
        exit 2
    fi
    # Check the same command IDs/text ran every time; a dropped row must never improve a flake rate.
    cut -f1,4 "$run/results.tsv" | LC_ALL=C sort >"$output/selection-$iteration.tsv"
    if ((iteration > 1)) && ! cmp -s "$output/selection-1.tsv" "$output/selection-$iteration.tsv"; then
        echo "soak: command selection changed in run $iteration; see $output/selection-$iteration.tsv" >&2
        exit 2
    fi
    awk -F '\t' -v OFS='\t' -v iteration="$iteration" '{ print iteration, $0 }' \
        "$run/results.tsv" >>"$output/results.tsv"
    awk -F '\t' -v OFS='\t' -v iteration="$iteration" -v run="$run" \
        '$2 != 0 { print iteration, $1, $2, $4, run "/" $1 ".log" }' \
        "$run/results.tsv" >>"$output/failures.tsv"
    if awk -F '\t' '$2 != 0 { failures++ } END { exit !failures }' "$run/results.tsv"; then
        failed=1
    elif ((status != 0)); then
        echo "soak: runner failed without a failed command in run $iteration; see $output/run-$iteration.log" >&2
        exit 2
    fi
    awk -F '\t' '
        { command=$5; total[command]++; if ($3 != 0) failures[command]++ }
        END { for (command in total) printf "%d\t%d\t%.2f%%\t%s\n", total[command], failures[command],
            100 * failures[command] / total[command], command }
    ' "$output/results.tsv" | LC_ALL=C sort -t "$(printf '\t')" -k2,2nr -k4,4 >"$output/summary.tsv.next"
    mv -- "$output/summary.tsv.next" "$output/summary.tsv"
done
printf '\nruns\tfailures\tfailure rate\tcommand\n'
cat "$output/summary.tsv"
echo "evidence: $output (failures.tsv links each failure to its log)"
exit "$failed"
