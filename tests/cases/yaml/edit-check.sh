#!/usr/bin/env bash
# Lossless editing vectors. edit/*.json are the specs (*-value.json also pin the
# resulting value); edit-expected.txt is the probe's canonical output for each,
# in file-name order, compared byte for byte (diff). Every supported parser
# input must also keep its complete concrete source: the `noop` probe mode
# (no edit) and `root` mode (set the root to the source itself) must print the
# source back unchanged (cmp).
# Usage: edit-check.sh EDIT-PROBE OUTPUT-DIRECTORY
set -euo pipefail
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
    *-value.json) "$probe" "$spec" value >> "$output/edit-actual.txt" || status=$? ;;
    *) "$probe" "$spec" >> "$output/edit-actual.txt" || status=$? ;;
    esac
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
        "$probe" "$mode" "$here/corpus/$name.yaml" > "$output/edit-$mode.out" || status=$?
        [[ $status == 0 ]] || { echo "YAML $mode on $name exited $status" >&2; exit 1; }
        cmp -s "$here/corpus/$name.yaml" "$output/edit-$mode.out" ||
            { echo "YAML $mode changed the text of $name" >&2; exit 1; }
    done
    paired=$((paired + 1))
done < "$here/corpus.list"
echo "YAML editing: $count edit vectors and $paired x 2 lossless source round trips passed"
