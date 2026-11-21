#!/usr/bin/env bash
# The doc-example suite runs the tour's Abla blocks. This checks that their real source files match,
# including helper modules, then compiles and executes the documented REPL session.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler=$PWD/$compiler
out=$root/build/tour-check
mkdir -p "$out"
count=0
for doc in docs/tour/*.md; do
    blocks=$out/$(basename "$doc" .md)
    mkdir -p "$blocks"
    : > "$blocks/index"
    awk -v out="$blocks" '
        !inside && /^```/ {
            inside=1; info=substr($0,4); abla=(info ~ /^abla /); n++
            if (abla) {
                source=""; split(info, words, " ")
                for (i in words) if (words[i] ~ /^source=/) source=substr(words[i],8)
                print n " " source > (out "/index")
                file=out "/" n; printf "" > file
            }
            next
        }
        inside && /^```[[:space:]]*$/ {inside=0; if (abla) close(file); next}
        inside && abla {print > file}
    ' "$doc"
    while read -r number source; do
        [[ -n $source ]] || { echo "tour: $doc has an Abla block without source=" >&2; exit 1; }
        cmp "$blocks/$number" "$(dirname "$doc")/$source" || { echo "tour: $doc differs from $source" >&2; exit 1; }
        count=$((count + 1))
    done < "$blocks/index"
done
[[ $count == 14 ]] || { echo "tour: expected 13 programs and one helper, got $count" >&2; exit 1; }
# Keep the visible transcript tied to the actual REPL input as well.
awk '/^```text$/ {inside=1; next} inside && /^```$/ {inside=0; next} inside {print}' docs/tour/13-repl.md > "$out/repl.input"
cmp "$out/repl.input" tests/cases/tour/repl.in
ABLA_MAX_MEMORY_MB=3072 ABLA_MAX_SECONDS=180 "$root/tools/run-limited.sh" "$compiler" repl \
    < tests/cases/tour/repl.in > "$out/repl.stdout" 2> "$out/repl.stderr"
printf 'abla> defined\nabla> 42\nabla> ' > "$out/repl.expected"
cmp "$out/repl.expected" "$out/repl.stdout"
[[ ! -s $out/repl.stderr ]] || { cat "$out/repl.stderr" >&2; exit 1; }
echo "tour: $count source blocks match; REPL stdout and successful exit checked"
