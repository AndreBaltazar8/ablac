#!/usr/bin/env bash
# Lossless editing vectors. edit/*.json are the specs (*-value.json also pin the
# resulting value); edit-expected.txt is the probe's canonical output for each,
# in file-name order, compared byte for byte (diff). Every supported parser
# input must also keep its complete concrete source: the `noop` probe mode
# (no edit) and `root` mode (set the root to the source itself) must print the
# source back unchanged (cmp).
# Usage: edit-check.sh EDIT-PROBE OUTPUT-DIRECTORY
set -euo pipefail
# A hung probe must not stall the suite: run each under `timeout 5` where it
# exists (Linux). macOS has no timeout and runs the probes unguarded.
guard=()
if command -v timeout >/dev/null 2>&1; then guard=(timeout 5); fi
probe=$1
output=$2
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$output"
: > "$output/edit-actual.txt"
count=0
for spec in "$here"/edit/*.json; do
    count=$((count + 1))
    status=0
    case $(basename "$spec") in
    *-value.json) ${guard[@]+"${guard[@]}"} "$probe" "$spec" value >> "$output/edit-actual.txt" || status=$? ;;
    *) ${guard[@]+"${guard[@]}"} "$probe" "$spec" >> "$output/edit-actual.txt" || status=$? ;;
    esac
    [[ $status != 124 ]] || { echo "probe timed out on $spec" >&2; exit 1; }
    [[ $status == 0 ]] || { echo "edit probe exited $status on $spec" >&2; exit 1; }
done
diff "$here/edit-expected.txt" "$output/edit-actual.txt" > "$output/edit.diff" ||
    { head -20 "$output/edit.diff" >&2; echo "YAML editing differs from edit-expected.txt" >&2; exit 1; }
paired=0
line=0
while IFS= read -r name; do
    line=$((line + 1))
    [[ $(sed -n "${line}p" "$here/expected.txt") != error ]] || continue
    for mode in noop root; do
        status=0
        ${guard[@]+"${guard[@]}"} "$probe" "$mode" "$here/corpus/$name.yaml" > "$output/edit-$mode.out" || status=$?
        [[ $status != 124 ]] || { echo "probe timed out on $name" >&2; exit 1; }
        [[ $status == 0 ]] || { echo "YAML $mode on $name exited $status" >&2; exit 1; }
        cmp -s "$here/corpus/$name.yaml" "$output/edit-$mode.out" ||
            { echo "YAML $mode changed the text of $name" >&2; exit 1; }
    done
    paired=$((paired + 1))
done < "$here/corpus.list"
echo "YAML editing: $count edit vectors and $paired x 2 lossless source round trips passed"
