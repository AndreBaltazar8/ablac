#!/usr/bin/env bash
# The suite's shards (tools/run-tests.sh with RUN_TESTS_SHARD=i/n, what the CI matrix of the Linux job runs): for 2 and 3 shards, every command of
# the recipe is in exactly one shard (the union of the shards is the whole suite, no command twice, none dropped), test-self-hosted.sh is in the
# same shard as the commands that wait for it, a command that tools/test-times.tsv does not know is still placed, and the shards' cost (by that
# table) is balanced: the longest within 12% of the shortest. Usage: tools/test-shards.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# This check proves the whole recipe's partition, even when a focused suite
# selected this script. The parent's filter, exclusions or custom recipe must
# not change the universe that the shard assertions describe.
unset RUN_TESTS_FILTER RUN_TESTS_EXCLUDE RUN_TESTS_COMMANDS
mkdir -p build   # run-tests.sh stamps its compiler cache there
work=$(mktemp -d "${TMPDIR:-/tmp}/test-shards.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
list() { RUN_TESTS_LIST=1 RUN_TESTS_OUTPUT="$work/$1" "$root/tools/run-tests.sh" "$compiler" "${@:2}" | sort -n; }
export RUN_TESTS_SHARD=
whole=$(RUN_TESTS_SHARD='' list whole)
[[ -n $whole ]] || { echo "test-shards: the suite lists no command" >&2; exit 1; }
for count in 2 3; do
    : > "$work/union.$count"
    for ((shard = 1; shard <= count; shard++)); do
        RUN_TESTS_SHARD=$shard/$count list "s$shard-$count" > "$work/shard.$shard.$count"
        [[ -s $work/shard.$shard.$count ]] || { echo "test-shards: shard $shard/$count is empty" >&2; exit 1; }
        cat "$work/shard.$shard.$count" >> "$work/union.$count"
    done
    sort -n "$work/union.$count" > "$work/union-sorted.$count"
    if [[ $(sort -n "$work/union.$count" | uniq -d | head -n 1) != '' ]]; then
        echo "test-shards: $count shards: command $(sort -n "$work/union.$count" | uniq -d | head -n 1) is in two shards" >&2; exit 1
    fi
    if ! diff <(printf '%s\n' "$whole") "$work/union-sorted.$count" > "$work/diff.$count"; then
        echo "test-shards: $count shards: the union is not the whole suite:" >&2; head -n 5 "$work/diff.$count" >&2; exit 1
    fi
    # test-self-hosted.sh and what waits for it: one shard.
    self=$(grep -n 'tools/test-self-hosted.sh' "$work/whole/commands.txt" | head -n 1 | cut -d: -f1)
    shard_of_self=
    for ((shard = 1; shard <= count; shard++)); do grep -qx "$self" "$work/shard.$shard.$count" && shard_of_self=$shard; done
    [[ -n $shard_of_self ]] || { echo "test-shards: test-self-hosted.sh is in no shard" >&2; exit 1; }
    for waiting in test-borrow-lifetimes test-floating-point test-nominal-scalars test-unsafe-stack-memory test-local-shadowing test-eval-steps test-borrow-duplicates; do
        number=$(grep -n "tools/$waiting.sh" "$work/whole/commands.txt" | head -n 1 | cut -d: -f1)
        [[ -n $number ]] || continue
        grep -qx "$number" "$work/shard.$shard_of_self.$count" || { echo "test-shards: $waiting is not in test-self-hosted.sh's shard" >&2; exit 1; }
    done
    # The balance, by the cost table.
    awk -F'\t' -v count="$count" -v work="$work" -v tab="$root/tools/test-times.tsv" '
        function key(command) { gsub(/[^ ;]*ablac[^ ;]*/, "COMPILER", command); return command }
        BEGIN {
            while ((getline line < tab) > 0) { split(line, f, "\t"); cost[key(f[4])] = (f[5] + 0 > 0 ? f[5] + 0 : f[3] + 0) }
            n = 0; while ((getline line < (work "/whole/commands.txt")) > 0) { n++; cmd[n] = line }
            for (s = 1; s <= count; s++) {
                file = work "/shard." s "." count
                while ((getline number < file) > 0) { k = key(cmd[number]); total[s] += (k in cost ? cost[k] : 20) }
                close(file)
            }
            min = total[1]; max = total[1]
            for (s = 2; s <= count; s++) { if (total[s] < min) min = total[s]; if (total[s] > max) max = total[s] }
            printf "%d shards: cost per shard", count; for (s = 1; s <= count; s++) printf " %.0f", total[s]; printf " (longest/shortest %.3f)\n", max / min
            exit (max / min > 1.12)
        }' || { echo "test-shards: $count shards are not balanced" >&2; exit 1; }
done
echo "test-shards: the shards are disjoint, cover the suite, keep test-self-hosted.sh with what waits for it, and are balanced"
