#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
cd "$root"

floor=tools/doc-coverage-floor.txt
out=build/doc-coverage-floor
mkdir -p "$out"
"$compiler" doc --stdlib "$root/stdlib" --output "$out" --coverage-debt "$out/current.tsv" > "$out/doc.log"
sort -o "$out/current.tsv" "$out/current.tsv"
sort -c "$floor"

base=${ABLA_DOC_COVERAGE_BASE:-origin/master}
if [[ -n ${ABLA_DOC_COVERAGE_BASE:-} ]]; then
    git cat-file -e "$base^{commit}"
fi
if git cat-file -e "$base:$floor" 2>/dev/null; then
    git show "$base:$floor" > "$out/previous.tsv"
    comm -13 "$out/previous.tsv" "$floor" > "$out/added.tsv"
    if [[ -s "$out/added.tsv" ]]; then
        echo 'doc coverage: the floor adds legacy exceptions' >&2
        cat "$out/added.tsv" >&2
        exit 1
    fi
fi

comm -23 "$out/current.tsv" "$floor" > "$out/new.tsv"
comm -13 "$out/current.tsv" "$floor" > "$out/resolved.tsv"
if [[ -s "$out/new.tsv" ]]; then
    echo 'doc coverage: add doc comments for these public declarations' >&2
    cat "$out/new.tsv" >&2
    exit 1
fi
if [[ -s "$out/resolved.tsv" ]]; then
    echo "doc coverage: remove resolved exceptions from $floor" >&2
    cat "$out/resolved.tsv" >&2
    exit 1
fi
printf 'doc coverage: %s remaining legacy declarations match the floor\n' "$(wc -l < "$floor")"
tail -1 "$out/doc.log"
