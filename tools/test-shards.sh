#!/usr/bin/env bash
# The suite's shards (tools/run-tests.sh with RUN_TESTS_SHARD=i/n, what the CI matrix of the Linux job and the release's static suite run): for 2, 3 and 4 shards, every command of
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
# The libc-free check is a separate suite recipe for each x86 part.
LIBC_FREE_TARGETS=x86 tools/test-libc-free-programs.sh "$compiler" --list > "$work/libc-free.whole"
for part in 1 2 3; do
    LIBC_FREE_TARGETS=x86 tools/test-libc-free-programs.sh "$compiler" --part "$part/3" --list
done | sort > "$work/libc-free.parts"
sort "$work/libc-free.whole" > "$work/libc-free.expected"
diff -u "$work/libc-free.expected" "$work/libc-free.parts"
list() { RUN_TESTS_LIST=1 RUN_TESTS_OUTPUT="$work/$1" "$root/tools/run-tests.sh" "$compiler" "${@:2}" | sort -n; }
export RUN_TESTS_SHARD=
whole=$(RUN_TESTS_SHARD='' list whole)
[[ -n $whole ]] || { echo "test-shards: the suite lists no command" >&2; exit 1; }
# release-4: the release's static suite, four shards in release mode (RUN_TESTS_FULL=1), split by tools/test-times-release.tsv
# over tools/test-times.tsv.
for run in 2 3 4 6 release-4; do
    count=${run#release-}
    tables=$root/tools/test-times.tsv
    if [[ $run == release-* ]]; then export RUN_TESTS_FULL=1; tables+=" $root/tools/test-times-release.tsv"; else unset RUN_TESTS_FULL; fi
    : > "$work/union.$run"
    for ((shard = 1; shard <= count; shard++)); do
        RUN_TESTS_SHARD=$shard/$count list "s$shard-$run" > "$work/shard.$shard.$run"
        [[ -s $work/shard.$shard.$run ]] || { echo "test-shards: shard $shard/$count is empty" >&2; exit 1; }
        cat "$work/shard.$shard.$run" >> "$work/union.$run"
    done
    sort -n "$work/union.$run" > "$work/union-sorted.$run"
    if [[ $(sort -n "$work/union.$run" | uniq -d | head -n 1) != '' ]]; then
        echo "test-shards: $count shards: command $(sort -n "$work/union.$run" | uniq -d | head -n 1) is in two shards" >&2; exit 1
    fi
    if ! diff <(printf '%s\n' "$whole") "$work/union-sorted.$run" > "$work/diff.$run"; then
        echo "test-shards: $count shards: the union is not the whole suite:" >&2; head -n 5 "$work/diff.$run" >&2; exit 1
    fi
    # test-self-hosted.sh and what waits for it: one shard.
    self=$(grep -n 'tools/test-self-hosted.sh' "$work/whole/commands.txt" | head -n 1 | cut -d: -f1)
    shard_of_self=
    for ((shard = 1; shard <= count; shard++)); do grep -qx "$self" "$work/shard.$shard.$run" && shard_of_self=$shard; done
    [[ -n $shard_of_self ]] || { echo "test-shards: test-self-hosted.sh is in no shard" >&2; exit 1; }
    for waiting in test-borrow-lifetimes test-floating-point test-nominal-scalars test-unsafe-stack-memory test-local-shadowing test-eval-steps test-borrow-duplicates; do
        number=$(grep -n "tools/$waiting.sh" "$work/whole/commands.txt" | head -n 1 | cut -d: -f1)
        [[ -n $number ]] || continue
        grep -qx "$number" "$work/shard.$shard_of_self.$run" || { echo "test-shards: $waiting is not in test-self-hosted.sh's shard" >&2; exit 1; }
    done
    # The balance, by the cost table.
    awk -F'\t' -v count="$count" -v run="$run" -v work="$work" -v tables="$tables" '
        function key(command) { gsub(/[^ ;]*ablac[^ ;]*/, "COMPILER", command); return command }
        BEGIN {
            m = split(tables, tab, " ")
            for (t = 1; t <= m; t++) {
                while ((getline line < tab[t]) > 0) {
                    split(line, f, "\t")
                    if (f[3] ~ /^[0-9.]+$/) { k = key(f[4]); cost[k] = (f[5] + 0 > 0 ? f[5] + 0 : f[3] + 0); wall[k] = f[3] + 0 }
                }
                close(tab[t])
            }
            n = 0; while ((getline line < (work "/whole/commands.txt")) > 0) { n++; cmd[n] = line }
            for (s = 1; s <= count; s++) {
                file = work "/shard." s "." run
                while ((getline number < file) > 0) {
                    k = key(cmd[number]); total[s] += (k in cost ? cost[k] : 20)
                    w = (k in wall ? wall[k] : 0)
                    if (w > first) { second = first; secondshard = firstshard; secondname = firstname; first = w; firstshard = s; firstname = cmd[number] }
                    else if (w > second) { second = w; secondshard = s; secondname = cmd[number] }
                }
                close(file)
            }
            # The two longest commands by wall start on separate shards: together they would set one shard'\''s length.
            if (firstshard == secondshard) {
                printf "%s shards: the two longest commands share shard %d: %s (%.0f s) and %s (%.0f s)\n", run, firstshard, firstname, first, secondname, second
                exit 1
            }
            min = total[1]; max = total[1]
            for (s = 2; s <= count; s++) { if (total[s] < min) min = total[s]; if (total[s] > max) max = total[s] }
            printf "%s shards: cost per shard", run; for (s = 1; s <= count; s++) printf " %.0f", total[s]; printf " (longest/shortest %.3f)\n", max / min
            exit (max / min > 1.12)
        }' || { echo "test-shards: $run shards are not balanced, or their two longest commands share a shard" >&2; exit 1; }
done
echo "test-shards: the shards are disjoint, cover the suite, keep test-self-hosted.sh with what waits for it, and are balanced"
