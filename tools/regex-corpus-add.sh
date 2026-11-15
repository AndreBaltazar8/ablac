#!/usr/bin/env bash
# Adds the `corpus:` lines that `tools/fuzz/run --regex` prints for a disagreement (read from stdin, with or without
# the "  corpus: " prefix) to tests/cases/regex/corpus.tsv.gz, once each, keeping the file's compression reproducible.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
file=$root/tests/cases/regex/corpus.tsv.gz
work=$(mktemp -d "${TMPDIR:-/tmp}/abla-regex-corpus-XXXXXXXX")
trap 'rm -rf "$work"' EXIT
zcat "$file" >"$work/corpus.tsv"
sed -n 's/^ *corpus: //p;t;/\t/p' >"$work/new.tsv"
[[ -s $work/new.tsv ]] || { echo 'regex-corpus-add: no corpus lines on stdin' >&2; exit 1; }
added=0
while IFS= read -r line; do
    if ! grep -Fx -- "$line" "$work/corpus.tsv" >/dev/null; then
        printf '%s\n' "$line" >>"$work/corpus.tsv"
        added=$((added + 1))
    fi
done <"$work/new.tsv"
gzip -9n <"$work/corpus.tsv" >"$file"
echo "regex-corpus-add: $added line(s) added"
