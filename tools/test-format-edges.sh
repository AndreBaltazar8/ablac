#!/usr/bin/env bash
# Data-format edge cases, with Node as the reference where it has one (tests/cases/format-edges):
#  - json.ab: 182 inputs (JSONTestSuite style: valid, invalid, odd numbers and escapes) parsed with jsonPermissiveLimits;
#    accept/refuse must equal JSON.parse's except the cases in json.exceptions (lone surrogate escapes, nesting beyond
#    256), and the whole verdict list is recorded in json.expected. json-inputs.mjs is the source of the inputs and
#    gen-json.mjs makes json.ab from it (checked here, so the two cannot drift). Needs node, else only the record is checked.
#  - base64.ab: RFC 4648 vectors, every byte value and pair round-tripped, malformed input refused ("" like the docs say:
#    no padding, whitespace, URL alphabet, a stray byte, a second block after padding), hex either case, odd lengths.
#  - query.ab: HttpRequest.queryParameter on 29 queries x 17 names (first non-empty value, raw text, empty parts).
#  - uuid.ab: uuidParse takes exactly the 36 character hyphenated form in either case.
# Each .ab (except json) runs every case as ordinary code and under `#` (interpreter and ABLA_COMPILE_EVAL=jit), they must
# agree and print exactly the recorded <name>.expected.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
cases=tests/cases/format-edges
out=build/format-edges
rm -rf "$out"
mkdir -p "$out"

for name in base64 query uuid; do
    for tier in interp jit; do
        ABLA_COMPILE_EVAL=$tier "$compiler" build "$cases/$name.ab" -o "$out/$name-$tier" --fast --no-cache
        set +e
        "$out/$name-$tier" > "$out/$name-$tier.txt" 2>&1
        status=$?
        set -e
        [[ $status -eq 0 ]] || { echo "format edges: $name ($tier): run time and compile time differ:" >&2; grep -a -v '^LIVE' "$out/$name-$tier.txt" | head -20 >&2; exit 1; }
        if ! cmp -s "$cases/$name.expected" "$out/$name-$tier.txt"; then
            echo "format edges: $name ($tier) differs from $name.expected:" >&2
            diff "$cases/$name.expected" "$out/$name-$tier.txt" | head -20 >&2
            exit 1
        fi
    done
    sed '1s/.*/mutated/' "$cases/$name.expected" > "$out/mutated.expected"
    ! cmp -s "$out/mutated.expected" "$out/$name-interp.txt" || { echo "format edges: the negative control matched in $name" >&2; exit 1; }
done

"$compiler" build "$cases/json.ab" -o "$out/json" --fast --no-cache
"$out/json" > "$out/json.txt"
cmp -s "$cases/json.expected" "$out/json.txt" || { echo "format edges: json verdicts differ from json.expected:" >&2; diff "$cases/json.expected" "$out/json.txt" | head -20 >&2; exit 1; }

node=${FORMAT_EDGES_NODE:-$(command -v node || true)}
if [[ -z $node ]]; then
    echo "format edges: recorded results match; the comparison with Node is skipped (no node)"
    exit 0
fi
"$node" "$cases/gen-json.mjs" "$out/json.ab" "$out/json-node.txt"
tail -n +2 "$out/json.ab" > "$out/json-fresh.txt"; tail -n +2 "$cases/json.ab" > "$out/json-committed.txt"
cmp -s "$out/json-fresh.txt" "$out/json-committed.txt" || { echo "format edges: json.ab is not what gen-json.mjs makes from json-inputs.mjs" >&2; exit 1; }
paste -d' ' "$out/json-node.txt" "$out/json.txt" | awk -v exceptions="$cases/json.exceptions" '
    BEGIN { while ((getline line < exceptions) > 0) { split(line, p, " "); allowed[p[1]] = 1 } }
    $1 != $2 { if (!((NR - 1) in allowed)) { print "input " (NR - 1) ": JSON.parse " $1 ", Abla " $2; bad = 1 } else seen[NR - 1] = 1 }
    $1 == $2 && ((NR - 1) in allowed) { print "input " (NR - 1) " is listed in json.exceptions but agrees with JSON.parse"; bad = 1 }
    END { exit bad }' >&2 || { echo "format edges: JSON accept/refuse differs from Node" >&2; exit 1; }
echo "format edges: base64/hex, query, uuid and $(grep -c . "$cases/json.expected") JSON inputs agree with the records (run time and #, both tiers) and, for JSON, with Node apart from the 5 listed"
